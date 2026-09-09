import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "yani.camera"
    manageIpc: false
    property var anchorItem: null
    property var hostWidget: null
    property bool configuring: true
    property bool pinned: false
    property bool configured: false
    property string message: ""
    property string playbackMessage: ""
    property bool receivedFrame: false
    property double framesReceived: 0
    property real viewerWidth: 640
    property real viewerHeight: 500
    property bool sizeDirty: false
    property string sizeSaveError: ""
    property var config: ({url: "rtsp://10.0.0.233/ch2", username: "", password: ""})
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/rtsp-camera/config.json"
    readonly property bool streaming: opened && !configuring && configured
    readonly property bool live: streaming && frameWatchdog.running
        && player.playbackState === MediaPlayer.PlayingState

    function editSettings() {
        address.text = config.url
        username.text = config.username
        password.text = config.password
        message = ""
        configuring = true
        address.forceActiveFocus()
    }
    function streamUrl() {
        var url = config.url
        var split = url.indexOf("://") + 3
        var auth = config.username ? encodeURIComponent(config.username) + ":" + encodeURIComponent(config.password) + "@" : ""
        return url.slice(0, split) + auth + url.slice(split)
    }
    function play() {
        frameWatchdog.stop()
        connectionTimeout.stop()
        player.stop()
        receivedFrame = false
        framesReceived = 0
        playbackMessage = "Connecting…"
        player.source = streamUrl()
        connectionTimeout.restart()
        player.play()
    }
    function playbackStatus() {
        return JSON.stringify({streaming: streaming, live: live, receivedFrame: receivedFrame,
            framesReceived: framesReceived, timeoutRunning: connectionTimeout.running,
            playing: player.playbackState === MediaPlayer.PlayingState,
            hasAudio: player.hasAudio, muted: cameraAudio.muted,
            width: popup.contentWidth, height: popup.contentHeight,
            sizePending: sizeDirty || sizeWriter.running, sizeSaveError: sizeSaveError,
            pinned: pinned, inputWidth: popup.mask.width, inputHeight: popup.mask.height,
            message: playbackMessage})
    }
    function resizeViewer(width, height) {
        viewerWidth = Math.round(Math.min(popup.availableCardWidth, Math.max(420, width)))
        viewerHeight = Math.round(Math.min(popup.availableCardHeight, Math.max(440, height)))
        sizeDirty = true
        sizeSaveTimer.restart()
    }
    function saveViewerSize() {
        if (!sizeDirty || sizeWriter.running) return
        sizeWriter.pending = JSON.stringify({width: viewerWidth, height: viewerHeight})
        sizeDirty = false
        sizeWriter.running = true
    }
    function toggleAudio() {
        if (streaming && player.hasAudio) cameraAudio.muted = !cameraAudio.muted
    }
    onStreamingChanged: {
        if (streaming) play()
        else {
            frameWatchdog.stop()
            cameraAudio.muted = true
            connectionTimeout.stop()
            player.stop()
            player.source = ""
        }
    }
    onOpenedChanged: {
        if (!opened) {
            pinned = false
            sizeSaveTimer.stop()
            saveViewerSize()
        }
        if (opened && configuring) editSettings()
    }

    FileView {
        id: sizeFile
        path: root.configPath.replace(/config\.json$/, "view.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (root.sizeDirty || sizeWriter.running) return
            try {
                var size = JSON.parse(text())
                if (typeof size.width !== "number" || typeof size.height !== "number"
                    || !isFinite(size.width) || !isFinite(size.height)
                    || size.width < 1 || size.height < 1
                    || size.width > 32768 || size.height > 32768) return
                root.viewerWidth = size.width
                root.viewerHeight = size.height
            } catch (error) { /* Missing or invalid size uses the defaults. */ }
        }
    }
    Timer {
        id: sizeSaveTimer
        interval: 300
        onTriggered: root.saveViewerSize()
    }
    Process {
        id: sizeWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--view-size"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        onExited: function(code) {
            root.sizeSaveError = code === 0 ? "" : "Could not remember viewer size"
            if (root.sizeDirty) sizeSaveTimer.restart()
        }
    }
    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                var data = JSON.parse(text())
                if (typeof data.url !== "string" || !/^rtsps?:\/\//.test(data.url)
                    || typeof data.username !== "string" || typeof data.password !== "string") throw new Error()
                root.config = data
                root.configured = true
                if (!root.opened) root.configuring = false
                if (root.streaming) root.play()
            } catch (error) {
                root.configured = false
                root.configuring = true
                root.message = "Saved settings could not be read. Enter them again to repair the file."
            }
        }
        onLoadFailed: {
            root.configured = false
            root.configuring = true
        }
    }
    Process {
        id: writer
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, "")]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        stdout: StdioCollector { id: saveResult }
        onExited: function(code) {
            if (code !== 0) {
                root.message = saveResult.text.trim() || "Unable to save settings."
                return
            }
            root.config = {url: address.text.trim(), username: username.text, password: password.text}
            root.configured = true
            root.message = ""
            root.configuring = false
            password.text = ""
            configFile.reload()
        }
    }
    MediaPlayer {
        id: player
        videoOutput: video
        audioOutput: AudioOutput {
            id: cameraAudio
            muted: true
            volume: 1.0
        }
        onErrorOccurred: {
            frameWatchdog.stop()
            connectionTimeout.stop()
            root.playbackMessage = "Unable to connect. Check the address, credentials, and camera availability."
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                frameWatchdog.stop()
                connectionTimeout.stop()
                root.playbackMessage = "Stream ended. Click Retry to reconnect."
            }
        }
        onPlaybackStateChanged: {
            if (playbackState !== MediaPlayer.PlayingState) frameWatchdog.stop()
        }
    }
    Connections {
        target: video.videoSink
        function onVideoFrameChanged() {
            // Live RTSP feeds can render indefinitely without BufferedMedia.
            // A positive video size excludes the empty frame emitted on stop.
            if (!root.streaming || player.playbackState !== MediaPlayer.PlayingState
                || video.videoSink.videoSize.width <= 0 || video.videoSink.videoSize.height <= 0) return
            root.framesReceived += 1
            frameWatchdog.restart()
            if (!root.receivedFrame) {
                root.receivedFrame = true
                connectionTimeout.stop()
                root.playbackMessage = ""
            }
        }
    }
    // Only tracks freshness; it never stops or restarts the media player.
    Timer {
        id: frameWatchdog
        interval: 5000
    }
    Timer {
        id: connectionTimeout
        interval: 20000
        onTriggered: {
            if (!root.streaming || root.receivedFrame) return
            player.stop()
            player.source = ""
            root.playbackMessage = "Connection timed out. Check your settings and click Retry."
        }
    }

    CameraPopup {
        id: popup
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        pinned: root.pinned
        contentWidth: fittedContentWidth(root.viewerWidth)
        contentHeight: cappedContentHeight(root.viewerHeight)
        focusTarget: content

        FocusScope {
            id: content
            anchors.fill: parent
            Keys.onEscapePressed: root.close()
            ColumnLayout {
                anchors.fill: parent
                anchors.bottomMargin: 20
                spacing: 12
                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        text: root.configuring ? "Camera settings" : "Camera"
                        color: root.foreground
                        font.pixelSize: 20
                        font.bold: true
                        Layout.fillWidth: true
                    }
                    Button {
                        text: root.pinned ? "Unpin" : "Pin"
                        Accessible.name: root.pinned ? "Unpin camera" : "Keep camera above other windows"
                        ToolTip.visible: hovered
                        ToolTip.text: root.pinned ? "Return to popup mode" : "Stay visible while using other windows"
                        onClicked: root.pinned = !root.pinned
                    }
                    Button {
                        text: "Config"
                        Accessible.name: "Camera settings"
                        ToolTip.visible: hovered
                        ToolTip.text: "Connection settings"
                        enabled: !writer.running
                        onClicked: root.editSettings()
                    }
                    ToolButton {
                        text: "\u00d7"
                        Accessible.name: "Close camera"
                        onClicked: root.close()
                    }
                }
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.configuring ? 1 : 0
                    ColumnLayout {
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            color: "#080b10"
                            radius: 0
                            border.width: 1
                            border.color: root.foreground
                            clip: true
                            VideoOutput {
                                id: video
                                anchors.fill: parent
                                anchors.margins: 1
                                fillMode: VideoOutput.PreserveAspectFit
                            }
                            Label {
                                anchors.centerIn: parent
                                width: parent.width - 48
                                text: root.playbackMessage
                                visible: text !== ""
                                color: "white"
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                                padding: 12
                                background: Rectangle { color: "#dd080b10"; radius: 8 }
                            }
                        }
                        RowLayout {
                            Label {
                                text: root.sizeSaveError || "Live view"
                                color: root.foreground
                                font.strikeout: !root.live && !root.sizeSaveError
                                Layout.fillWidth: true
                            }
                            Button {
                                text: !player.hasAudio ? "No audio" : cameraAudio.muted ? "Audio off" : "Audio on"
                                enabled: root.streaming && player.hasAudio
                                Accessible.name: cameraAudio.muted ? "Unmute camera audio" : "Mute camera audio"
                                ToolTip.visible: hovered
                                ToolTip.text: !player.hasAudio ? "This stream has no audio track" : cameraAudio.muted ? "Click to unmute" : "Click to mute"
                                onClicked: root.toggleAudio()
                            }
                            Button { text: "Retry"; onClicked: root.play() }
                        }
                    }
                    ColumnLayout {
                        enabled: !writer.running
                        spacing: 8
                        Label { text: "RTSP address"; color: root.foreground }
                        TextField {
                            id: address
                            Layout.fillWidth: true
                            text: root.config.url
                            placeholderText: "rtsp://10.0.0.233:554/ch2"
                            selectByMouse: true
                            Accessible.name: "RTSP address"
                        }
                        Label { text: "Username"; color: root.foreground }
                        TextField {
                            id: username
                            Layout.fillWidth: true
                            selectByMouse: true
                            Accessible.name: "Username"
                        }
                        Label { text: "Password"; color: root.foreground }
                        TextField {
                            id: password
                            Layout.fillWidth: true
                            echoMode: TextInput.Password
                            selectByMouse: true
                            Accessible.name: "Password"
                        }
                        Label {
                            text: root.message || "Saved locally in a file readable only by your user account."
                            color: root.message ? "#f38ba8" : root.foreground
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            font.pixelSize: 12
                        }
                        Item { Layout.fillHeight: true }
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            Button {
                                text: "Cancel"
                                visible: root.configured
                                onClicked: { password.text = ""; root.configuring = false }
                            }
                            Button {
                                text: writer.running ? "Saving…" : "Save & connect"
                                onClicked: {
                                    root.message = ""
                                    writer.pending = JSON.stringify({url: address.text, username: username.text, password: password.text})
                                    writer.running = true
                                }
                            }
                        }
                    }
                }
            }
            // Use scene coordinates: the popup can shift as its size changes.
            // Local mouse coordinates alone would feed that shift into the drag.
            component ResizeGrip: MouseArea {
                property bool leftCorner: false
                property point dragStart
                property real startWidth: 0
                property real startHeight: 0
                width: 26
                height: 22
                anchors.bottom: parent.bottom
                hoverEnabled: true
                preventStealing: true
                cursorShape: leftCorner ? Qt.SizeBDiagCursor : Qt.SizeFDiagCursor
                acceptedButtons: Qt.LeftButton
                onPressed: function(mouse) {
                    dragStart = mapToItem(null, mouse.x, mouse.y)
                    startWidth = popup.contentWidth
                    startHeight = popup.contentHeight
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var point = mapToItem(null, mouse.x, mouse.y)
                    root.resizeViewer(startWidth + (leftCorner ? -1 : 1) * (point.x - dragStart.x),
                        startHeight + (point.y - dragStart.y))
                }
                onDoubleClicked: root.resizeViewer(640, 500)
                ToolTip.visible: containsMouse && !pressed
                ToolTip.text: "Drag to resize · double-click to reset"
                Text {
                    anchors.centerIn: parent
                    text: parent.leftCorner ? "◣" : "◢"
                    color: root.foreground
                    opacity: parent.containsMouse ? 1 : 0.5
                    font.pixelSize: 14
                }
            }
            ResizeGrip { anchors.left: parent.left; leftCorner: true }
            ResizeGrip { anchors.right: parent.right }
        }
    }
}
