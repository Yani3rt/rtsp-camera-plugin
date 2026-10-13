"""Run isolated Qt mouse/playback checks in an active Omarchy Wayland session."""
import os
import json
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="camera-checks-") as temporary:
    work = Path(temporary)
    # A configured camera already has this directory before opening its live feed.
    (work / "config" / "rtsp-camera").mkdir(parents=True)
    for name in ("Commons", "Ui"):
        (work / name).symlink_to(Path("/usr/share/omarchy/shell") / name)
    (work / "Camera").symlink_to(repo)
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
    if "--benchmark" not in sys.argv[1:]:
        assert checked == 16, f"Expected 16 rotation/style captures, got {checked}"
        print("PASS: all 16 rendered rotation/style pixel checks")
