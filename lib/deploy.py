#!/usr/bin/env python3
"""Stage, back up and deploy only the paths in the dotfiles manifest."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import tomllib


def roots():
    home = Path(os.environ["HOME"]).resolve()
    result = {"home": home}
    for name, variable, default in (
        ("config", "XDG_CONFIG_HOME", ".config"),
        ("data", "XDG_DATA_HOME", ".local/share"),
        ("state", "XDG_STATE_HOME", ".local/state"),
    ):
        value = Path(os.environ.get(variable) or str(home / default))
        if not value.is_absolute():
            raise ValueError(f"{variable} must be an absolute path")
        value = value.resolve()
        if value == home or not value.is_relative_to(home):
            raise ValueError(f"{variable} must be a directory inside HOME")
        result[name] = value
    return result


def relative(value):
    path = Path(value)
    if path.is_absolute() or not path.parts or any(p in ("..", ".") for p in path.parts):
        raise ValueError(f"Invalid manifest path: {value}")
    return path


def safe_target(root, rel):
    target = root / relative(rel)
    if not target.parent.resolve().is_relative_to(root):
        raise ValueError(f"Parent symlink escapes destination: {target}")
    return target


def exists(path):
    return path.exists() or path.is_symlink()


def write_json(path, data):
    temporary = path.with_suffix(".new")
    with temporary.open("w") as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def manifest(bundle, compositor=None, check_sources=True):
    catalog = json.loads((bundle / "manifest.json").read_text())
    result = []
    mapped = roots()
    targets = []
    for entry in catalog:
        supported = entry.get("compositors", ["niri", "hyprland"])
        if not isinstance(supported, list) or not supported or any(c not in ("niri", "hyprland") for c in supported):
            raise ValueError("Invalid compositor list in manifest")
        if compositor and compositor not in supported:
            continue
        if entry["root"] not in mapped:
            raise ValueError("Unknown manifest root")
        rel = relative(entry["path"])
        src = bundle / "payload" / entry["root"] / rel
        if check_sources and (not exists(src) or src.is_symlink()):
            raise ValueError(f"Missing or symbolic payload entry: {src}")
        target = safe_target(mapped[entry["root"]], rel)
        if any(target == old or target.is_relative_to(old) or old.is_relative_to(target) for old in targets):
            raise ValueError(f"Overlapping deployment entry: {target}")
        targets.append(target)
        result.append(entry)
    return result


def prepare(args):
    compositor = getattr(args, "compositor", None)
    entries = manifest(args.bundle, compositor)
    mapped = roots()
    stage = args.stage.resolve()
    stage.mkdir(parents=True, exist_ok=True)
    for entry in entries:
        src = args.bundle / "payload" / entry["root"] / entry["path"]
        dest = stage / entry["root"] / entry["path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dest)
        else:
            shutil.copy2(src, dest)
    substitutions = {
        "@DOTFILES_CONFIG@": str(mapped["config"]),
        "@DOTFILES_DATA@": str(mapped["data"]),
        "@DOTFILES_STATE@": str(mapped["state"]),
        "@DOTFILES_HOME@": str(mapped["home"]),
    }
    # Only our staged text is rendered; existing files are never searched/edited.
    for file in stage.rglob("*"):
        if not file.is_file() or file.stat().st_size > 2 * 1024 * 1024:
            continue
        try:
            text = file.read_text()
        except UnicodeDecodeError:
            continue
        before = text
        for marker, value in substitutions.items():
            if file.suffix in (".json", ".jsonc", ".toml", ".kdl", ".lua"):
                value = json.dumps(value, ensure_ascii=False)[1:-1]
            text = text.replace(marker, value)
        if text != before:
            file.write_text(text)
    if args.keep_monitors:
        for original, target in (
            ("config/niri/monitors-original.kdl", "config/niri/monitors.kdl"),
            ("config/hypr/monitors-original.lua", "config/hypr/monitors.lua"),
        ):
            if (stage / original).exists():
                shutil.copy2(stage / original, stage / target)
    settings = stage / "state/noctalia/settings.toml"
    if compositor and settings.exists():
        text = settings.read_text()
        config = tomllib.loads(text)
        templates = config.get("theme", {}).get("templates", {}).get("builtin_ids", [])
        templates = [item for item in templates if item not in ("niri", "hyprland", "sway") or item == compositor]
        if compositor not in templates:
            templates.append(compositor)
        text, count = re.subn(
            r"(?m)^([ \t]*)builtin_ids\s*=\s*\[[^\]]*\]",
            lambda match: match[1] + "builtin_ids = " + json.dumps(templates), text,
        )
        if count != 1:
            raise ValueError("Expected exactly one Noctalia builtin_ids setting")
        settings.write_text(text)
    if compositor == "niri":
        # Optional Waybar must also use this compositor's modules if started later.
        for source, target in (("config-niri.jsonc", "config.jsonc"), ("style-niri.css", "style.css")):
            base = stage / "config/waybar"
            if (base / source).exists():
                shutil.copy2(base / source, base / target)
    if args.vm:
        file = stage / "state/noctalia/settings.toml"
        text = file.read_text()
        # Preserve lock timers; a guest should not automatically suspend itself.
        section = "    [idle.behavior.lock-and-suspend]"
        if section in text:
            prefix, tail = text.split(section, 1)
            tail = tail.replace("enabled = true", "enabled = false", 1)
            file.write_text(prefix + section + tail)
    print(f"Staged {len(entries)} deployment entries.")


def show(args):
    mapped = roots()
    for entry in manifest(args.bundle, args.compositor, check_sources=not getattr(args, "catalog_only", False)):
        print(f"  {safe_target(mapped[entry['root']], entry['path'])}")


def restore_backup(backup, expected, automatic=False):
    if backup.stat().st_uid != os.getuid():
        raise ValueError("This backup is owned by a different user")
    info = json.loads((backup / "journal.json").read_text())
    if info["roots"] != {key: str(value) for key, value in expected.items()}:
        raise ValueError("This backup belongs to a different HOME or XDG layout")
    if info.get("restored"):
        raise ValueError("This backup has already been restored")
    recovery = backup / ("failed-install" if automatic else f"before-restore-{time.time_ns()}")
    for entry in reversed(info["entries"]):
        root, rel = entry["root"], relative(entry["path"])
        target = safe_target(expected[root], rel)
        saved = backup / "original" / root / rel
        # An existing target may not have been moved yet when an install failed.
        if entry["existed"] and not exists(saved):
            continue
        if exists(target):
            displaced = recovery / root / rel
            displaced.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(displaced))
        if exists(saved):
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(saved), str(target))
    info["restored"] = True
    write_json(backup / "journal.json", info)
    print(f"Restored dotfiles. Replaced files were retained in {recovery}")


def deploy(args):
    compositor = getattr(args, "compositor", None)
    entries = manifest(args.bundle, compositor)
    mapped = roots()
    backup = args.backup.resolve()
    if exists(backup):
        raise ValueError(f"Backup already exists: {backup}")
    backup.mkdir(parents=True, mode=0o700)
    info = {"roots": {key: str(value) for key, value in mapped.items()}, "entries": [], "restored": False,
            "compositor": compositor}
    write_json(backup / "journal.json", info)
    try:
        for entry in entries:
            target = safe_target(mapped[entry["root"]], entry["path"])
            src = args.stage / entry["root"] / entry["path"]
            if not exists(src):
                raise ValueError(f"Missing staged entry: {src}")
            target.parent.mkdir(parents=True, exist_ok=True)
            record = dict(entry, existed=exists(target))
            info["entries"].append(record)
            write_json(backup / "journal.json", info)
            if record["existed"]:
                saved = backup / "original" / entry["root"] / entry["path"]
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(target), str(saved))
            shutil.move(str(src), str(target))
    except BaseException:
        restore_backup(backup, mapped, automatic=True)
        raise
    print(f"Installed {len(entries)} entries; backup: {backup}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "show", "prepare", "deploy", "restore"))
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--keep-monitors", action="store_true")
    parser.add_argument("--vm", action="store_true")
    parser.add_argument("--compositor", choices=("niri", "hyprland"),
                        help="Select one compositor; omitted checks the complete payload")
    parser.add_argument("--catalog-only", action="store_true",
                        help="Check/show paths without requiring expanded sources (archive dry-run only)")
    args = parser.parse_args()
    if args.catalog_only and args.mode not in ("check", "show"):
        parser.error("--catalog-only is only valid with check or show")
    if args.mode in ("prepare", "deploy") and not args.stage:
        parser.error("--stage is required")
    if args.mode in ("deploy", "restore") and not args.backup:
        parser.error("--backup is required")
    if args.mode == "restore":
        restore_backup(args.backup.resolve(), roots())
    elif args.mode == "check":
        print(f"Manifest valid: {len(manifest(args.bundle, args.compositor, check_sources=not args.catalog_only))} entries")
    else:
        {"prepare": prepare, "show": show, "deploy": deploy}[args.mode](args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
