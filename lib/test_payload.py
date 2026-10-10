"""Safety and round-trip tests for payload archives; all data stays in temp dirs."""

import hashlib
import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("payload", Path(__file__).with_name("payload.py"))
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


class PayloadArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="payload-archive-test-")
        self.base = Path(self.temp.name)
        self.bundle = self.base / "bundle"
        (self.bundle / "payload").mkdir(parents=True)
        self.archives = self.bundle / "payload-archives"
        self.destination = self.base / "extracted"

    def tearDown(self):
        self.temp.cleanup()

    def make_tar(self, members):
        """Build a trusted-hash archive from (TarInfo, bytes|None) pairs."""
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as archive:
            for info, content in members:
                if content is None:
                    archive.addfile(info)
                else:
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))
        raw = data.getvalue()
        self.archives.mkdir(parents=True, exist_ok=True)
        part_name = "payload-0001.tar.gz.part"
        (self.archives / part_name).write_bytes(raw)
        regular_files = [(info, content) for info, content in members if info.isfile()]
        descriptor = {
            "format": payload.FORMAT,
            "version": payload.VERSION,
            "archive_root": "payload/",
            "file_count": len(regular_files),
            "total_bytes": sum(len(content) for _, content in regular_files),
            "parts": [{"name": part_name, "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}],
        }
        (self.archives / "manifest.json").write_text(json.dumps(descriptor), encoding="utf-8")
        return descriptor

    def test_pack_and_extract_preserves_hidden_unicode_modes_and_empty_directories(self):
        source = self.bundle / "payload"
        (source / "nested" / "empty").mkdir(parents=True)
        (source / ".hidden file").write_bytes(b"hidden\0data")
        executable = source / "nested" / "café-工具.sh"
        executable.write_bytes(bytes(range(256)) * 100)
        executable.chmod(0o751)

        payload.pack(self.bundle, None, 512)
        manifest, parts = payload.check_archives(self.bundle)
        self.assertGreater(len(parts), 1)
        self.assertTrue(all(path.stat().st_size <= 512 for path in parts))
        self.assertEqual(manifest["file_count"], 2)
        self.assertEqual(manifest["total_bytes"], 11 + 25600)

        payload.extract(self.bundle, self.destination)
        extracted = self.destination / "payload"
        self.assertEqual((extracted / ".hidden file").read_bytes(), b"hidden\0data")
        result = extracted / "nested" / "café-工具.sh"
        self.assertEqual(result.read_bytes(), executable.read_bytes())
        self.assertEqual(result.stat().st_mode & 0o777, 0o751)
        self.assertTrue((extracted / "nested" / "empty").is_dir())

    def test_cli_pack_check_extract_round_trip(self):
        (self.bundle / "payload" / "dir").mkdir()
        (self.bundle / "payload" / "dir" / "file").write_text("cli payload")
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(payload.main(["pack", "--bundle", str(self.bundle), "--part-size", "128"]), 0)
            self.assertEqual(payload.main(["check", "--bundle", str(self.bundle)]), 0)
            self.assertEqual(payload.main([
                "extract", "--bundle", str(self.bundle), "--destination", str(self.destination),
            ]), 0)
        self.assertIn("Created", output.getvalue())
        self.assertEqual((self.destination / "payload/dir/file").read_text(), "cli payload")

    def test_pack_api_rejects_nonpositive_part_size(self):
        (self.bundle / "payload" / "file").write_text("content")
        for size in (0, -1, True):
            with self.subTest(size=size), self.assertRaises(payload.PayloadError):
                payload.pack(self.bundle, None, size)

    def test_corrupt_chunk_is_rejected_before_extracting_anything(self):
        (self.bundle / "payload" / "file").write_text("some payload")
        payload.pack(self.bundle, None, 4096)
        manifest_path = self.archives / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        part = self.archives / manifest["parts"][0]["name"]
        part.write_bytes(part.read_bytes() + b"corruption")

        with self.assertRaises(payload.PayloadError):
            payload.extract(self.bundle, self.destination)
        self.assertFalse(self.destination.exists())

    def test_missing_part_is_rejected(self):
        (self.bundle / "payload" / "file").write_text("content")
        payload.pack(self.bundle, None, 4096)
        (self.archives / "payload-0001.tar.gz.part").unlink()
        with self.assertRaises(payload.PayloadError):
            payload.check_archives(self.bundle)

    def test_manifest_part_length_mismatch_is_rejected(self):
        info = tarfile.TarInfo("payload/file")
        descriptor = self.make_tar([(info, b"abc")])
        descriptor["parts"][0]["size"] += 1
        (self.archives / "manifest.json").write_text(json.dumps(descriptor))
        with self.assertRaises(payload.PayloadError):
            payload.check_archives(self.bundle)

    def test_manifest_file_count_and_byte_mismatches_leave_destination_absent(self):
        for field, bad_value in (("file_count", 2), ("total_bytes", 4)):
            with self.subTest(field=field):
                if self.archives.exists():
                    import shutil
                    shutil.rmtree(self.archives)
                descriptor = self.make_tar([(tarfile.TarInfo("payload/file"), b"abc")])
                descriptor[field] = bad_value
                (self.archives / "manifest.json").write_text(json.dumps(descriptor))
                with self.assertRaises(payload.PayloadError):
                    payload.extract(self.bundle, self.destination)
                self.assertFalse(self.destination.exists())

    def test_existing_nonempty_destination_is_never_overwritten(self):
        self.make_tar([(tarfile.TarInfo("payload/file"), b"new")])
        self.destination.mkdir()
        sentinel = self.destination / "keep.txt"
        sentinel.write_text("original")
        with self.assertRaises(payload.PayloadError):
            payload.extract(self.bundle, self.destination)
        self.assertEqual(sentinel.read_text(), "original")

    def test_traversal_symlink_hardlink_and_duplicate_members_are_rejected(self):
        cases = []

        traversal = tarfile.TarInfo("payload/../../escape")
        cases.append(("traversal", [(traversal, b"bad")]))

        symlink = tarfile.TarInfo("payload/link")
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = "../../outside"
        cases.append(("symlink", [(symlink, None)]))

        hardlink = tarfile.TarInfo("payload/link")
        hardlink.type = tarfile.LNKTYPE
        hardlink.linkname = "payload/file"
        cases.append(("hardlink", [(hardlink, None)]))

        cases.append(("duplicate", [
            (tarfile.TarInfo("payload/file"), b"first"),
            (tarfile.TarInfo("payload/file"), b"second"),
        ]))

        outside = self.base / "escape"
        outside.write_text("keep")
        for name, members in cases:
            with self.subTest(name=name):
                import shutil
                if self.archives.exists():
                    shutil.rmtree(self.archives)
                if self.destination.exists():
                    shutil.rmtree(self.destination)
                self.make_tar(members)
                with self.assertRaises(payload.PayloadError):
                    payload.extract(self.bundle, self.destination)
                self.assertEqual(outside.read_text(), "keep")
                self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
