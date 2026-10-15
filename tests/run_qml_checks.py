"""Run isolated Qt mouse/playback checks in an active Omarchy Wayland session."""
import os
import json
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import size_filename, position_filename

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="camera-checks-") as temporary:
    work = Path(temporary)
    # A configured camera already has this directory before opening its live feed.
    (work / "config" / "rtsp-camera").mkdir(parents=True)
    for name in ("Commons", "Ui"):
        (work / name).symlink_to(Path("/usr/share/omarchy/shell") / name)
    camera_copy = work / "Camera"
    shutil.copytree(repo, camera_copy, ignore=shutil.ignore_patterns('.git', '__pycache__'))
    # Only this disposable copy uses a fixed fixture, never the real clipboard.
    shutil.copy2(repo / 'clipboard.py', camera_copy / 'bounded_original.py')
    shutil.copy2(repo / 'tests/clipboard_fixture.py', camera_copy / 'clipboard.py')
    clipboard_fixture = work / 'clipboard-fixture.json'
    clipboard_fixture.write_text('{"mode":"small"}')
    shutil.copy2(repo / "tests/CameraChecks.qml", work / "shell.qml")
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=10", "-f", "lavfi", "-i",
        "anullsrc=channel_layout=mono:sample_rate=44100", "-t", "60",
        "-c:v", "mpeg4", "-c:a", "aac",
        str(work / "sample.mp4")
    ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=1/10", "-t", "20", "-c:v", "mpeg4",
        str(work / "stall.mp4")
    ], check=True)
    environment = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"),
                       QT_QUICK_CONTROLS_STYLE="Basic", CAMERA_CLOCK_TICKS=str(os.sysconf("SC_CLK_TCK")))
    rotation_captures = work / "rotation-captures"
    rotation_captures.mkdir()
    environment["CAMERA_TEST_ROTATION_DIR"] = str(rotation_captures)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=red:s=320x240:r=10,drawbox=x=160:y=0:w=160:h=120:color=lime:t=fill,"
        "drawbox=x=0:y=120:w=160:h=120:color=blue:t=fill,"
        "drawbox=x=160:y=120:w=160:h=120:color=white:t=fill",
        "-t", "30", "-c:v", "mpeg4", str(work / "rotation.mp4")
    ], check=True)
    environment['CAMERA_TEST_CLIPBOARD_FIXTURE'] = str(clipboard_fixture)
    if '--clipboard-only' in sys.argv[1:]:
        environment['CAMERA_TEST_CLIPBOARD_ONLY'] = '1'
    if "--lifecycle-only" in sys.argv[1:]:
        environment["CAMERA_TEST_LIFECYCLE_ONLY"] = "1"
        (work / "config" / "rtsp-camera" / "config.json").write_text(json.dumps(dict(
            version=2, selectedId="lifecycle", cameras=[dict(id="lifecycle", name="Lifecycle",
                url="rtsp://127.0.0.1:1/lifecycle", username="", password="")])))
    if "--pin-only" in sys.argv[1:]:
        environment["CAMERA_TEST_PIN_ONLY"] = "1"
    legacy = {}
    if "--pin-only" in sys.argv[1:]:
        for name, value in {"view.json": {"width": 880, "height": 650},
                            "position-DP-1.json": {"screen": "DP-1", "x": 400, "y": 300}}.items():
            path = work / "config" / "rtsp-camera" / name
            legacy[path] = json.dumps(value).encode()
            path.write_bytes(legacy[path])
    if "--rotation-only" in sys.argv[1:]:
        environment["CAMERA_TEST_ROTATION_ONLY"] = "1"
    if "--ui-only" in sys.argv[1:]:
        environment["CAMERA_TEST_UI_ONLY"] = "1"
    if "--benchmark" in sys.argv[1:]:
        environment["CAMERA_TEST_BENCHMARK"] = "1"
    if "--capture" in sys.argv[1:]:
        captures = Path("/tmp/rtsp-camera-captures")
        captures.mkdir(exist_ok=True)
        environment["CAMERA_TEST_CAPTURE_DIR"] = str(captures)
    result = subprocess.run(["quickshell", "-p", str(work), "--no-color"],
                            env=environment, capture_output=True, text=True, timeout=130)
    output = result.stdout + result.stderr
    print(output)
    if result.returncode or "CAMERA_CHECKS_PASSED" not in output or "CAMERA_CHECKS_FAILED" in output:
        raise SystemExit(1)
    for path, before in legacy.items():
        assert path.read_bytes() == before, f"Legacy geometry changed: {path.name}"
    for line in output.splitlines():
        if "GEOMETRY_FILES " not in line:
            continue
        sample = json.loads(line.split("GEOMETRY_FILES ", 1)[1])
        directory = work / "config" / "rtsp-camera"
        for key, width, height, x, y in (("a", 710, 550, 150, 170), ("b", 670, 510, 230, 250)):
            identity = sample[key]
            assert json.loads((directory / size_filename(identity)).read_text()) == dict(cameraId=identity, width=width, height=height)
            assert json.loads((directory / position_filename(sample["screen"], identity)).read_text()) == dict(cameraId=identity, screen=sample["screen"], x=x, y=y)
        monitor = "Geometry test monitor/2"
        assert json.loads((directory / position_filename(monitor, sample["a"])).read_text()) == dict(cameraId=sample["a"], screen=monitor, x=190, y=210)
        print("PASS: exact per-camera/per-monitor geometry files read back" + ("; legacy files unchanged" if legacy else ""))
        library = dict(version=2, selectedId=sample["a"], cameras=[
            dict(id=sample[key], name="Restart " + key, url="rtsp://127.0.0.1:1/restart", username="", password="")
            for key in ("a", "b")])
        (directory / "config.json").write_text(json.dumps(library))
        restarted = subprocess.run(["quickshell", "-p", str(work), "--no-color"],
            env=dict(environment, CAMERA_TEST_GEOMETRY_RESTART=json.dumps(sample)),
            capture_output=True, text=True, timeout=20)
        restart_output = restarted.stdout + restarted.stderr
        print(restart_output)
        assert restarted.returncode == 0 and "CAMERA_CHECKS_PASSED" in restart_output and "CAMERA_CHECKS_FAILED" not in restart_output
    checked = 0
    for line in output.splitlines():
        if "ROTATION_PIXELS " not in line:
            continue
        sample = json.loads(line.split("ROTATION_PIXELS ", 1)[1])
        path = rotation_captures / (sample["name"] + ".png")
        width, height = struct.unpack(">II", path.read_bytes()[16:24])
        pixels = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"
        ])
        for (x, y), expected in zip(sample["points"], sample["expected"]):
            assert 0 <= x < width and 0 <= y < height, sample
            offset = (y * width + x) * 3
            r, g, b = pixels[offset:offset + 3]
            matches = {"r": r > g + 30 and r > b + 30, "g": g > r + 30 and g > b + 30,
                       "b": b > r + 30 and b > g + 30, "w": min(r, g, b) > 120}
            assert matches[expected], (sample["name"], expected, (r, g, b))
        checked += 1
    if not any(flag in sys.argv[1:] for flag in ("--benchmark", "--pin-only", "--lifecycle-only", "--clipboard-only")):
        assert checked == 16, f"Expected 16 rotation/style captures, got {checked}"
        print("PASS: all 16 rendered rotation/style pixel checks")
    # Include the lifecycle regression in the default suite, and exercise the
    # missing-file first-run path in a separate fresh shell as well.
    full_suite = not sys.argv[1:]
    if full_suite:
        security = subprocess.run(['quickshell', '-p', str(work), '--no-color'],
            env=dict(environment, CAMERA_TEST_CLIPBOARD_ONLY='1'),
            capture_output=True, text=True, timeout=20)
        security_output = security.stdout + security.stderr
        print(security_output)
        assert security.returncode == 0 and 'CAMERA_CHECKS_PASSED' in security_output and 'CAMERA_CHECKS_FAILED' not in security_output
    if full_suite or "--lifecycle-only" in sys.argv[1:]:
        library_path = work / "config" / "rtsp-camera" / "config.json"
        for mode in (("1", "missing") if full_suite else ("missing",)):
            if mode == "1":
                library_path.write_text(json.dumps(dict(version=2, selectedId="lifecycle", cameras=[dict(
                    id="lifecycle", name="Lifecycle", url="rtsp://127.0.0.1:1/lifecycle", username="", password="")])))
            else:
                library_path.unlink(missing_ok=True)
            lifecycle = subprocess.run(["quickshell", "-p", str(work), "--no-color"],
                env=dict(environment, CAMERA_TEST_LIFECYCLE_ONLY=mode),
                capture_output=True, text=True, timeout=20)
            lifecycle_output = lifecycle.stdout + lifecycle.stderr
            print(lifecycle_output)
            assert lifecycle.returncode == 0 and "CAMERA_CHECKS_PASSED" in lifecycle_output and "CAMERA_CHECKS_FAILED" not in lifecycle_output
