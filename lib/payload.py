#!/usr/bin/env python3
"""Pack, verify, and safely extract large dotfiles payload archives."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile
from typing import BinaryIO

FORMAT = "dotfiles-payload-archives"
VERSION = 1
DEFAULT_PART_SIZE = 24 * 1024 * 1024
CHUNK_SIZE = 1024 * 1024
MAX_MANIFEST_SIZE = 4 * 1024 * 1024


class PayloadError(Exception):
    pass


class ChunkWriter:
    """Write one gzip stream to bounded, independently hashed part files."""

    def __init__(self, directory: Path, part_size: int):
        self.directory = directory
        self.part_size = part_size
        self.parts: list[dict[str, object]] = []
        self.current: BinaryIO | None = None
        self.current_hash = hashlib.sha256()
        self.current_size = 0
        self.total_size = 0

    def writable(self) -> bool:
        return True

    def write(self, data: bytes) -> int:
        view = memoryview(data)
        written = len(view)
        while view:
            if self.current is None or self.current_size == self.part_size:
                self._finish_part()
                index = len(self.parts) + 1
                name = f"payload-{index:04d}.tar.gz.part"
                self.current = (self.directory / name).open("xb")
                self.current_hash = hashlib.sha256()
                self.current_size = 0
            amount = min(len(view), self.part_size - self.current_size)
            piece = view[:amount]
            self.current.write(piece)
            self.current_hash.update(piece)
            self.current_size += amount
            self.total_size += amount
            view = view[amount:]
        return written

    def flush(self) -> None:
        if self.current is not None:
            self.current.flush()

    def _finish_part(self) -> None:
        if self.current is None:
            return
        self.current.close()
        index = len(self.parts) + 1
        self.parts.append({
            "name": f"payload-{index:04d}.tar.gz.part",
            "size": self.current_size,
            "sha256": self.current_hash.hexdigest(),
        })
        self.current = None
        self.current_size = 0

    def close(self) -> None:
        self._finish_part()


class ConcatenatedReader:
    """Read a sequence of archive parts as one gzip stream."""

    def __init__(self, paths: list[Path]):
        self.paths = paths
        self.index = 0
        self.file: BinaryIO | None = None

    def readable(self) -> bool:
        return True

    def read(self, size: int = -1) -> bytes:
        if size == 0:
            return b""
        chunks: list[bytes] = []
        remaining = size
        while self.index < len(self.paths) and (size < 0 or remaining > 0):
            if self.file is None:
                self.file = self.paths[self.index].open("rb")
            block = self.file.read(CHUNK_SIZE if size < 0 else remaining)
            if block:
                chunks.append(block)
                if size > 0:
                    remaining -= len(block)
                continue
            self.file.close()
            self.file = None
            self.index += 1
        return b"".join(chunks)

    def close(self) -> None:
        if self.file is not None:
            self.file.close()
            self.file = None


def _manifest_path(bundle: Path) -> Path:
    return bundle / "payload-archives" / "manifest.json"


def _read_manifest(bundle: Path) -> tuple[dict[str, object], list[Path]]:
    path = _manifest_path(bundle)
    try:
        if path.stat().st_size > MAX_MANIFEST_SIZE:
            raise PayloadError("Archive manifest is unexpectedly large.")
        data = json.loads(path.read_text(encoding="utf-8"))
    except PayloadError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PayloadError(f"Cannot read archive manifest {path}: {exc}") from exc

    if not isinstance(data, dict) or data.get("format") != FORMAT or data.get("version") != VERSION:
        raise PayloadError("Unsupported or invalid payload archive manifest format.")
    if data.get("archive_root") != "payload/":
        raise PayloadError("Manifest archive_root must be 'payload/'.")
    for field in ("file_count", "total_bytes"):
        if type(data.get(field)) is not int or data[field] < 0:
            raise PayloadError(f"Manifest field {field!r} must be a nonnegative integer.")
    parts = data.get("parts")
    if not isinstance(parts, list) or not parts:
        raise PayloadError("Manifest must list at least one archive part.")

    root = path.parent.resolve()
    paths: list[Path] = []
    names: set[str] = set()
    for index, part in enumerate(parts, start=1):
        if not isinstance(part, dict):
            raise PayloadError(f"Invalid archive part entry #{index}.")
        name = part.get("name")
        expected_name = f"payload-{index:04d}.tar.gz.part"
        if name != expected_name or name in names:
            raise PayloadError(f"Invalid or out-of-order archive part name at entry #{index}.")
        names.add(name)
        size = part.get("size")
        digest = part.get("sha256")
        if type(size) is not int or size <= 0:
            raise PayloadError(f"Invalid size for archive part {name}.")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise PayloadError(f"Invalid SHA-256 for archive part {name}.")
        candidate = path.parent / name
        try:
            resolved = candidate.resolve(strict=True)
            if resolved.parent != root or not candidate.is_file() or candidate.is_symlink():
                raise PayloadError(f"Archive part is not a regular file in the archive directory: {name}")
        except OSError as exc:
            raise PayloadError(f"Missing archive part {name}: {exc}") from exc
        paths.append(candidate)
    return data, paths


def check_archives(bundle: Path) -> tuple[dict[str, object], list[Path]]:
    manifest, parts = _read_manifest(bundle)
    entries = manifest["parts"]
    for entry, path in zip(entries, parts, strict=True):
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            while block := stream.read(CHUNK_SIZE):
                digest.update(block)
                size += len(block)
        if size != entry["size"]:
            raise PayloadError(f"Size mismatch for {path.name}: expected {entry['size']}, found {size}.")
        if digest.hexdigest() != entry["sha256"]:
            raise PayloadError(f"SHA-256 mismatch for {path.name}.")
    return manifest, parts


def _payload_entries(source: Path) -> list[tuple[Path, str, bool, os.stat_result]]:
    if not source.is_dir() or source.is_symlink():
        raise PayloadError(f"Payload source directory is missing or is a symlink: {source}")
    entries: list[tuple[Path, str, bool, os.stat_result]] = []
    for directory, dirs, files in os.walk(source, topdown=True, followlinks=False):
        base = Path(directory)
        dirs.sort()
        files.sort()
        for name in list(dirs):
            path = base / name
            info = path.lstat()
            if not path.is_dir() or path.is_symlink():
                raise PayloadError(f"Payload contains a symlink or non-directory entry: {path}")
            arcname = (Path("payload") / path.relative_to(source)).as_posix() + "/"
            entries.append((path, arcname, True, info))
        for name in files:
            path = base / name
            info = path.lstat()
            if not path.is_file() or path.is_symlink():
                raise PayloadError(f"Payload contains a symlink or non-regular file: {path}")
            arcname = (Path("payload") / path.relative_to(source)).as_posix()
            entries.append((path, arcname, False, info))
    entries.sort(key=lambda item: item[1])
    return entries


def _write_manifest(path: Path, data: dict[str, object]) -> None:
    encoded = json.dumps(data, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    with path.open("xb") as stream:
        stream.write(encoded)
        stream.flush()
        os.fsync(stream.fileno())


def pack(bundle: Path, output: Path | None, part_size: int) -> None:
    if type(part_size) is not int or part_size < 1:
        raise PayloadError("Archive part size must be a positive integer number of bytes.")
    bundle = bundle.resolve()
    source = bundle / "payload"
    entries = _payload_entries(source)
    files = [entry for entry in entries if not entry[2]]
    total_bytes = sum(info.st_size for _, _, is_dir, info in entries if not is_dir)
    output = (output or bundle / "payload-archives").absolute()
    if output == source or source in output.parents or output in source.parents:
        raise PayloadError("Archive output must be outside the source payload directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=output.parent))
    backup: Path | None = None
    try:
        writer = ChunkWriter(staging, part_size)
        try:
            with gzip.GzipFile(fileobj=writer, mode="wb", compresslevel=3, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                    root_info = source.lstat()
                    root = tarfile.TarInfo("payload/")
                    root.type = tarfile.DIRTYPE
                    root.mode = root_info.st_mode & 0o777
                    root.mtime = 0
                    archive.addfile(root)
                    for path, arcname, is_dir, info in entries:
                        item = tarfile.TarInfo(arcname)
                        item.mode = info.st_mode & 0o777
                        item.mtime = 0
                        if is_dir:
                            item.type = tarfile.DIRTYPE
                            archive.addfile(item)
                        else:
                            item.size = info.st_size
                            with path.open("rb") as stream:
                                archive.addfile(item, stream)
        finally:
            writer.close()
        if not writer.parts:
            raise PayloadError("Archive creation produced no data.")
        descriptor: dict[str, object] = {
            "format": FORMAT,
            "version": VERSION,
            "archive_root": "payload/",
            "file_count": len(files),
            "total_bytes": total_bytes,
            "parts": writer.parts,
        }
        _write_manifest(staging / "manifest.json", descriptor)
        # Verify the newly generated parts before making the replacement visible.
        _verify_directory(staging)
        if output.exists() or output.is_symlink():
            backup = output.with_name(f".{output.name}.old-{os.getpid()}")
            if backup.exists():
                raise PayloadError(f"Cannot safely replace archive output; backup path exists: {backup}")
            output.rename(backup)
        try:
            staging.rename(output)
        except Exception:
            if backup is not None and backup.exists() and not output.exists():
                backup.rename(output)
                backup = None
            raise
        if backup is not None:
            shutil.rmtree(backup)
            backup = None
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        if backup is not None and backup.exists() and not output.exists():
            backup.rename(output)


def _verify_directory(directory: Path) -> tuple[dict[str, object], list[Path]]:
    # The reader uses the same schema and digest checks without requiring a bundle root.
    wrapper = directory.parent / f".{directory.name}.verify-{os.getpid()}"
    if wrapper.exists():
        raise PayloadError(f"Temporary verification path already exists: {wrapper}")
    wrapper.mkdir()
    try:
        (wrapper / "payload-archives").symlink_to(directory, target_is_directory=True)
        return check_archives(wrapper)
    finally:
        shutil.rmtree(wrapper)


def _safe_member_name(name: str) -> tuple[str, bool]:
    if not name or "\\" in name or name.startswith("/"):
        raise PayloadError(f"Unsafe archive path: {name!r}")
    is_dir = name.endswith("/")
    raw = name[:-1] if is_dir else name
    path = PurePosixPath(raw)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise PayloadError(f"Unsafe archive path: {name!r}")
    if path.parts[0] != "payload":
        raise PayloadError(f"Archive member is outside payload/: {name!r}")
    normalized = path.as_posix()
    if normalized != raw:
        raise PayloadError(f"Noncanonical archive path: {name!r}")
    return normalized, is_dir


def extract(bundle: Path, destination: Path) -> None:
    manifest, parts = check_archives(bundle)
    destination = destination.absolute()
    if destination.is_symlink():
        raise PayloadError("Extraction destination must not be a symlink.")
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise PayloadError("Extraction destination must be an empty directory or a new path.")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.extract-", dir=destination.parent))
    os.chmod(staging, 0o700)
    seen: set[str] = set()
    files = 0
    total_bytes = 0
    total_members = 0
    reader = ConcatenatedReader(parts)
    try:
        with gzip.GzipFile(fileobj=reader, mode="rb") as compressed:
            with tarfile.open(fileobj=compressed, mode="r|") as archive:
                for member in archive:
                    total_members += 1
                    name, is_dir = _safe_member_name(member.name)
                    if name in seen:
                        raise PayloadError(f"Duplicate archive member: {member.name}")
                    seen.add(name)
                    if member.isdir():
                        target = staging / name
                        target.mkdir(parents=True, exist_ok=True)
                        os.chmod(target, member.mode & 0o777)
                    elif member.isfile():
                        if is_dir:
                            raise PayloadError(f"Regular file has directory path: {member.name}")
                        if member.size < 0 or total_bytes + member.size > manifest["total_bytes"]:
                            raise PayloadError("Archive extracted byte count exceeds manifest declaration.")
                        target = staging / name
                        target.parent.mkdir(parents=True, exist_ok=True)
                        stream = archive.extractfile(member)
                        if stream is None:
                            raise PayloadError(f"Cannot read archive member: {member.name}")
                        remaining = member.size
                        with target.open("xb") as out:
                            os.chmod(target, member.mode & 0o777)
                            while remaining:
                                block = stream.read(min(CHUNK_SIZE, remaining))
                                if not block:
                                    raise PayloadError(f"Truncated archive member: {member.name}")
                                out.write(block)
                                remaining -= len(block)
                                total_bytes += len(block)
                        files += 1
                    else:
                        raise PayloadError(f"Links, devices, and special files are forbidden: {member.name}")
                    if total_members > manifest["file_count"] + 1_000_000:
                        raise PayloadError("Archive has an unreasonable number of directory entries.")
        if "payload" not in seen or files != manifest["file_count"] or total_bytes != manifest["total_bytes"]:
            raise PayloadError(
                "Extracted payload does not match manifest "
                f"(files {files}/{manifest['file_count']}, bytes {total_bytes}/{manifest['total_bytes']})."
            )
        if destination.exists():
            if destination.is_symlink() or any(destination.iterdir()):
                raise PayloadError("Extraction destination changed or is no longer empty.")
            destination.rmdir()
        staging.rename(destination)
    except (tarfile.TarError, OSError, EOFError, gzip.BadGzipFile) as exc:
        raise PayloadError(f"Archive extraction failed: {exc}") from exc
    finally:
        reader.close()
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer number of bytes") from exc
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer number of bytes")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Package, verify, or extract the large dotfiles payload.")
    sub = parser.add_subparsers(dest="command", required=True)
    pack_parser = sub.add_parser("pack", help="create bounded, SHA-256 checked tar.gz parts")
    pack_parser.add_argument("--bundle", type=Path, required=True, help="dotfiles bundle directory")
    pack_parser.add_argument("--output", type=Path, help="archive output directory (default: BUNDLE/payload-archives)")
    pack_parser.add_argument("--part-size", type=positive_int, default=DEFAULT_PART_SIZE, help="maximum bytes per part (default: 24 MiB)")
    check_parser = sub.add_parser("check", help="validate manifest and verify every archive part")
    check_parser.add_argument("--bundle", type=Path, required=True, help="dotfiles bundle directory")
    extract_parser = sub.add_parser("extract", help="verify parts and extract payload/ into an empty directory")
    extract_parser.add_argument("--bundle", type=Path, required=True, help="dotfiles bundle directory")
    extract_parser.add_argument("--destination", type=Path, required=True, help="new or empty directory; payload/ is created inside")
    args = parser.parse_args(argv)
    try:
        if args.command == "pack":
            pack(args.bundle, args.output, args.part_size)
            manifest, _ = _verify_directory((args.output or args.bundle / "payload-archives").absolute())
            print(f"Created {len(manifest['parts'])} verified archive part(s) in {args.output or args.bundle / 'payload-archives'}.")
        elif args.command == "check":
            manifest, _ = check_archives(args.bundle)
            print(
                f"Archive OK: {len(manifest['parts'])} part(s), "
                f"{manifest['file_count']} files, {manifest['total_bytes']} uncompressed bytes."
            )
        else:
            extract(args.bundle, args.destination)
            print(f"Verified payload extracted to {args.destination.absolute() / 'payload'}.")
    except PayloadError as exc:
        print(f"payload.py: error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
