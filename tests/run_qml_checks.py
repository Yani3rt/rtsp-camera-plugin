"""Run isolated Qt mouse/playback checks in an active Omarchy Wayland session."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="camera-checks-") as temporary:
    work = Path(temporary)
    for name in ("Commons", "Ui"):
        (work / name).symlink_to(Path("/usr/share/omarchy/shell") / name)
    (work / "Camera").symlink_to(repo)
    shutil.copy2(repo / "tests/CameraChecks.qml", work / "shell.qml")
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=10", "-t", "20", "-c:v", "mpeg4",
        str(work / "sample.mp4")
    ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=1/10", "-t", "20", "-c:v", "mpeg4",
        str(work / "stall.mp4")
    ], check=True)
    environment = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"),
                       QT_QUICK_CONTROLS_STYLE="Basic")
    if "--ui-only" in sys.argv[1:]:
        environment["CAMERA_TEST_UI_ONLY"] = "1"
    result = subprocess.run(["quickshell", "-p", str(work), "--no-color"],
                            env=environment, capture_output=True, text=True, timeout=65)
    output = result.stdout + result.stderr
    print(output)
    if result.returncode or "CAMERA_CHECKS_PASSED" not in output or "CAMERA_CHECKS_FAILED" in output:
        raise SystemExit(1)
