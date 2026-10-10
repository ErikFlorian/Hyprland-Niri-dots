"""Checks for the backup engine, isolated in temporary directories."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import tomllib
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("deploy", Path(__file__).with_name("deploy.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotfiles-engine-test-")
        self.base = Path(self.temp.name)
        self.home = self.base / "target home"
        self.home.mkdir()
        self.env = patch.dict(os.environ, {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
        })
        self.env.start()
        self.bundle = self.base / "bundle"
        self.bundle.mkdir()
        self.stage = self.base / "stage"
        self.backup = self.home / ".local/state/dotfiles/backups/test"
        self.entries = []
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()

    def tearDown(self):
        self.output.__exit__(None, None, None)
        self.env.stop()
        self.temp.cleanup()

    def add(self, root, rel, text):
        file = self.bundle / "payload" / root / rel
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.entries.append({"root": root, "path": rel})
        (self.bundle / "manifest.json").write_text(json.dumps(self.entries))

    def args(self):
        return SimpleNamespace(bundle=self.bundle, stage=self.stage,
                               backup=self.backup, keep_monitors=False, vm=False)

    def test_backup_restore_preserves_original_and_displaced_changes(self):
        self.add("home", ".zshrc", "new shell")
        self.add("home", ".local/bin/helper", "new helper")
        (self.home / ".zshrc").write_text("original shell")
        deploy.prepare(self.args())
        deploy.deploy(self.args())
        self.assertEqual((self.home / ".zshrc").read_text(), "new shell")
        self.assertEqual((self.backup / "original/home/.zshrc").read_text(), "original shell")
        (self.home / ".zshrc").write_text("edited after install")
        deploy.restore_backup(self.backup, deploy.roots())
        self.assertEqual((self.home / ".zshrc").read_text(), "original shell")
        self.assertFalse((self.home / ".local/bin/helper").exists())
        displaced = list(self.backup.glob("before-restore-*/home/.zshrc"))
        self.assertEqual(displaced[0].read_text(), "edited after install")
        with self.assertRaises(ValueError):
            deploy.restore_backup(self.backup, deploy.roots())

    def test_failed_second_move_rolls_back_first_and_original_second_file(self):
        self.add("home", ".one", "new one")
        self.add("home", ".two", "new two")
        for name in (".one", ".two"):
            (self.home / name).write_text("old " + name)
        deploy.prepare(self.args())
        original_move = shutil.move

        def fail_second(src, dst, *args, **kwargs):
            if Path(src) == self.stage / "home/.two":
                raise OSError("simulated disk write failure")
            return original_move(src, dst, *args, **kwargs)

        with patch.object(deploy.shutil, "move", side_effect=fail_second):
            with self.assertRaises(OSError):
                deploy.deploy(self.args())
        self.assertEqual((self.home / ".one").read_text(), "old .one")
        self.assertEqual((self.home / ".two").read_text(), "old .two")
        self.assertTrue(json.loads((self.backup / "journal.json").read_text())["restored"])

    def test_existing_symlink_is_backed_up_and_restored_as_symlink(self):
        self.add("home", ".zshrc", "new shell")
        source = self.home / "old-config"
        source.write_text("original shell")
        (self.home / ".zshrc").symlink_to(source)
        deploy.prepare(self.args())
        deploy.deploy(self.args())
        self.assertFalse((self.home / ".zshrc").is_symlink())
        deploy.restore_backup(self.backup, deploy.roots())
        self.assertTrue((self.home / ".zshrc").is_symlink())
        self.assertEqual(source.read_text(), "original shell")

    def test_external_parent_symlink_is_rejected(self):
        self.add("home", "escape/config", "new")
        outside = self.base / "outside"
        outside.mkdir()
        (self.home / "escape").symlink_to(outside)
        with self.assertRaises(ValueError):
            deploy.manifest(self.bundle)
        self.assertFalse((outside / "config").exists())

    def test_traversal_and_overlapping_paths_are_rejected(self):
        with self.assertRaises(ValueError):
            deploy.relative("../outside")
        self.add("home", "folder/file", "new")
        self.entries.append({"root": "home", "path": "folder"})
        (self.bundle / "manifest.json").write_text(json.dumps(self.entries))
        with self.assertRaises(ValueError):
            deploy.manifest(self.bundle)

    def test_prepare_renders_new_home_and_vm_idle_without_mutating_payload(self):
        self.add("state", "noctalia/settings.toml",
                 'path = "@DOTFILES_HOME@/Wallpapers/black.png"\n'
                 '    [idle.behavior.lock-and-suspend]\n    enabled = true\n')
        args = self.args()
        args.vm = True
        deploy.prepare(args)
        actual = (self.stage / "state/noctalia/settings.toml").read_text()
        self.assertIn(str(self.home / "Wallpapers/black.png"), actual)
        self.assertIn("enabled = false", actual)
        original = (self.bundle / "payload/state/noctalia/settings.toml").read_text()
        self.assertIn("@DOTFILES_HOME@", original)
        self.assertIn("enabled = true", original)

    def test_monitor_override_is_opt_in_and_gui_preferences_survive(self):
        self.add("config", "niri/monitors.kdl", "// automatic\n")
        self.add("config", "niri/monitors-original.kdl", 'output "eDP-1" { position x=3840 y=-120; }\n')
        self.add("config", "hypr/monitors.lua", "-- automatic\n")
        original = 'hl.monitor({output="eDP-1", position="3840x-120"})\n'
        self.add("config", "hypr/monitors-original.lua", original)
        gui = 'require("monitors")\nhl.config({general={layout="scrolling", gaps_in=3}})\n'
        self.add("config", "hypr/hyprland-gui.lua", gui)
        args = self.args()
        args.vm = True
        self.add("state", "noctalia/settings.toml", "[idle]\n")
        deploy.prepare(args)
        self.assertEqual((self.stage / "config/hypr/monitors.lua").read_text(), "-- automatic\n")
        self.assertEqual((self.stage / "config/hypr/hyprland-gui.lua").read_text(), gui)
        args.stage = self.base / "kept-monitors"
        args.keep_monitors = True
        deploy.prepare(args)
        self.assertEqual((args.stage / "config/hypr/monitors.lua").read_text(), original)
        self.assertIn('output "eDP-1"', (args.stage / "config/niri/monitors.kdl").read_text())
        self.assertEqual((self.bundle / "payload/config/hypr/monitors.lua").read_text(), "-- automatic\n")

    def test_each_compositor_leaves_other_config_untouched_and_restores_its_own(self):
        self.add("home", ".zshrc", "shared shell")
        self.add("config", "niri/config.kdl", "new niri")
        self.add("config", "hypr/hyprland.lua", "new hyprland")
        self.add("state", "noctalia/settings.toml",
                 '[theme.templates]\nbuiltin_ids = ["foot", "niri", "hyprland", "sway", "qt"]\n')
        for entry in self.entries:
            if entry["path"] == "niri/config.kdl":
                entry["compositors"] = ["niri"]
            elif entry["path"] == "hypr/hyprland.lua":
                entry["compositors"] = ["hyprland"]
        (self.bundle / "manifest.json").write_text(json.dumps(self.entries))
        targets = {"niri": self.home / ".config/niri/config.kdl",
                   "hyprland": self.home / ".config/hypr/hyprland.lua"}
        for compositor, target in targets.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("old " + compositor)
        for compositor in ("niri", "hyprland"):
            with self.subTest(compositor=compositor):
                args = self.args()
                args.compositor = compositor
                args.stage = self.base / ("stage-" + compositor)
                args.backup = self.home / ("backup-" + compositor)
                other = "hyprland" if compositor == "niri" else "niri"
                deploy.prepare(args)
                self.assertFalse((args.stage / targets[other].relative_to(self.home).as_posix().replace(".config/", "config/", 1)).exists())
                settings = tomllib.loads((args.stage / "state/noctalia/settings.toml").read_text())
                self.assertEqual(set(settings["theme"]["templates"]["builtin_ids"]), {"foot", "qt", compositor})
                deploy.deploy(args)
                self.assertEqual(targets[other].read_text(), "old " + other)
                self.assertEqual(targets[compositor].read_text(), "new " + compositor)
                journal = json.loads((args.backup / "journal.json").read_text())
                self.assertEqual(journal["compositor"], compositor)
                deploy.restore_backup(args.backup, deploy.roots())
                self.assertEqual(targets[compositor].read_text(), "old " + compositor)
        source = tomllib.loads((self.bundle / "payload/state/noctalia/settings.toml").read_text())
        self.assertIn("sway", source["theme"]["templates"]["builtin_ids"])

    def test_invalid_compositor_manifest_is_rejected(self):
        self.add("home", ".zshrc", "new")
        self.entries[0]["compositors"] = ["unknown"]
        (self.bundle / "manifest.json").write_text(json.dumps(self.entries))
        with self.assertRaises(ValueError):
            deploy.manifest(self.bundle, "niri")

    def test_catalog_only_lists_missing_archived_payload_sources(self):
        self.add("home", ".zshrc", "temporary source")
        shutil.rmtree(self.bundle / "payload")
        with self.assertRaises(ValueError):
            deploy.manifest(self.bundle, "niri")
        self.assertEqual(len(deploy.manifest(self.bundle, "niri", check_sources=False)), 1)
        args = self.args()
        args.compositor = "niri"
        args.catalog_only = True
        deploy.show(args)
        self.assertIn(str(self.home / ".zshrc"), self.output._new_target.getvalue())

    def test_catalog_only_is_rejected_for_prepare_and_deploy(self):
        for mode in ("prepare", "deploy"):
            with self.subTest(mode=mode):
                argv = ["deploy.py", mode, "--bundle", str(self.bundle), "--catalog-only"]
                with patch("sys.argv", argv), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        deploy.main()
                self.assertEqual(error.exception.code, 2)

    def test_niri_waybar_defaults_use_niri_modules(self):
        self.add("config", "waybar/config.jsonc", '"hyprland/workspaces"')
        self.add("config", "waybar/config-niri.jsonc", '"niri/workspaces"')
        self.add("config", "waybar/style.css", "hyprland style")
        self.add("config", "waybar/style-niri.css", "niri style")
        args = self.args()
        args.compositor = "niri"
        deploy.prepare(args)
        self.assertEqual((self.stage / "config/waybar/config.jsonc").read_text(), '"niri/workspaces"')
        self.assertEqual((self.stage / "config/waybar/style.css").read_text(), "niri style")
        self.assertEqual((self.bundle / "payload/config/waybar/config.jsonc").read_text(), '"hyprland/workspaces"')


if __name__ == "__main__":
    unittest.main()
