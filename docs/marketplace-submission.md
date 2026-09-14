### Repository URL

https://github.com/Yani3rt/rtsp-camera-plugin

### Category

Widgets

### Tags

bar, media, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

RTSP camera bar widget with multiple saved cameras, mute controls, automatic
reconnect, a pinnable/resizable viewer, and live appearance previews. Video styles
include Omarchy palette tint and adjustable pixel effects; Default, Coder, and
Hackerman overlays work with every style.

Requires Omarchy 4's Quickshell shell, Qt 6 Multimedia with a suitable backend
(tested with qt6-multimedia-ffmpeg), and Python 3 without pip dependencies.
Tested with Omarchy 4.0.3, Quickshell 0.3.1, and Qt 6.11.2. The shader is bundled.
No installer script, privileged commands, background service, or runtime code
downloads. Users enter their own camera address and credentials in the UI.

The plugin invokes its bundled Python helper for local settings. Credentials
are saved in a mode-0600 file in a mode-0700 configuration directory, passed to
the helper on stdin, and used by Qt Multimedia to connect to the selected camera.
Removal retains that configuration; the README explains how to erase it.

MIT licensed, with upstream Omarchy popup attribution retained. The root preview
is a still from the README recording showing the owner's pixelated camera feed,
explicitly approved by the owner for public use.
The animated waveform is decorative and does not analyze audio.

### Submission checklist

- [ ] The repository is public and contains installation and removal instructions.
- [ ] I have documented the plugin license and any external dependencies.
- [ ] I confirm that I own or have permission to submit this plugin and its preview assets.
- [ ] The plugin does not overwrite user configuration without explicit consent.
- [ ] I understand that approval is for listing and is not a security review.
