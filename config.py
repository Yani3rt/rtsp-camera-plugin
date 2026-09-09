"""Validate and atomically save camera settings; secrets arrive over stdin."""
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit


def validate(data):
    if not isinstance(data, dict) or any(
        not isinstance(data.get(key), str) for key in ("url", "username", "password")
    ):
        raise ValueError("Fill in the connection fields.")
    address = data["url"].strip()
    try:
        url = urlsplit(address)
        port = url.port
        host = url.hostname
    except ValueError:
        raise ValueError("Use a numeric port, for example :554/ch2.") from None
    if url.scheme not in ("rtsp", "rtsps") or not host:
        raise ValueError("Enter an rtsp:// or rtsps:// camera address.")
    if any(c.isspace() or ord(c) < 32 for c in address) or url.fragment:
        raise ValueError("The address cannot contain spaces or a fragment.")
    if url.username is not None or url.password is not None:
        raise ValueError("Enter credentials in the username and password fields.")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("The port must be between 1 and 65535.")
    if data["password"] and not data["username"]:
        raise ValueError("Enter a username for this password.")
    return {"url": address, "username": data["username"], "password": data["password"]}


def validate_size(data):
    if not isinstance(data, dict) or any(
        type(data.get(key)) is not int or not 1 <= data[key] <= 32768
        for key in ("width", "height")
    ):
        raise ValueError("Invalid viewer size.")
    return {"width": data["width"], "height": data["height"]}


def save(data, directory, filename="config.json"):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".config-", dir=directory)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, directory / filename)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        size_only = sys.argv[1:] == ["--view-size"]
        data = (validate_size if size_only else validate)(json.loads(sys.stdin.readline()))
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        save(data, base / "rtsp-camera", "view.json" if size_only else "config.json")
    except ValueError as error:
        # Only our validation messages are safe to display; JSON errors are generic.
        print("Invalid settings." if isinstance(error, json.JSONDecodeError) else str(error))
        sys.exit(1)
    except OSError:
        print("Could not save camera settings. Check directory permissions.")
        sys.exit(1)
