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
    // Automatic setup while FileView loads is not an explicit Config request.
    property bool settingsRequested: false
    // No native editors during the initial asynchronous saved-profile read.
    property bool libraryLoaded: false
    property bool firstRunConfirmed: false
    property var settingsDraft: ({name: "Camera 1", url: "rtsp://", username: "", password: ""})
    property bool pinned: false
    // Set by Widget for detached pins; standalone panels remain selectable.
    property string fixedCameraId: ""
    // Widget supplies this only for a fresh viewer. Null means already handled.
    property var initialPinnedCameraIds: null
    readonly property bool canDispose: !writer.running && !appearanceWriter.running
        && !sizeWriter.running && !positionWriter.running && !sizeDirty && !pendingPosition
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
    // Production geometry is per camera; standalone panels retain legacy routes.
    property bool independentViewerSize: false
    property var pendingSizes: []
    property var pendingPositions: []
    // Keep this viewer's latest edits even after a queue entry becomes in-flight.
    // Disk may still contain an older value when returning to the same scope.
    property var localSizes: Object.create(null)
    property var localPositions: Object.create(null)
    property var geometryReaders: []
    property int geometryGeneration: 0
    property bool sizeTouched: false
    property bool positionTouched: false
    property string geometryMonitorName: popup.screen ? popup.screen.name : ""
    onGeometryMonitorNameChanged: if (independentViewerSize) resetGeometry(true)
    property bool viewerSizeLoaded: false
    property bool sizeDirty: false
    property string sizeSaveError: ""
    property string positionSaveError: ""
    property string videoStyle: "theme"
    property int tintStrength: 35
    property int pixelSize: 3
    property string overlayStyle: "default"
    readonly property var overlayStyles: ["default", "coder", "hacker"]
    property string appearanceMessage: ""
    property bool editingAppearance: false
    property var cameraRotations: ({})
    readonly property int videoRotation: Object.prototype.hasOwnProperty.call(cameraRotations, selectedCameraId)
        ? cameraRotations[selectedCameraId] : 0
    onSelectedCameraIdChanged: {
        editingAppearance = false
        if (independentViewerSize) resetGeometry()
    }
    readonly property var videoStyles: ["original", "theme", "pixel", "theme-pixel"]
    property var pendingPosition: null
    property int retryAttempt: 0
    property bool changingPlayback: false
    property var config: ({url: "rtsp://", username: "", password: ""})
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/rtsp-camera/config.json"
    readonly property bool streaming: opened && !configuring && configured
    readonly property bool live: streaming && frameWatchdog.running
        && player.playbackState === MediaPlayer.PlayingState

    function editSettings(newCamera, automatic) {
        settingsRequested = automatic !== true
        editingAppearance = false
        editingCameraId = newCamera === true ? "" : selectedCameraId
        settingsDraft = {name: newCamera === true ? "" : selectedCameraIndex >= 0 ? cameras[selectedCameraIndex].name : "Camera 1",
            url: newCamera === true ? "rtsp://" : config.url,
            username: newCamera === true ? "" : config.username,
            password: newCamera === true ? "" : config.password}
        deleteArmed = false
        message = ""
        configuring = true
        if (settingsLoader.item) settingsLoader.item.populate()
    }
    function toggleAppearance() {
        if (appearanceWriter.running) return
        if (editingAppearance) {
            editingAppearance = false
            return
        }
        videoStyleChooser.currentIndex = videoStyles.indexOf(videoStyle)
        tintSlider.value = tintStrength
        pixelSlider.value = pixelSize
        overlayChooser.currentIndex = overlayStyles.indexOf(overlayStyle)
        rotationChooser.currentIndex = videoRotation / 90
        appearanceMessage = ""
        editingAppearance = true
    }
    function applyAppearance(saved) {
        var savedPixelSize = saved.pixelSize === undefined ? 3 : saved.pixelSize
        var savedOverlay = saved.overlay === undefined ? "default" : saved.overlay
        if (savedOverlay === "off") savedOverlay = "default"
        else if (savedOverlay === "hud") savedOverlay = "coder"
        else if (savedOverlay === "terminal") savedOverlay = "hacker"
        var rotations = saved.rotations === undefined ? {} : saved.rotations
        if (videoStyles.indexOf(saved.style) < 0 || !Number.isInteger(saved.strength)
            || saved.strength < 0 || saved.strength > 100
            || !Number.isInteger(savedPixelSize) || savedPixelSize < 1 || savedPixelSize > 16
            || overlayStyles.indexOf(savedOverlay) < 0
            || !rotations || typeof rotations !== "object" || Array.isArray(rotations)) throw new Error()
        Object.keys(rotations).forEach(function(id) {
            if (!id || id.length > 64 || [0, 90, 180, 270].indexOf(rotations[id]) < 0) throw new Error()
        })
        videoStyle = saved.style
        tintStrength = saved.strength
        pixelSize = savedPixelSize
        overlayStyle = savedOverlay
        cameraRotations = rotations
    }
    onConfiguringChanged: if (configuring) editingAppearance = false
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
        var globalSelected = data.cameras.find(function(camera) { return camera.id === data.selectedId })
        if ((data.cameras.length && !globalSelected) || (!data.cameras.length && data.selectedId !== "")) throw new Error()
        var viewerId = fixedCameraId || data.selectedId
        var selected = data.cameras.find(function(camera) { return camera.id === viewerId })
        if (fixedCameraId && !selected) {
            // Deleting a pinned profile closes its viewer, never substitutes another feed.
            cameras = data.cameras
            close()
            configured = false
            return
        }
        var changed = selectedCameraId !== viewerId
            || (selected && (selected.url !== config.url || selected.username !== config.username || selected.password !== config.password))
        var wasStreaming = streaming
        cameras = data.cameras
        selectedCameraId = viewerId
        config = selected || {url: "rtsp://", username: "", password: ""}
        configured = !!selected
        firstRunConfirmed = cameras.length === 0
        libraryLoaded = true
        if (!opened || !configured || !settingsRequested) configuring = !configured
        if (changed) cameraAudio.muted = true
        if (changed && wasStreaming && streaming) play()
        var pinnedIds = initialPinnedCameraIds
        initialPinnedCameraIds = null
        if (pinnedIds && pinnedIds.length && !fixedCameraId && !settingsRequested) {
            var available = cameras.findIndex(function(camera) { return pinnedIds.indexOf(camera.id) < 0 })
            // Use the normal asynchronous selection write, once only. Reloads
            // and its result must never reapply the fresh-open preference.
            if (available >= 0) selectCamera(available)
        }
    }
    function runProfileOperation(operation) {
        if (writer.running) return
        initialPinnedCameraIds = null
        message = ""
        writer.stayInSettings = configuring && operation.action === "select"
        writer.pending = JSON.stringify(operation)
        writer.running = true
    }
    function selectCamera(index) {
        if (fixedCameraId || writer.running || index < 0 || index >= cameras.length) return
        if (index === selectedCameraIndex) {
            if (configuring) editSettings()
            return
        }
        runProfileOperation({action: "select", id: cameras[index].id})
    }
    function submitProfile() {
        if (!settingsLoader.item) return
        runProfileOperation({action: "save", camera: {id: editingCameraId,
            name: settingsLoader.item.nameText, url: settingsLoader.item.addressText,
            username: settingsLoader.item.usernameText, password: settingsLoader.item.passwordText}})
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
        sizeTouched = true
        var size = {width: viewerWidth, height: viewerHeight}
        if (independentViewerSize) {
            if (!selectedCameraId) { sizeDirty = false; return }
            size.cameraId = selectedCameraId
            localSizes[selectedCameraId] = size
        }
        pendingSizes = pendingSizes.filter(function(s) { return s.cameraId !== size.cameraId }).concat([size])
        sizeSaveTimer.restart()
    }
    function saveViewerSize() {
        if (!pendingSizes.length || sizeWriter.running) return
        sizeWriter.pending = JSON.stringify(pendingSizes[0])
        pendingSizes = pendingSizes.slice(1)
        sizeDirty = pendingSizes.length > 0
        sizeWriter.running = true
    }
    function cameraToken(id) { return encodeURIComponent(id).replace(/-/g, "%2D") }
    function positionKey(id, monitor) { return JSON.stringify([id, monitor]) }
    function resetGeometry(positionOnly) {
        geometryGeneration++
        geometryReaders.forEach(function(reader) { reader.destroy() })
        geometryReaders = []
        var localSize = Object.prototype.hasOwnProperty.call(localSizes, selectedCameraId)
            ? localSizes[selectedCameraId] : null
        var key = positionKey(selectedCameraId, geometryMonitorName)
        var localPosition = Object.prototype.hasOwnProperty.call(localPositions, key)
            ? localPositions[key] : null
        positionTouched = !!localPosition
        if (positionOnly !== true) {
            sizeTouched = !!localSize
            viewerSizeLoaded = !!localSize
            viewerWidth = localSize ? localSize.width : 640
            viewerHeight = localSize ? localSize.height : 500
        }
        popup.savedPosition = localPosition ? Qt.point(localPosition.x, localPosition.y) : null
        popup.pinnedOrigin = popup.savedPosition || popup.anchoredOrigin
        Qt.callLater(loadGeometry)
    }
    function loadGeometry() {
        if (!independentViewerSize || !selectedCameraId || geometryReaders.length) return
        var readers = [cameraSizeReader.createObject(root, {cameraId: selectedCameraId, generation: geometryGeneration})]
        if (geometryMonitorName) readers.push(cameraPositionReader.createObject(root, {
            cameraId: selectedCameraId, generation: geometryGeneration, monitor: geometryMonitorName}))
        geometryReaders = readers
    }
    function toggleAudio() {
        if (streaming && player.hasAudio) cameraAudio.muted = !cameraAudio.muted
    }
    function saveViewerPosition() {
        if (!pendingPositions.length || positionWriter.running) return
        positionWriter.pending = JSON.stringify(pendingPositions[0])
        pendingPositions = pendingPositions.slice(1)
        pendingPosition = pendingPositions.length ? pendingPositions[0] : null
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
            settingsRequested = false
            settingsDraft = {name: "", url: "rtsp://", username: "", password: ""}
            editingAppearance = false
            writer.stayInSettings = false
            pinned = false
            sizeSaveTimer.stop()
            saveViewerSize()
            positionSaveTimer.stop()
            saveViewerPosition()
        }
        if (opened) {
            settingsRequested = false
            configuring = !configured
            if (configuring && libraryLoaded) editSettings(false, true)
        }
    }

    FileView {
        id: appearanceFile
        path: root.configPath.replace(/config\.json$/, "appearance.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.applyAppearance(JSON.parse(text()))
            } catch (error) { /* Missing or invalid appearance keeps the default. */ }
        }
    }
    Process {
        id: appearanceWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--appearance"]
        stdinEnabled: true
        onStarted: write(pending + "\n")
        stdout: StdioCollector { id: appearanceResult }
        onExited: function(code) {
            if (code !== 0) {
                root.appearanceMessage = "Could not save video appearance. Try again."
                return
            }
            // Commit the exact submitted preview before hiding the editor.
            try { root.applyAppearance(JSON.parse(appearanceResult.text)) }
            catch (error) { root.appearanceMessage = "Saved video appearance could not be read."; return }
            root.appearanceMessage = ""
            root.editingAppearance = false
            appearanceFile.reload()
        }
    }
    FileView {
        id: positionFile
        readonly property string monitorName: popup.screen ? popup.screen.name : ""
        path: !root.independentViewerSize && monitorName ? root.configPath.replace(/config\.json$/, "position-" + encodeURIComponent(monitorName) + ".json") : ""
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
                // Remember the latest monitor position for future pins, without
                // teleporting another detached viewer that is already open.
                if (popup.pinned && !root.fixedCameraId) popup.pinnedOrigin = popup.boundedOrigin(popup.savedPosition)
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
        path: root.independentViewerSize ? "" : root.configPath.replace(/config\.json$/, "view.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (root.independentViewerSize && root.viewerSizeLoaded) return
            root.viewerSizeLoaded = true
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
        onLoadFailed: root.viewerSizeLoaded = true
    }
    Timer {
        id: sizeSaveTimer
        interval: 300
        onTriggered: root.saveViewerSize()
    }
    Component {
        id: cameraSizeReader
        FileView {
            required property string cameraId
            required property int generation
            path: root.configPath.replace(/config\.json$/, "view-" + root.cameraToken(cameraId) + ".json")
            printErrors: false
            onLoaded: {
                if (generation !== root.geometryGeneration || root.sizeTouched
                    || Object.prototype.hasOwnProperty.call(root.localSizes, cameraId)) return
                root.viewerSizeLoaded = true
                try {
                    var size = JSON.parse(text())
                    if (size.cameraId !== cameraId || !Number.isInteger(size.width) || !Number.isInteger(size.height)
                        || size.width < 1 || size.height < 1 || size.width > 32768 || size.height > 32768) return
                    root.viewerWidth = size.width; root.viewerHeight = size.height
                    if (popup.pinned && !root.positionTouched && !popup.savedPosition)
                        popup.pinnedOrigin = popup.anchoredOrigin
                } catch (error) {}
            }
            onLoadFailed: if (generation === root.geometryGeneration) root.viewerSizeLoaded = true
        }
    }
    Component {
        id: cameraPositionReader
        FileView {
            required property string cameraId
            required property int generation
            required property string monitor
            path: root.configPath.replace(/config\.json$/, "position-" + root.cameraToken(cameraId) + "--" + encodeURIComponent(monitor) + ".json")
            printErrors: false
            onLoaded: {
                if (generation !== root.geometryGeneration || root.positionTouched
                    || Object.prototype.hasOwnProperty.call(root.localPositions, root.positionKey(cameraId, monitor))) return
                try {
                    var saved = JSON.parse(text())
                    if (saved.cameraId !== cameraId || saved.screen !== monitor
                        || !Number.isInteger(saved.x) || !Number.isInteger(saved.y)
                        || saved.x < 0 || saved.y < 0 || saved.x > 32768 || saved.y > 32768) return
                    popup.savedPosition = Qt.point(saved.x, saved.y)
                    // Clamp through cardOrigin, not here: size may still be loading.
                    // Late initial load may restore a pin, but never overwrite its own drag.
                    if (popup.pinned) popup.pinnedOrigin = popup.savedPosition
                } catch (error) {}
            }
        }
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
                root.firstRunConfirmed = false
                root.configured = false
                root.configuring = true
                root.message = "Saved settings could not be read. Open Config to repair the file."
            }
        }
        onLoadFailed: function(error) {
            root.firstRunConfirmed = error === FileViewError.FileNotFound
            root.libraryLoaded = true
            root.configured = false
            root.configuring = true
            if (!root.firstRunConfirmed) root.message = "Saved settings could not be read. Open Config to repair the file."
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
            root.settingsDraft = {name: "", url: "rtsp://", username: "", password: ""}
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
            root.positionTouched = true
            var position = {screen: root.geometryMonitorName, x: Math.round(x), y: Math.round(y)}
            if (root.independentViewerSize) {
                if (!root.selectedCameraId) return
                position.cameraId = root.selectedCameraId
                root.localPositions[root.positionKey(position.cameraId, position.screen)] = position
            }
            root.pendingPositions = root.pendingPositions.filter(function(p) {
                return p.cameraId !== position.cameraId || p.screen !== position.screen
            }).concat([position])
            root.pendingPosition = root.pendingPositions[0]
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
                            enabled: !root.fixedCameraId && !writer.running && root.cameras.length > 0
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
                    ColumnLayout {
                        id: viewerPage
                        spacing: 8
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 120
                            color: "#080b10"
                            border.width: 1
                            border.color: Color.accent
                            clip: true
                            VideoOutput {
                                id: video
                                orientation: root.editingAppearance ? rotationChooser.currentIndex * 90 : root.videoRotation
                                anchors.fill: parent
                                anchors.margins: 1
                                fillMode: VideoOutput.PreserveAspectFit
                            }
                            VideoEffect {
                                objectName: "videoEffect"
                                anchors.fill: video
                                sourceItem: video
                                active: root.streaming
                                style: root.editingAppearance ? root.videoStyles[videoStyleChooser.currentIndex] : root.videoStyle
                                strength: (root.editingAppearance ? tintSlider.value : root.tintStrength) / 100
                                pixelSize: root.editingAppearance ? Math.round(pixelSlider.value) : root.pixelSize
                            }
                            // Keep controls readable over both light and dark video.
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 1
                                height: 88
                                gradient: Gradient {
                                    GradientStop { position: 0; color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0) }
                                    GradientStop { position: 1; color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.75) }
                                }
                            }
                            VideoOverlay {
                                id: cameraOverlay
                                objectName: "videoOverlay"
                                x: video.x + (video.contentRect.width > 0 ? video.contentRect.x : 0)
                                y: video.y + (video.contentRect.height > 0 ? video.contentRect.y : 0)
                                width: video.contentRect.width > 0 ? video.contentRect.width : video.width
                                height: video.contentRect.height > 0 ? video.contentRect.height : video.height
                                active: root.streaming
                                mode: root.editingAppearance ? root.overlayStyles[overlayChooser.currentIndex] : root.overlayStyle
                                cameraName: root.selectedCameraIndex >= 0 ? root.cameras[root.selectedCameraIndex].name : "Camera"
                                live: root.live
                                framesReceived: root.framesReceived
                                rightHeaderSpace: audioWaveform.width + 8
                            }
                            AudioWaveform {
                                id: audioWaveform
                                objectName: "audioButton"
                                readonly property real videoWidth: cameraOverlay.width > 0 ? cameraOverlay.width : video.width
                                x: (cameraOverlay.width > 0 ? cameraOverlay.x : video.x)
                                    + videoWidth - feedControls.sideInset - width
                                y: (cameraOverlay.height > 0 ? cameraOverlay.y : video.y) + feedControls.overlayInset + 8
                                width: Math.min(104, Math.max(0, videoWidth - feedControls.sideInset * 2) * 0.3)
                                audioAvailable: root.streaming && player.hasAudio
                                audioMuted: cameraAudio.muted
                                onClicked: root.toggleAudio()
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
                                readonly property real overlayInset: cameraOverlay.item && cameraOverlay.item.inset !== undefined
                                    ? cameraOverlay.item.inset : 0
                                readonly property real sideInset: Math.max(12, overlayInset + 6)
                                anchors.left: cameraOverlay.width > 0 ? cameraOverlay.left : video.left
                                anchors.right: cameraOverlay.width > 0 ? cameraOverlay.right : video.right
                                anchors.bottom: cameraOverlay.height > 0 ? cameraOverlay.bottom : video.bottom
                                anchors.leftMargin: sideInset
                                anchors.rightMargin: sideInset
                                anchors.bottomMargin: overlayInset + 12
                                spacing: 6
                                Item { Layout.fillWidth: true }
                                FeedButton {
                                    objectName: "themeButton"
                                    text: "\udb80\udfd8"
                                    font.family: "JetBrainsMono Nerd Font"
                                    Accessible.name: "Video theme"
                                    ToolTip.text: root.editingAppearance ? "Close theme preview" : "Video theme"
                                    checked: root.editingAppearance
                                    enabled: !appearanceWriter.running
                                    onClicked: root.toggleAppearance()
                                }
                            }
                        }
                        Rectangle {
                            id: themeEditor
                            objectName: "themeEditor"
                            visible: root.editingAppearance
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(appearanceColumn.implicitHeight + appearanceFooter.implicitHeight + 36, viewerPage.height * 0.6)
                            color: Color.popups.background
                            border.color: Color.popups.border
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 12
                                Controls.ScrollView {
                                    id: appearanceScroll
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    contentWidth: availableWidth
                                    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
                                    ColumnLayout {
                                        id: appearanceColumn
                                        width: appearanceScroll.availableWidth
                                        spacing: 12
                                        Label { text: "Rotation · this camera"; color: root.foreground }
                                        Controls.ComboBox {
                                            id: rotationChooser
                                            objectName: "videoRotation"
                                            Layout.fillWidth: true
                                            model: ["0° · Original", "90° · Clockwise", "180° · Upside down", "270° · Counterclockwise"]
                                            currentIndex: root.videoRotation / 90
                                            enabled: !appearanceWriter.running && root.selectedCameraId !== ""
                                            Accessible.name: "Video rotation for this camera"
                                            implicitHeight: 32
                                            contentItem: Text {
                                                text: rotationChooser.displayText
                                                color: Color.popups.text
                                                verticalAlignment: Text.AlignVCenter
                                                leftPadding: 10; rightPadding: 28
                                            }
                                            background: Rectangle {
                                                color: Color.popups.background
                                                border.color: rotationChooser.activeFocus ? Color.accent : Color.popups.border
                                            }
                                            indicator: Text {
                                                x: rotationChooser.width - width - 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "\u2304"; color: Color.popups.text
                                            }
                                            delegate: Controls.ItemDelegate {
                                                required property string modelData
                                                required property int index
                                                width: rotationChooser.width
                                                text: modelData
                                                highlighted: rotationChooser.highlightedIndex === index
                                                contentItem: Text { text: parent.text; color: Color.popups.text; verticalAlignment: Text.AlignVCenter }
                                                background: Rectangle {
                                                    color: parent.hovered || parent.highlighted
                                                        ? Style.hoverFillFor(Color.popups.text, Color.accent) : Color.popups.background
                                                }
                                            }
                                            popup: Controls.Popup {
                                                y: rotationChooser.height
                                                width: rotationChooser.width
                                                implicitHeight: rotationList.contentHeight + 2
                                                padding: 1
                                                contentItem: ListView {
                                                    id: rotationList
                                                    clip: true
                                                    implicitHeight: contentHeight
                                                    model: rotationChooser.popup.visible ? rotationChooser.delegateModel : null
                                                    currentIndex: rotationChooser.highlightedIndex
                                                }
                                                background: Rectangle { color: Color.popups.background; border.color: Color.popups.border }
                                            }
                                        }
                                        Label { text: "Video style · all cameras"; color: root.foreground }
                                        Controls.ComboBox {
                                            id: videoStyleChooser
                                            objectName: "videoStyle"
                                            Layout.fillWidth: true
                                            model: ["Original", "Omarchy", "Pixel", "Omarchy Pixel"]
                                            currentIndex: root.videoStyles.indexOf(root.videoStyle)
                                            enabled: !appearanceWriter.running
                                            Accessible.name: "Video style"
                                            implicitHeight: 32
                                            contentItem: Text {
                                                text: videoStyleChooser.displayText
                                                color: Color.popups.text
                                                verticalAlignment: Text.AlignVCenter
                                                leftPadding: 10; rightPadding: 28
                                            }
                                            background: Rectangle {
                                                color: Color.popups.background
                                                border.color: videoStyleChooser.activeFocus ? Color.accent : Color.popups.border
                                            }
                                            indicator: Text {
                                                x: videoStyleChooser.width - width - 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "\u2304"; color: Color.popups.text
                                            }
                                            delegate: Controls.ItemDelegate {
                                                required property string modelData
                                                required property int index
                                                width: videoStyleChooser.width
                                                text: modelData
                                                highlighted: videoStyleChooser.highlightedIndex === index
                                                contentItem: Text { text: parent.text; color: Color.popups.text; verticalAlignment: Text.AlignVCenter }
                                                background: Rectangle {
                                                    color: parent.hovered || parent.highlighted
                                                        ? Style.hoverFillFor(Color.popups.text, Color.accent) : Color.popups.background
                                                }
                                            }
                                            popup: Controls.Popup {
                                                y: videoStyleChooser.height
                                                width: videoStyleChooser.width
                                                implicitHeight: styleList.contentHeight + 2
                                                padding: 1
                                                contentItem: ListView {
                                                    id: styleList
                                                    clip: true
                                                    implicitHeight: contentHeight
                                                    model: videoStyleChooser.popup.visible ? videoStyleChooser.delegateModel : null
                                                    currentIndex: videoStyleChooser.highlightedIndex
                                                }
                                                background: Rectangle { color: Color.popups.background; border.color: Color.popups.border }
                                            }
                                        }
                                        RowLayout {
                                            visible: videoStyleChooser.currentIndex === 1 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            Label { text: "Tint strength"; color: root.foreground }
                                            Controls.Slider {
                                                id: tintSlider
                                                objectName: "tintStrength"
                                                Layout.fillWidth: true
                                                from: 0; to: 100; stepSize: 1
                                                value: root.tintStrength
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Tint strength"
                                                background: Rectangle {
                                                    x: tintSlider.leftPadding
                                                    y: tintSlider.topPadding + tintSlider.availableHeight / 2 - height / 2
                                                    width: tintSlider.availableWidth; height: 4
                                                    color: Color.popups.border
                                                    Rectangle { width: tintSlider.visualPosition * parent.width; height: parent.height; color: Color.accent }
                                                }
                                                handle: Rectangle {
                                                    x: tintSlider.leftPadding + tintSlider.visualPosition * (tintSlider.availableWidth - width)
                                                    y: tintSlider.topPadding + tintSlider.availableHeight / 2 - height / 2
                                                    implicitWidth: 14; implicitHeight: 18
                                                    color: tintSlider.pressed ? Color.popups.text : Color.accent
                                                    border.width: tintSlider.activeFocus ? 2 : 1
                                                    border.color: Color.popups.text
                                                }
                                            }
                                            Label { text: Math.round(tintSlider.value) + "%"; color: root.foreground }
                                        }
                                        RowLayout {
                                            visible: videoStyleChooser.currentIndex === 2 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            Label { text: "Pixel size"; color: root.foreground }
                                            Controls.Slider {
                                                id: pixelSlider
                                                objectName: "pixelSize"
                                                Layout.fillWidth: true
                                                from: 1; to: 16; stepSize: 1
                                                value: root.pixelSize
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Pixel size"
                                                ToolTip.visible: hovered
                                                ToolTip.text: "Larger pixels give a stronger pixelated look"
                                                background: Rectangle {
                                                    x: pixelSlider.leftPadding
                                                    y: pixelSlider.topPadding + pixelSlider.availableHeight / 2 - height / 2
                                                    width: pixelSlider.availableWidth; height: 4
                                                    color: Color.popups.border
                                                    Rectangle { width: pixelSlider.visualPosition * parent.width; height: parent.height; color: Color.accent }
                                                }
                                                handle: Rectangle {
                                                    x: pixelSlider.leftPadding + pixelSlider.visualPosition * (pixelSlider.availableWidth - width)
                                                    y: pixelSlider.topPadding + pixelSlider.availableHeight / 2 - height / 2
                                                    implicitWidth: 14; implicitHeight: 18
                                                    color: pixelSlider.pressed ? Color.popups.text : Color.accent
                                                    border.width: pixelSlider.activeFocus ? 2 : 1
                                                    border.color: Color.popups.text
                                                }
                                            }
                                            Label { text: Math.round(pixelSlider.value) + " px"; color: root.foreground }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Label { text: "Overlay"; color: root.foreground }
                                            Controls.ComboBox {
                                                id: overlayChooser
                                                objectName: "overlayStyle"
                                                Layout.fillWidth: true
                                                model: ["Default", "Coder", "Hackerman"]
                                                currentIndex: root.overlayStyles.indexOf(root.overlayStyle)
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Camera overlay"
                                                implicitHeight: 32
                                                contentItem: Text {
                                                    text: overlayChooser.displayText
                                                    color: Color.popups.text
                                                    verticalAlignment: Text.AlignVCenter
                                                    leftPadding: 10; rightPadding: 28
                                                }
                                                background: Rectangle {
                                                    color: Color.popups.background
                                                    border.color: overlayChooser.activeFocus ? Color.accent : Color.popups.border
                                                }
                                                indicator: Text {
                                                    x: overlayChooser.width - width - 10
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: "\u2304"; color: Color.popups.text
                                                }
                                                delegate: Controls.ItemDelegate {
                                                    required property string modelData
                                                    required property int index
                                                    width: overlayChooser.width
                                                    text: modelData
                                                    highlighted: overlayChooser.highlightedIndex === index
                                                    contentItem: Text { text: parent.text; color: Color.popups.text; verticalAlignment: Text.AlignVCenter }
                                                    background: Rectangle {
                                                        color: parent.hovered || parent.highlighted
                                                            ? Style.hoverFillFor(Color.popups.text, Color.accent) : Color.popups.background
                                                    }
                                                }
                                                popup: Controls.Popup {
                                                    y: overlayChooser.height
                                                    width: overlayChooser.width
                                                    implicitHeight: overlayList.contentHeight + 2
                                                    padding: 1
                                                    contentItem: ListView {
                                                        id: overlayList
                                                        clip: true
                                                        implicitHeight: contentHeight
                                                        model: overlayChooser.popup.visible ? overlayChooser.delegateModel : null
                                                        currentIndex: overlayChooser.highlightedIndex
                                                    }
                                                    background: Rectangle { color: Color.popups.background; border.color: Color.popups.border }
                                                }
                                            }
                                        }

                                    }
                                }
                                RowLayout {
                                    id: appearanceFooter
                                    Layout.fillWidth: true
                                    Label {
                                        text: root.appearanceMessage || "Rotation: this camera · Theme: all cameras. Apply to save."
                                        color: root.foreground
                                        font.pixelSize: 12
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                    Button {
                                        objectName: "applyStyle"
                                        text: appearanceWriter.running ? "Applying…" : "Apply"
                                        enabled: !appearanceWriter.running
                                        onClicked: {
                                            root.appearanceMessage = ""
                                            var settings = {style: root.videoStyles[videoStyleChooser.currentIndex],
                                                strength: Math.round(tintSlider.value), pixelSize: Math.round(pixelSlider.value),
                                                overlay: root.overlayStyles[overlayChooser.currentIndex]}
                                            if (root.selectedCameraId) {
                                                settings.cameraId = root.selectedCameraId
                                                settings.rotation = rotationChooser.currentIndex * 90
                                            }
                                            appearanceWriter.pending = JSON.stringify(settings)
                                            appearanceWriter.running = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Loader {
                        id: settingsLoader
                        active: root.opened && root.configuring && (root.settingsRequested || root.firstRunConfirmed)
                        onLoaded: item.populate()
                        Label {
                            anchors.centerIn: parent
                            width: parent.width
                            visible: !settingsLoader.active
                            text: root.message || "Loading camera profiles…"
                            color: root.foreground
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                        sourceComponent: Controls.ScrollView {
                            id: settingsScroll
                            property alias nameText: cameraName.text
                            property alias addressText: address.text
                            property alias usernameText: username.text
                            property alias passwordText: password.text
                            function populate() {
                                cameraName.text = root.settingsDraft.name
                                address.text = root.settingsDraft.url
                                username.text = root.settingsDraft.username
                                password.text = root.settingsDraft.password
                                cameraName.forceActiveFocus()
                            }
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
                                        enabled: !root.fixedCameraId && !writer.running && root.cameras.length < 32
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
                                    placeholderText: "rtsp://camera-ip:554/stream"
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
                                        onClicked: {
                                            root.configuring = false
                                            root.settingsRequested = false
                                            root.settingsDraft = {name: "", url: "rtsp://", username: "", password: ""}
                                        }
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
            }
            component FeedButton: Controls.Button {
                id: feedButton
                implicitWidth: 34
                implicitHeight: 34
                padding: 0
                font.pixelSize: 20
                hoverEnabled: true
                ToolTip.visible: hovered
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: !feedButton.enabled ? Color.muted
                        : feedButton.checked || feedButton.hovered || feedButton.activeFocus ? Color.accent : Color.foreground
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 0
                    color: "transparent"
                    border.width: feedButton.activeFocus ? 2 : 1
                    border.color: !feedButton.enabled ? Color.muted
                        : feedButton.checked || feedButton.hovered || feedButton.activeFocus ? Color.accent : Color.popups.border
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
