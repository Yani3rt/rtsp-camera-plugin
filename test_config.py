import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

from config import save, validate, validate_size, validate_position, position_filename
from config import normalize_library, update_library, validate_appearance


class SettingsTests(unittest.TestCase):
    def test_overlay_defaults_and_validates_choices(self):
        old = dict(style="original", strength=35, pixelSize=3)
        self.assertEqual(validate_appearance(old), dict(old, overlay="default"))
        for overlay in ("default", "coder", "hacker"):
            self.assertEqual(validate_appearance(dict(old, overlay=overlay)), dict(old, overlay=overlay))
        for old_overlay, new_overlay in (("off", "default"), ("hud", "coder"), ("terminal", "hacker")):
            self.assertEqual(validate_appearance(dict(old, overlay=old_overlay)), dict(old, overlay=new_overlay))
        for overlay in (None, [], 1, "unknown"):
            with self.subTest(overlay=overlay), self.assertRaises(ValueError):
                validate_appearance(dict(old, overlay=overlay))

    def test_pixel_size_defaults_for_old_settings_and_accepts_full_range(self):
        self.assertEqual(validate_appearance(dict(style="pixel", strength=35)),
                         dict(style="pixel", strength=35, pixelSize=3, overlay="default"))
        for size in (1, 8, 16):
            data = dict(style="theme-pixel", strength=60, pixelSize=size, overlay="default")
            self.assertEqual(validate_appearance(data), data)

    def test_pixel_size_rejects_invalid_values(self):
        for value in (None, True, 0, -1, 17, 3.5, "8", float("nan")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_appearance(dict(style="pixel", strength=35, pixelSize=value))

    def test_appearance_save_is_separate_and_invalid_edits_preserve_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "rtsp-camera"
            credentials = dict(url="rtsp://camera/live", username="user", password="secret")
            save(credentials, directory)
            def run(data):
                return subprocess.run([sys.executable, str(Path(__file__).with_name("config.py")), "--appearance"],
                                      input=json.dumps(data) + "\n", text=True, capture_output=True,
                                      env=dict(os.environ, XDG_CONFIG_HOME=temporary))
            for style in ("original", "theme", "pixel", "theme-pixel"):
                data = dict(style=style, strength=35, pixelSize=8, overlay="coder")
                result = run(data)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(json.loads((directory / "appearance.json").read_text()), data)
                self.assertEqual(json.loads((directory / "config.json").read_text()), credentials)
            before = (directory / "appearance.json").read_bytes()
            for data in (None, {}, dict(style="unknown", strength=35), dict(style=[], strength=35),
                         *[dict(style="theme", strength=x) for x in (True, -1, 101, "35", float("nan"))]):
                with self.subTest(data=data):
                    self.assertNotEqual(run(data).returncode, 0)
                    self.assertEqual((directory / "appearance.json").read_bytes(), before)

    def test_helper_cli_routes_profiles_size_and_position(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, XDG_CONFIG_HOME=temporary)
            cases = [
                ("--profiles", dict(action="save", camera=dict(name="Front", url="rtsp://camera/live", username="", password="")), "config.json"),
                ("--view-size", dict(width=800, height=600), "view.json"),
                ("--position", dict(screen="DP-1", x=50, y=70), position_filename("DP-1")),
            ]
            for flag, data, filename in cases:
                result = subprocess.run([sys.executable, str(Path(__file__).with_name("config.py")), flag],
                                        input=json.dumps(data) + "\n", text=True, capture_output=True, env=environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((Path(temporary) / "rtsp-camera" / filename).exists())

    def test_concurrent_additions_preserve_both_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def add(name):
                return update_library(dict(action="save", camera=dict(name=name, url="rtsp://camera/live", username="", password="")), directory)
            with ThreadPoolExecutor(max_workers=2) as executor:
                list(executor.map(add, ["Front", "Back"]))
            library = json.loads((directory / "config.json").read_text())
            self.assertEqual({camera["name"] for camera in library["cameras"]}, {"Front", "Back"})

    def test_migrates_existing_camera_without_changing_credentials(self):
        old = dict(url="rtsp://camera/live", username="user", password="secret")
        library = normalize_library(old)
        self.assertEqual(library["selectedId"], "default")
        self.assertEqual(library["cameras"][0], dict(old, id="default", name="Camera 1"))

    def test_add_select_rename_delete_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            old = dict(url="rtsp://camera/live", username="user", password="secret")
            save(old, directory)
            second = dict(url="rtsp://second/live", username="second", password="other", name="Garage")
            added = update_library(dict(action="save", camera=second), directory)
            new_id = added["selectedId"]
            self.assertEqual(len(added["cameras"]), 2)
            self.assertEqual(added["cameras"][0]["password"], "secret")
            selected = update_library(dict(action="select", id="default"), directory)
            self.assertEqual(selected["selectedId"], "default")
            renamed = update_library(dict(action="save", camera=dict(second, id=new_id, name="Back door")), directory)
            self.assertEqual(renamed["cameras"][1]["name"], "Back door")
            remaining = update_library(dict(action="delete", id=new_id), directory)
            self.assertEqual(remaining["selectedId"], "default")
            empty = update_library(dict(action="delete", id="default"), directory)
            self.assertEqual(empty, dict(version=2, selectedId="", cameras=[]))
            self.assertEqual(stat.S_IMODE((directory / "config.json").stat().st_mode), 0o600)

    def test_invalid_profile_edit_leaves_saved_library_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            camera = dict(name="Front", url="rtsp://camera/live", username="", password="")
            update_library(dict(action="save", camera=camera), directory)
            before = (directory / "config.json").read_bytes()
            for bad in (dict(camera, name=""), dict(camera, name="front"),
                        dict(camera, name="New", url="http://camera"), dict(camera, id="missing")):
                with self.subTest(camera=bad), self.assertRaises(ValueError):
                    update_library(dict(action="save", camera=bad), directory)
                self.assertEqual((directory / "config.json").read_bytes(), before)
            with self.assertRaises(ValueError):
                update_library(dict(action="select", id="missing"), directory)

    def test_positions_roundtrip_independently_per_monitor(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for screen, x in (("DP-1", 120), ("HDMI-A-1", 340)):
                data = validate_position(dict(screen=screen, x=x, y=80))
                save(data, directory, position_filename(screen))
            self.assertEqual(json.loads((directory / position_filename("DP-1")).read_text())["x"], 120)
            self.assertEqual(json.loads((directory / position_filename("HDMI-A-1")).read_text())["x"], 340)
            self.assertNotIn("/", position_filename("../monitor/name"))

    def test_rejects_invalid_positions(self):
        for value in (True, -1, 32769, "120", float("nan")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_position(dict(screen="DP-1", x=value, y=80))
        for screen in (None, "", 12):
            with self.subTest(screen=screen), self.assertRaises(ValueError):
                validate_position(dict(screen=screen, x=0, y=0))

    def test_size_save_preserves_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            credentials = dict(url="rtsp://camera/live", username="user", password="secret")
            save(credentials, directory)
            size = validate_size(dict(width=900, height=650))
            save(size, directory, "view.json")
            self.assertEqual(json.loads((directory / "view.json").read_text()), size)
            self.assertEqual(json.loads((directory / "config.json").read_text()), credentials)

    def test_rejects_invalid_sizes(self):
        for value in (None, True, -1, 0, 32769, "640", float("nan")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_size(dict(width=value, height=500))

    def test_rejects_invalid_addresses(self):
        for url in ("rtps://10.0.0.233/ch2", "rtsp://10.0.0.233:ch2",
                    "rtsp://", "http://camera/live", "rtsp://user:secret@camera/live",
                    "rtsp://camera:0/live", "rtsp://camera:65536/live",
                    "rtsp://cam era/live", "rtsp://camera/live#fragment"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate(dict(url=url, username="user", password="secret"))

    def test_ipv6_and_special_credentials_roundtrip_privately(self):
        data = validate(dict(url=" rtsps://[::1]:554/ch2?mode=1 ",
                             username="user@example.com", password="p:@/\\\"\n%雪"))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "camera"
            save(data, directory)
            path = directory / "config.json"
            self.assertEqual(json.loads(path.read_text()), data)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            save(dict(data, password="replacement"), directory)
            self.assertEqual(json.loads(path.read_text())["password"], "replacement")
            self.assertEqual(list(directory.iterdir()), [path])

    def test_password_requires_username(self):
        with self.assertRaises(ValueError):
            validate(dict(url="rtsp://camera/live", username="", password="secret"))


if __name__ == "__main__":
    unittest.main()
