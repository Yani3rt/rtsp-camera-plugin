# RTSP Camera for Omarchy

Surveillance-camera icon in the Omarchy bar. Click to view; Config in the upper right
opens the camera name, RTSP address, username, and masked password form. Save & connect
persists that camera and opens its stream. Cancel discards edits. Escape,
the close button, clicking outside, or clicking the bar icon closes the popup.

The top row has a camera dropdown alongside the pin and Config controls.
Select a name to switch feeds. Open **Config** and use **+** beside the camera
name field to add another named camera.
Selecting a camera in Config loads its settings without leaving the form.
The last selection is remembered and shared across monitor widgets.
Config edits the selected camera, including its name; Delete
requires a second click to confirm. Names must be unique (up to 64 characters),
with up to 32 saved cameras. Switching cameras mutes audio and resets reconnect
attempts. An existing single-camera setup appears as **Camera 1** and is migrated
without changing its connection details when profiles are first saved.

Drag either bottom corner to resize the viewer; double-click a corner to
reset its size. Dimensions are saved in `~/.config/rtsp-camera/view.json`
(or under `$XDG_CONFIG_HOME`) and shared across monitors. They survive closing
and shell restarts, and fit within the current monitor. Video retains its
aspect ratio while resizing.
Turn on the square pin switch to keep the camera above other windows while using
your desktop. Turning it off restores outside-click dismissal. Close or Escape still closes
the pinned viewer. While pinned, drag the empty header space to move the viewer anywhere
within the current screen. Unpinning returns it to the bar icon. The dragged
position is saved separately for each monitor in `position-<monitor>.json` under
the camera config directory. Pinning again restores that position, including
after closing or restarting the shell, clamped to the current screen size.
The pin switch itself resets when the viewer is closed.
While pinned, the surrounding panel and header fade out when the pointer leaves
the viewer, and fade back in on hover. The camera feed and its overlay controls
remain visible, with no change to the feed's size or position.
Streaming stops while closed or editing settings. Audio starts muted; click
the speaker icon at the bottom-right of the feed to unmute or mute. Closing the popup or opening settings
mutes it again. Streams without an audio track disable the speaker button. The
reconnect icon beside it retries immediately. Failed connections, interrupted
streams, and five seconds without video frames trigger automatic reconnect.
Retries wait 2, 4, 8, 16, then at most 30 seconds between attempts; each connection
has a 20-second timeout. Receiving video resets the delay. Closing the viewer or
opening settings cancels retries.
The bottom-left status pill is green (LIVE) while frames are arriving and red
(OFFLINE) while disconnected, connecting, or after five seconds without a video
frame. Controls overlay the feed.

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

In an active Omarchy Wayland session, run the integration checks (requires
FFmpeg and QtTest). These use temporary settings, a refused localhost connection,
and generated video, without reading the saved camera credentials:

```sh
python3 tests/run_qml_checks.py
```

For layout-only changes, use `python3 tests/run_qml_checks.py --ui-only` to skip
the playback recovery checks.

## Disable

```sh
omarchy plugin disable yani.camera
```

The saved connection is retained when the plugin is disabled.
