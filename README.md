# RTSP Camera for Omarchy

Surveillance-camera icon in the Omarchy bar. Click to view; Config in the upper right
opens the RTSP address, username, and masked password form. Save & connect
persists the connection and opens the stream. Cancel discards edits. Escape,
the close button, clicking outside, or clicking the bar icon closes the popup.

Drag either bottom corner to resize the viewer; double-click a corner to
reset its size. Dimensions are saved in `~/.config/rtsp-camera/view.json`
(or under `$XDG_CONFIG_HOME`) and shared across monitors. They survive closing
and shell restarts, and fit within the current monitor. Video retains its
aspect ratio while resizing.
Click Pin to keep the camera above other windows while interacting with your
desktop. Unpin restores outside-click dismissal. Close or Escape still closes
the pinned viewer. Pinning lasts until the viewer is closed.
Streaming stops while closed or editing settings. Audio starts muted; click
Audio off / Audio on to unmute or mute. Closing the popup or opening settings
mutes it again. Streams without an audio track show a disabled No audio button. Retry
reconnects after a failure; initial connections time out after 20 seconds.
Live view is struck through while disconnected, connecting, or after five
seconds without a video frame. It returns to normal when frames resume;
this status check does not interrupt playback.

Requires Omarchy Quickshell, Qt 6 Multimedia, and Python 3 (no pip packages).
Video playback uses Qt Multimedia's installed backend:
https://doc.qt.io/qt-6/qtmultimedia-index.html

## Install

Copy `manifest.json`, `Widget.qml`, `CameraPanel.qml`, `CameraPopup.qml`, and `config.py` into
`~/.config/omarchy/plugins/yani.camera/`, then run:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable yani.camera --section right
```

First click opens settings. The suggested address is
`rtsp://10.0.0.233/ch2`; verify the exact stream path with your camera.
A custom port must be numeric, for example `rtsp://10.0.0.233:554/ch2`.
Enter credentials in the separate fields, not in the URL.

Settings live at `$XDG_CONFIG_HOME/rtsp-camera/config.json` (normally
`~/.config/rtsp-camera/config.json`). The password is stored as plaintext
in a mode-0600 file, inside a mode-0700 directory created on first save.
Credentials are passed to the save helper over stdin, not command arguments.
They are percent-encoded into the playback URL in memory. The plugin displays
generic playback errors; avoid enabling Qt/FFmpeg debug logging with real
credentials, since the backend may log stream URLs. RTSP itself is not
encrypted; use RTSPS if supported by the camera.

## Verify

```sh
python3 -m unittest discover -s . -p 'test_*.py'
```

## Disable

```sh
omarchy plugin disable yani.camera
```

The saved connection is retained when the plugin is disabled.
