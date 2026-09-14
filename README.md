# RTSP Camera for Omarchy

Surveillance-camera icon in the Omarchy bar. Click to view; Config in the upper right
opens the camera name, RTSP address, username, and masked password form. Save & connect
persists that camera and opens its stream. Cancel discards edits. Escape,
the close button, clicking outside, or clicking the bar icon closes the popup.

The top row has a camera dropdown alongside the pin and Config controls.
Select a name to switch feeds. Open **Config** and use **+** beside the camera
name field to add another named camera.
Selecting a camera in Config loads its settings without leaving the form.
Closing and reopening returns to the selected camera's main screen, discarding
unsaved Config edits. Setup is shown when no camera is configured.
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
Streaming stops while closed or editing settings. Audio starts muted. In every
video style and overlay, click the top-right waveform to mute or unmute; its slash
indicates muted audio. The waveform button also supports keyboard focus and Space.
Closing the popup or opening settings mutes audio again. Streams without an audio track disable the
audio control. The bottom-right palette icon opens the video theme preview. Failed connections, interrupted
streams, and five seconds without video frames trigger automatic reconnect.
Retries wait 2, 4, 8, 16, then at most 30 seconds between attempts; each connection
has a 20-second timeout. Receiving video resets the delay. Closing the viewer or
opening settings cancels retries.
Connection status is shown by the corner borders and terminal readouts. The audio
waveform and theme button have transparent backgrounds and themed interaction
states. Controls overlay the feed.

Requires Omarchy Quickshell, Qt 6 Multimedia, and Python 3 (no pip packages).
Video playback uses Qt Multimedia's installed backend:
https://doc.qt.io/qt-6/qtmultimedia-index.html

## Video appearance

Click the **palette icon** at the bottom-right of the feed to open the theme
section below the video. Choose **Video style** and adjust its sliders while the
feed keeps playing; changes preview immediately in this viewer:

- **Original**: unfiltered video, with no effect texture allocated.
- **Omarchy** (first-run default): gently blends the image into the current Omarchy palette.
- **Pixel**: crisp blocks with original colors.
- **Omarchy Pixel**: combines the pixel look with the theme tint.

The themed styles show a **Tint strength** slider (default 35%). Zero preserves
the original colors; 100% fully maps the image into the theme palette. Theme
changes update the filter automatically. Text and video controls remain sharp.

**Pixel** and **Omarchy Pixel** show a **Pixel size** slider from 1 to 16 px.
Higher values make larger blocks and a stronger pixelated look. The default is
3 px, including for settings saved before this slider was added. Click **Apply**
to save the size for every camera and monitor.

Use **Overlay** to add a theme-colored camera display to any video style:

- **Default**: corner borders and the waveform mute button.
- **Coder**: Default plus right-side activity dots pulsing up and down and a lower
  terminal readout with stream status and a received-frame counter.
- **Hackerman**: Coder plus scanlines, a smooth scanning band sweeping down and back up
  every six seconds, a top terminal header, and a blinking block cursor.
  The top header is transparent. Coder and Hackerman show their lower console in
  larger viewers, beside the theme button, with a background at 39% opacity.

Corner borders are red while offline or connecting and return to the theme accent
when video frames arrive. They remain visible even before the first frame.
Existing saved video styles are preserved. Older overlay choices migrate from
Off to Default, Sci-fi HUD to Coder, and Hacker terminal to Hackerman.

Overlays preview and save with the other appearance settings. They fit the video
image, leaving letterboxing alone, and sit behind playback controls. They use
bounded geometry with no extra video capture texture or per-frame Python work.
The video border follows the theme accent. Playback controls stay inside the video
when resizing, inset from overlay corners, with transparent backgrounds.
The scan band uses a native looping animation. Coder and Hackerman share
one 8 Hz decoration clock and sample the frame counter once per second. The universal
waveform button has its own 8 Hz clock; it is simulated and never analyzes audio.
The Hackerman sweep pauses in place while offline and resumes when video returns.
Other decorations continue while visible. Hiding the overlay stops its animations,
and closing the viewer releases it. Default's corner borders need no animation clock.

Appearance applies to every camera and monitor and is saved separately in
`~/.config/rtsp-camera/appearance.json` (or under `$XDG_CONFIG_HOME`). **Apply** saves
the preview and completely hides the theme section, returning the space to the
video. Click the palette icon again to reopen it with the saved values. Dismissing
the section with that icon, closing the viewer, or opening camera **Config** discards
unapplied changes. Other monitors see only the applied settings. Theme controls no
longer appear in Config. Closing the viewer or opening Config unloads the effect;
opening the theme section keeps playback and audio running.

Effects use one GPU capture texture and one shader, with no Python frame processing
or transcoding. They add rendering work and video memory, and do not reduce stream
decoding cost. A working Qt Quick GPU backend is required for filtered styles.

## Install

Copy `manifest.json`, `Widget.qml`, `CameraPanel.qml`, `CameraPopup.qml`, `AudioWaveform.qml`, `VideoEffect.qml`, `VideoOverlay.qml`, `TerminalOverlay.qml`,
`config.py`, and the `shaders/` directory into `~/.config/omarchy/plugins/yani.camera/`,
then run:

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
the playback recovery checks. This still checks rendered effect pixels, live palette
updates, appearance persistence, and the settings controls.

`python3 tests/run_qml_checks.py --benchmark` compares process CPU usage and received
frame rate for all four styles using a generated 320×240, 10 fps clip. It is a small
local comparison, not a GPU benchmark or a guarantee for higher-resolution cameras.

The compiled Qt 6 shader is included, so installation needs no shader compiler.
After editing `shaders/video.frag`, rebuild it with Qt Shader Tools:

```sh
/usr/lib/qt6/bin/qsb --glsl '100 es,120,150' --hlsl 50 --msl 12 \
  -o shaders/video.frag.qsb shaders/video.frag
```

## Disable

```sh
omarchy plugin disable yani.camera
```

The saved connection is retained when the plugin is disabled.
