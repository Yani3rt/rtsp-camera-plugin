import json
from pathlib import Path
import stat
import tempfile
import unittest

from config import save, validate, validate_size


class SettingsTests(unittest.TestCase):
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
