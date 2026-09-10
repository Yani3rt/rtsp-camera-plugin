import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
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
    property var cameras: []
    property string selectedCameraId: ""
    property string editingCameraId: ""
    property bool deleteArmed: false
    readonly property int selectedCameraIndex: cameras.findIndex(function(camera) { return camera.id === root.selectedCameraId })
    property string message: ""
    property string playbackMessage: ""
    property bool receivedFrame: false
    property double framesReceived: 0
    property real viewerWidth: 640
    property real viewerHeight: 500
    property bool sizeDirty: false
    property string sizeSaveError: ""
    property string positionSaveError: ""
    property var pendingPosition: null
    property int retryAttempt: 0
    property bool changingPlayback: false
    property var config: ({url: "rtsp://10.0.0.233/ch2", username: "", password: ""})
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/rtsp-camera/config.json"
    readonly property bool streaming: opened && !configuring && configured
    readonly property bool live: streaming && frameWatchdog.running
        && player.playbackState === MediaPlayer.PlayingState

    function editSettings(newCamera) {
        editingCameraId = newCamera === true ? "" : selectedCameraId
        cameraName.text = newCamera === true ? "" : selectedCameraIndex >= 0 ? cameras[selectedCameraIndex].name : "Camera 1"
        address.text = newCamera === true ? "rtsp://" : config.url
        username.text = newCamera === true ? "" : config.username
        password.text = newCamera === true ? "" : config.password
        deleteArmed = false
        message = ""
        configuring = true
        cameraName.forceActiveFocus()
    }
    function applyLibrary(data) {
        // Existing single-camera settings migrate when first edited or selected.
        if (!Array.isArray(data.cameras)) {
            data = {version: 2, selectedId: "default", cameras: [{id: "default", name: "Camera 1",
                url: data.url, username: data.username, password: data.password}]}
        }
        if (data.version !== 2 || data.cameras.length > 32 || typeof data.selectedId !== "string") throw new Error()
        var ids = Object.create(null), names = Object.create(null)
        data.cameras.forEach(function(camera) {
            if (!camera || typeof camera.id !== "string" || !camera.id || ids[camera.id]
                || typeof camera.name !== "string" || !camera.name.trim() || names[camera.name.toLowerCase()]
                || typeof camera.url !== "string" || !/^rtsps?:\/\//.test(camera.url)
                || typeof camera.username !== "string" || typeof camera.password !== "string") throw new Error()
            ids[camera.id] = true
            names[camera.name.toLowerCase()] = true
        })
        var selected = data.cameras.find(function(camera) { return camera.id === data.selectedId })
        if ((data.cameras.length && !selected) || (!data.cameras.length && data.selectedId !== "")) throw new Error()
        var changed = selectedCameraId !== data.selectedId
            || (selected && (selected.url !== config.url || selected.username !== config.username || selected.password !== config.password))
        var wasStreaming = streaming
        cameras = data.cameras
        selectedCameraId = data.selectedId
        config = selected || {url: "rtsp://", username: "", password: ""}
        configured = !!selected
        if (!opened || !configured) configuring = !configured
        if (changed) cameraAudio.muted = true
        if (changed && wasStreaming && streaming) play()
    }
    function runProfileOperation(operation) {
        if (writer.running) return
        message = ""
        writer.stayInSettings = configuring && operation.action === "select"
        writer.pending = JSON.stringify(operation)
        writer.running = true
    }
    function selectCamera(index) {
        if (writer.running || index < 0 || index >= cameras.length) return
        if (index === selectedCameraIndex) {
            if (configuring) editSettings()
            return
        }
        runProfileOperation({action: "select", id: cameras[index].id})
    }
    function submitProfile() {
        runProfileOperation({action: "save", camera: {id: editingCameraId, name: cameraName.text,
            url: address.text, username: username.text, password: password.text}})
    }
    function streamUrl() {
        var url = config.url
        var split = url.indexOf("://") + 3
        var auth = config.username ? encodeURIComponent(config.username) + ":" + encodeURIComponent(config.password) + "@" : ""
        return url.slice(0, split) + auth + url.slice(split)
    }
    function play(resetRetry) {
        if (!streaming) return
        reconnectTimer.stop()
        if (resetRetry !== false) retryAttempt = 0
        frameWatchdog.stop()
        connectionTimeout.stop()
        changingPlayback = true
        player.stop()
        player.source = ""
        receivedFrame = false
        framesReceived = 0
        playbackMessage = "Connecting…"
        player.source = streamUrl()
        changingPlayback = false
        connectionTimeout.restart()
        player.play()
    }
    function scheduleReconnect(reason) {
        if (!streaming || changingPlayback || reconnectTimer.running) return
        frameWatchdog.stop()
        connectionTimeout.stop()
        changingPlayback = true
        player.stop()
        player.source = ""
        changingPlayback = false
        reconnectTimer.interval = Math.min(30000, 2000 * Math.pow(2, retryAttempt))
        retryAttempt = Math.min(retryAttempt + 1, 5)
        playbackMessage = reason + " Retrying in " + reconnectTimer.interval / 1000 + "s…"
        reconnectTimer.start()
    }
    function playbackStatus() {
        return JSON.stringify({streaming: streaming, live: live, receivedFrame: receivedFrame,
            framesReceived: framesReceived, timeoutRunning: connectionTimeout.running,
            playing: player.playbackState === MediaPlayer.PlayingState,
            hasAudio: player.hasAudio, muted: cameraAudio.muted,
            width: popup.contentWidth, height: popup.contentHeight,
            sizePending: sizeDirty || sizeWriter.running, sizeSaveError: sizeSaveError,
            pinned: pinned, inputWidth: popup.mask.width, inputHeight: popup.mask.height,
            x: popup.cardOrigin.x, y: popup.cardOrigin.y,
            reconnectPending: reconnectTimer.running, retryAttempt: retryAttempt,
            retryDelay: reconnectTimer.interval,
            positionPending: !!pendingPosition || positionWriter.running,
            positionSaveError: positionSaveError,
            cameraCount: cameras.length, selectedCameraId: selectedCameraId,
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
    function saveViewerPosition() {
        if (!pendingPosition || positionWriter.running) return
        positionWriter.pending = JSON.stringify(pendingPosition)
        pendingPosition = null
        positionWriter.running = true
    }
    onStreamingChanged: {
        if (streaming) play()
        else {
            reconnectTimer.stop()
            retryAttempt = 0
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
            positionSaveTimer.stop()
            saveViewerPosition()
        }
        if (opened && configuring) editSettings()
    }

    FileView {
        id: positionFile
        readonly property string monitorName: popup.screen ? popup.screen.name : ""
        path: monitorName ? root.configPath.replace(/config\.json$/, "position-" + encodeURIComponent(monitorName) + ".json") : ""
        watchChanges: true
        printErrors: false
        onPathChanged: popup.savedPosition = null
        onFileChanged: reload()
        onLoaded: {
            if (root.pendingPosition || positionWriter.running) return
            try {
                var saved = JSON.parse(text())
                if (saved.screen !== monitorName || typeof saved.x !== "number" || typeof saved.y !== "number"
                    || !isFinite(saved.x) || !isFinite(saved.y)
                    || saved.x < 0 || saved.y < 0 || saved.x > 32768 || saved.y > 32768) return
                popup.savedPosition = Qt.point(saved.x, saved.y)
                if (popup.pinned) popup.pinnedOrigin = popup.boundedOrigin(popup.savedPosition)
            } catch (error) { /* No saved position: use the bar anchor. */ }
        }
    }
    Timer {
        id: positionSaveTimer
        interval: 300
        onTriggered: root.saveViewerPosition()
    }
    Process {
        id: positionWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--position"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        onExited: function(code) {
            root.positionSaveError = code === 0 ? "" : "Could not remember viewer position"
            if (root.pendingPosition) positionSaveTimer.restart()
        }
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
            if (writer.running) return
            try {
                root.applyLibrary(JSON.parse(text()))
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
        property bool stayInSettings: false
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--profiles"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        stdout: StdioCollector { id: saveResult }
        onExited: function(code) {
            if (code !== 0) {
                root.message = saveResult.text.trim() || "Unable to save settings."
                return
            }
            try { root.applyLibrary(JSON.parse(saveResult.text)) }
            catch (error) { root.message = "Saved camera profiles could not be read."; return }
            root.message = ""
            root.configuring = stayInSettings || !root.configured
            password.text = ""
            root.deleteArmed = false
            if (!root.configured) root.editSettings(true)
            else if (stayInSettings) root.editSettings()
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
            root.scheduleReconnect("Unable to connect.")
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                root.scheduleReconnect("Stream ended.")
            }
        }
        onPlaybackStateChanged: {
            if (playbackState !== MediaPlayer.PlayingState) {
                frameWatchdog.stop()
                if (root.receivedFrame) root.scheduleReconnect("Stream interrupted.")
            }
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
            reconnectTimer.stop()
            root.retryAttempt = 0
            frameWatchdog.restart()
            if (!root.receivedFrame) {
                root.receivedFrame = true
                connectionTimeout.stop()
                root.playbackMessage = ""
            }
        }
    }
    Timer {
        id: reconnectTimer
        interval: 2000
        onTriggered: root.play(false)
    }
    Timer {
        id: frameWatchdog
        interval: 5000
        onTriggered: root.scheduleReconnect("Video stalled.")
    }
    Timer {
        id: connectionTimeout
        interval: 20000
        onTriggered: {
            if (!root.streaming || root.receivedFrame) return
            root.scheduleReconnect("Connection timed out.")
        }
    }

    CameraPopup {
        id: popup
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        pinned: root.pinned
        onPositionMoved: function(x, y) {
            if (!screen) return
            root.pendingPosition = {screen: screen.name, x: Math.round(x), y: Math.round(y)}
            positionSaveTimer.restart()
        }
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
                Item {
                    Layout.fillWidth: true
                    implicitHeight: headerControls.implicitHeight
                    opacity: popup.chromeOpacity
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.opened && root.pinned
                        hoverEnabled: true
                        preventStealing: true
                        acceptedButtons: Qt.LeftButton
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property point dragStart
                        property point startOrigin
                        onPressed: function(mouse) {
                            dragStart = mapToItem(null, mouse.x, mouse.y)
                            startOrigin = popup.cardOrigin
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            var point = mapToItem(null, mouse.x, mouse.y)
                            popup.movePinned(startOrigin.x + point.x - dragStart.x,
                                startOrigin.y + point.y - dragStart.y)
                        }
                        ToolTip.visible: containsMouse && !pressed
                        ToolTip.text: "Drag to move camera"
                    }
                    RowLayout {
                        id: headerControls
                        anchors.fill: parent
                        Controls.ComboBox {
                            id: cameraSelector
                            objectName: "cameraSelector"
                            Layout.fillWidth: true
                            Layout.preferredWidth: Math.min(240, headerControls.width * 0.5)
                            Layout.maximumWidth: Math.min(240, headerControls.width * 0.5)
                            implicitHeight: 32
                            model: root.cameras
                            textRole: "name"
                            currentIndex: root.selectedCameraIndex
                            displayText: root.cameras.length ? currentText : "No cameras"
                            enabled: !writer.running && root.cameras.length > 0
                            Accessible.name: "Select camera"
                            onActivated: function(index) { root.selectCamera(index) }
                            contentItem: Text {
                                text: cameraSelector.displayText
                                color: Color.popups.text
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                leftPadding: 10
                                rightPadding: 28
                            }
                            background: Rectangle {
                                color: Color.popups.background
                                border.color: cameraSelector.activeFocus ? Color.accent : Color.popups.border
                            }
                            indicator: Text {
                                x: cameraSelector.width - width - 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "\u2304"
                                color: Color.popups.text
                            }
                            delegate: Controls.ItemDelegate {
                                required property var modelData
                                width: cameraSelector.width
                                text: modelData.name
                                contentItem: Text {
                                    text: parent.text
                                    color: Color.popups.text
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    color: parent.hovered ? Style.hoverFillFor(Color.popups.text, Color.accent) : Color.popups.background
                                }
                            }
                            popup: Controls.Popup {
                                y: cameraSelector.height
                                width: cameraSelector.width
                                height: Math.min(180, cameraList.contentHeight + 2)
                                padding: 1
                                contentItem: ListView {
                                    id: cameraList
                                    clip: true
                                    model: cameraSelector.popup.visible ? cameraSelector.delegateModel : null
                                    currentIndex: cameraSelector.highlightedIndex
                                    Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
                                }
                                background: Rectangle { color: Color.popups.background; border.color: Color.popups.border }
                            }
                        }
                        Item {
                            objectName: "headerDragSpace"
                            Layout.fillWidth: true
                            Layout.minimumWidth: 32
                            Layout.fillHeight: true
                        }
                        Controls.Switch {
                            id: pinSwitch
                            implicitWidth: 44
                            implicitHeight: 28
                            padding: 0
                            checked: root.pinned
                            hoverEnabled: true
                            Accessible.name: root.pinned ? "Unpin camera" : "Keep camera above other windows"
                            ToolTip.visible: hovered
                            ToolTip.text: root.pinned ? "Return to popup mode" : "Stay visible while using other windows"
                            onClicked: root.pinned = checked
                            indicator: Rectangle {
                                x: 0
                                y: (pinSwitch.height - height) / 2
                                width: 44
                                height: 24
                                radius: 0
                                color: pinSwitch.hovered
                                    ? Style.hoverFillFor(Color.popups.text, Color.accent)
                                    : pinSwitch.checked
                                        ? Style.selectedFillFor(Color.popups.text, Color.accent)
                                        : Style.normalFillFor(Color.popups.text, Color.accent)
                                border.width: pinSwitch.activeFocus ? 2 : 1
                                border.color: pinSwitch.activeFocus ? Color.accent : Color.popups.border
                                Rectangle {
                                    x: pinSwitch.checked ? parent.width - width - 3 : 3
                                    y: 3
                                    width: 18
                                    height: 18
                                    radius: 0
                                    color: pinSwitch.checked
                                        ? Style.selectedStateColor(Color.popups.text, Color.accent)
                                        : Qt.darker(Color.popups.text, 1.25)
                                    Behavior on x {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                    }
                                }
                            }
                            contentItem: Item {}
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
                }
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.configuring ? 1 : 0
                    Rectangle {
                        color: "#080b10"
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
                        // Keep controls readable over both light and dark video.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 1
                            height: 88
                            gradient: Gradient {
                                GradientStop { position: 0; color: "#00000000" }
                                GradientStop { position: 1; color: "#b3000000" }
                            }
                        }
                        Label {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: feedControls.top
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.bottomMargin: 6
                            text: root.message || root.sizeSaveError || root.positionSaveError
                            visible: text !== ""
                            color: "#ffd2d2"
                            wrapMode: Text.WordWrap
                            font.pixelSize: 12
                        }
                        RowLayout {
                            id: feedControls
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 12
                            spacing: 8
                            Label {
                                text: root.live ? "LIVE" : "OFFLINE"
                                Accessible.name: root.live ? "Camera live" : "Camera offline"
                                color: "white"
                                font.pixelSize: 11
                                font.bold: true
                                font.letterSpacing: 0.8
                                leftPadding: 12
                                rightPadding: 12
                                topPadding: 6
                                bottomPadding: 6
                                background: Rectangle {
                                    radius: height / 2
                                    color: root.live ? "#176b45" : "#b42332"
                                }
                            }
                            Item { Layout.fillWidth: true }
                            FeedButton {
                                text: cameraAudio.muted ? "\udb81\udd81" : "\udb81\udd7e"
                                font.family: "JetBrainsMono Nerd Font"
                                enabled: root.streaming && player.hasAudio
                                Accessible.name: !player.hasAudio ? "No audio track"
                                    : cameraAudio.muted ? "Unmute camera audio" : "Mute camera audio"
                                ToolTip.text: !player.hasAudio ? "This stream has no audio track"
                                    : cameraAudio.muted ? "Unmute" : "Mute"
                                onClicked: root.toggleAudio()
                            }
                            FeedButton {
                                text: "\u21bb"
                                Accessible.name: "Reconnect camera"
                                ToolTip.text: "Reconnect"
                                onClicked: root.play()
                            }
                        }
                    }
                    Controls.ScrollView {
                        id: settingsScroll
                        clip: true
                        enabled: !writer.running
                        opacity: popup.chromeOpacity
                        contentWidth: availableWidth
                        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
                        ColumnLayout {
                            width: settingsScroll.availableWidth
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Camera name"; color: root.foreground; Layout.fillWidth: true }
                                Controls.ToolButton {
                                    objectName: "addCameraButton"
                                    text: "+"
                                    enabled: !writer.running && root.cameras.length < 32
                                    Accessible.name: "Add camera"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Add camera"
                                    onClicked: root.editSettings(true)
                                    contentItem: Text { text: parent.text; color: Color.popups.text; font.pixelSize: 22; horizontalAlignment: Text.AlignHCenter }
                                }
                            }
                            TextField {
                                id: cameraName
                                objectName: "cameraName"
                                Layout.fillWidth: true
                                placeholderText: "Front door"
                                maximumLength: 64
                                selectByMouse: true
                                Accessible.name: "Camera name"
                            }
                            Label { text: "RTSP address"; color: root.foreground }
                            TextField {
                                id: address
                                objectName: "cameraAddress"
                                Layout.fillWidth: true
                                text: root.config.url
                                placeholderText: "rtsp://10.0.0.233:554/ch2"
                                selectByMouse: true
                                Accessible.name: "RTSP address"
                            }
                            Label { text: "Username"; color: root.foreground }
                            TextField {
                                id: username
                                objectName: "cameraUsername"
                                Layout.fillWidth: true
                                selectByMouse: true
                                Accessible.name: "Username"
                            }
                            Label { text: "Password"; color: root.foreground }
                            TextField {
                                id: password
                                objectName: "cameraPassword"
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
                            RowLayout {
                                Layout.fillWidth: true
                                Button {
                                    text: root.deleteArmed ? "Confirm delete" : "Delete"
                                    visible: root.editingCameraId !== ""
                                    onClicked: {
                                        if (root.deleteArmed) root.runProfileOperation({action: "delete", id: root.editingCameraId})
                                        else root.deleteArmed = true
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Button {
                                    text: "Cancel"
                                    visible: root.configured
                                    onClicked: { password.text = ""; root.configuring = false }
                                }
                                Button {
                                    text: writer.running ? "Saving…" : "Save & connect"
                                    onClicked: root.submitProfile()
                                }
                            }
                        }
                    }
                }
            }
            component FeedButton: Controls.Button {
                implicitWidth: 34
                implicitHeight: 34
                padding: 0
                font.pixelSize: 20
                hoverEnabled: true
                ToolTip.visible: hovered
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: parent.enabled ? "white" : "#8b929a"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: width / 2
                    color: parent.checked ? (parent.down || parent.hovered ? "#238657" : "#176b45")
                        : parent.down ? "#e64b5563" : parent.hovered ? "#e637414e" : "#cc141a22"
                    border.width: parent.activeFocus ? 2 : 1
                    border.color: parent.activeFocus ? "white" : "#55ffffff"
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
            }
            ResizeGrip { anchors.left: parent.left; leftCorner: true }
            ResizeGrip { anchors.right: parent.right }
        }
    }
}
