"""Validate and atomically save camera settings; secrets arrive over stdin."""
import json
import fcntl
import os
from pathlib import Path
import sys
import tempfile
import uuid
from urllib.parse import quote, urlsplit


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


def validate_position(data):
    if (not isinstance(data, dict) or not isinstance(data.get("screen"), str)
            or not data["screen"] or len(data["screen"]) > 128
            or any(type(data.get(key)) is not int or not 0 <= data[key] <= 32768
                   for key in ("x", "y"))):
        raise ValueError("Invalid viewer position.")
    return {key: data[key] for key in ("screen", "x", "y")}


def position_filename(screen):
    # Match QML's encodeURIComponent, keeping monitor names within one filename.
    return "position-" + quote(screen, safe="-_.!~*'()") + ".json"


def normalize_library(data):
    if isinstance(data, dict) and "cameras" not in data:
        return dict(version=2, selectedId="default",
                    cameras=[dict(validate(data), id="default", name="Camera 1")])
    if (not isinstance(data, dict) or data.get("version") != 2
            or not isinstance(data.get("cameras"), list) or len(data["cameras"]) > 32):
        raise ValueError("Invalid saved camera profiles.")
    cameras, ids, names = [], set(), set()
    for camera in data["cameras"]:
        connection = validate(camera)
        identity, name = camera.get("id"), camera.get("name")
        if not isinstance(identity, str) or not identity or len(identity) > 64 or identity in ids:
            raise ValueError("Invalid camera identifier.")
        if not isinstance(name, str) or not name.strip() or len(name.strip()) > 64 or any(ord(c) < 32 for c in name):
            raise ValueError("Enter a camera name (up to 64 characters).")
        name = name.strip()
        if name.casefold() in names:
            raise ValueError("A camera with that name already exists.")
        ids.add(identity)
        names.add(name.casefold())
        cameras.append(dict(connection, id=identity, name=name))
    selected = data.get("selectedId")
    if not isinstance(selected, str) or (cameras and selected not in ids) or (not cameras and selected != ""):
        raise ValueError("Invalid selected camera.")
    return dict(version=2, selectedId=selected, cameras=cameras)


def update_library(operation, directory):
    if not isinstance(operation, dict) or operation.get("action") not in ("save", "select", "delete"):
        raise ValueError("Invalid camera operation.")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Merge operations under a lock so separate monitor widgets cannot lose profiles.
    fd = os.open(directory / ".profiles.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            library = normalize_library(json.loads((directory / "config.json").read_text()))
        except FileNotFoundError:
            library = dict(version=2, selectedId="", cameras=[])
        cameras = library["cameras"]
        action = operation["action"]
        if action == "save":
            camera = operation.get("camera")
            if not isinstance(camera, dict):
                raise ValueError("Fill in the camera fields.")
            camera = dict(camera)
            identity = camera.get("id")
            if identity:
                index = next((i for i, saved in enumerate(cameras) if saved["id"] == identity), None)
                if index is None:
                    raise ValueError("This camera no longer exists. Add it again.")
                cameras[index] = camera
            else:
                camera["id"] = uuid.uuid4().hex
                cameras.append(camera)
            library["selectedId"] = camera["id"]
        else:
            identity = operation.get("id")
            if not any(camera["id"] == identity for camera in cameras):
                raise ValueError("This camera no longer exists.")
            if action == "delete":
                library["cameras"] = [camera for camera in cameras if camera["id"] != identity]
                if library["selectedId"] == identity:
                    library["selectedId"] = library["cameras"][0]["id"] if library["cameras"] else ""
            else:
                library["selectedId"] = identity
        library = normalize_library(library)
        save(library, directory)
        return library


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
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        if sys.argv[1:] == ["--profiles"]:
            library = update_library(json.loads(sys.stdin.readline()), base / "rtsp-camera")
            print(json.dumps(library))
            sys.exit(0)
        size_only = sys.argv[1:] == ["--view-size"]
        position_only = sys.argv[1:] == ["--position"]
        validator = validate_position if position_only else validate_size if size_only else validate
        data = validator(json.loads(sys.stdin.readline()))
        filename = position_filename(data["screen"]) if position_only else "view.json" if size_only else "config.json"
        save(data, base / "rtsp-camera", filename)
    except ValueError as error:
        # Only our validation messages are safe to display; JSON errors are generic.
        print("Invalid settings." if isinstance(error, json.JSONDecodeError) else str(error))
        sys.exit(1)
    except OSError:
        print("Could not save camera settings. Check directory permissions.")
        sys.exit(1)
