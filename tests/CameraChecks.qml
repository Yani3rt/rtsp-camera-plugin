import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import "Camera"
ShellRoot {
    PanelWindow {
        id: effectWindow
        visible: false
        implicitWidth: 360
        implicitHeight: 180
        exclusionMode: ExclusionMode.Ignore
        Item {
            id: fixture
            anchors.fill: parent
            Rectangle {
                id: gradientSource
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "black" }
                    GradientStop { position: 1; color: "white" }
                }
            }
            VideoEffect { id: fixtureEffect; anchors.fill: parent; sourceItem: gradientSource }
            VideoOverlay { id: fixtureOverlay; active: false; anchors.fill: parent; cameraName: "Test camera" }
            Rectangle { x: 20; y: 20; width: 1; height: 20; color: "red" }
        }
        AudioWaveform { id: fixtureWave; visible: false; x: 230; y: 18 }
    }
    FileView { id: processStats; path: "/proc/" + Quickshell.processId + "/stat"; blockLoading: true }
    PanelWindow {
        id: barWindow
        anchors { top: true; left: true; right: true }
        implicitHeight: 28
        Item { id: anchor; x: 700; width: 30; height: 28 }
        Widget { id: widget; bar: fakeBar; x: 750; width: 30; height: 28 }
    }
    QtObject {
        id: fakeBar
        property string position: "top"
        property int barSize: 28
        property color foreground: "white"
        property color barForeground: "white"
        property bool vertical: false
        property bool foregroundAnimationEnabled: false
        property color urgent: "red"
        function hideTooltip(item) {}
        function showTooltip(item, text) {}
        property var activePopout: null
        function requestPopout(key) {
            if (activePopout === key) return
            if (activePopout) activePopout.closeForPopoutSwitch()
            activePopout = key
        }
        function releasePopout(key) { if (activePopout === key) activePopout = null }
    }
    CameraPanel { id: panel; bar: fakeBar; anchorItem: anchor }
    Component { id: newPanel; CameraPanel { bar: fakeBar; anchorItem: anchor } }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            try {
                if (Quickshell.env("CAMERA_TEST_GEOMETRY_RESTART")) probe.runGeometryRestart()
                else if (Quickshell.env("CAMERA_TEST_PIN_ONLY") === "1") { probe.runMultiPin(); probe.runFreshSelection(); probe.runGeometry() }
                else if (Quickshell.env("CAMERA_TEST_ROTATION_ONLY") === "1") probe.runRotation()
                else if (Quickshell.env("CAMERA_TEST_BENCHMARK") === "1") probe.runVideoStyles(true)
                else {
                    probe.runAppearance(); probe.runOverlayPixels(); probe.runEffectPixels(); probe.runDrag()
                    if (Quickshell.env("CAMERA_TEST_UI_ONLY") !== "1") { probe.runVideoStyles(false); probe.runReconnect() }
                    probe.runMultiPin(); probe.runFreshSelection(); probe.runGeometry(); probe.runProfiles(); probe.runRotation()
                }
                console.log("CAMERA_CHECKS_PASSED")
            }
            catch (error) { console.error("CAMERA_CHECKS_FAILED", error, error.stack) }
            finally { panel.close(); Qt.quit() }
        }
    }
    TestCase {
        id: probe
        optional: true
        name: "CameraDrag"
        when: false
        function assertOk(value, message) {
            if (!value) throw new Error(message || "Assertion failed")
        }
        function equal(actual, expected, message) {
            if (actual !== expected) throw new Error((message || "Comparison failed") + ": " + actual + " != " + expected)
        }
        function sameResampledImage(actual, expected) {
            if (actual.width !== expected.width || actual.height !== expected.height) return false
            // Fractional monitor scales resample the capture texture. Allow two
            // channel levels of rounding, while still catching a changed filter.
            for (var y = 0; y < actual.height; y += Math.max(1, Math.floor(actual.height / 24))) {
                for (var x = 0; x < actual.width; x += Math.max(1, Math.floor(actual.width / 48))) {
                    if (Math.abs(actual.red(x,y) - expected.red(x,y)) > 2
                        || Math.abs(actual.green(x,y) - expected.green(x,y)) > 2
                        || Math.abs(actual.blue(x,y) - expected.blue(x,y)) > 2
                        || Math.abs(actual.alpha(x,y) - expected.alpha(x,y)) > 2) return false
                }
            }
            return true
        }
        function eventually(predicate, timeout) {
            var deadline = Date.now() + timeout
            while (!predicate() && Date.now() < deadline) wait(25)
            assertOk(predicate(), "Timed out; playback status: " + panel.playbackStatus())
        }
        function find(item, predicate) {
            if (predicate(item)) return item
            var children = item.data || item.children || []
            for (var i = 0; i < children.length; ++i) {
                var result = find(children[i], predicate)
                if (result) return result
            }
            return null
        }
        function capture(item, name, directory) {
            directory = directory || Quickshell.env("CAMERA_TEST_CAPTURE_DIR")
            if (!directory) return
            var complete = false
            // Pixel probe coordinates below are logical item coordinates. Use
            // that same raster size even if the compositor chooses a scaled output.
            assertOk(item.grabToImage(function(result) {
                assertOk(result.saveToFile(directory + "/" + name + ".png"), "save visual capture")
                complete = true
            }, Qt.size(Math.round(item.width), Math.round(item.height))), "request visual capture")
            eventually(function() { return complete }, 2000)
        }
        function runMultiPin() {
            widget.open()
            var first = find(widget, function(i) { return i.playbackStatus !== undefined })
            eventually(function() { return first !== null }, 1000)
            wait(200) // Let the new panel's initial FileViews settle.
            first.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            first.configured = true; first.configuring = false
            eventually(function() { return first.live }, 5000)
            first.pinned = true
            var button = find(widget, function(i) { return i.triggerPress !== undefined })
            assertOk(button !== null, "real Widget bar button exists")
            mouseClick(button)
            wait(200)
            assertOk(first.opened && first.pinned && first.live,
                "bar click keeps pinned viewer open and playing")
            var second = find(widget, function(i) { return i !== first && i.playbackStatus !== undefined && i.opened })
            assertOk(second !== null, "bar click opens a separate selectable viewer")
            second.close(); first.close()
            eventually(function() { return widget.viewers.length === 0 }, 3000)
            widget.open()
            first = widget.panel
            wait(200)
            assertOk(first.configuring && !first.configured, "first-run empty library stays in Config")
            first.runProfileOperation({action: "save", camera: {name: "Pin front", url: "rtsp://127.0.0.1:1/front", username: "front", password: ""}})
            eventually(function() { return first.cameras.length === 1 }, 4000)
            var firstId = first.selectedCameraId
            first.resizeViewer(740, 580)
            first.pinned = true
            var geometryPopup = find(first, function(i) { return i.cardOrigin !== undefined })
            geometryPopup.movePinned(140, 160)
            eventually(function() { return first.canDispose }, 4000)
            button.triggerPress(Qt.LeftButton)
            second = widget.panel
            eventually(function() { return second.cameras.length === 1 }, 4000)
            assertOk(!second.configuring && second.streaming,
                "fresh bar viewer shows saved camera after async profile load, not Config")
            // Exercise the resulting video page with generated media, without
            // overriding configured/configuring to bypass the async open path.
            second.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            second.play()
            eventually(function() { return second.live }, 5000)
            second.runProfileOperation({action: "save", camera: {name: "Pin back", url: "rtsp://127.0.0.1:1/back", username: "back", password: ""}})
            eventually(function() { return second.cameras.length === 2 }, 4000)
            var secondId = second.selectedCameraId
            wait(250)
            equal(second.viewerWidth, 640, "new camera must not inherit another camera width")
            equal(second.viewerHeight, 500, "new camera must not inherit another camera height")
            var freshPopup = find(second, function(i) { return i.cardOrigin !== undefined })
            second.pinned = true
            equal(freshPopup.cardOrigin.x, freshPopup.anchoredOrigin.x, "new camera pins at bar anchor x")
            equal(freshPopup.cardOrigin.y, freshPopup.anchoredOrigin.y, "new camera pins at bar anchor y")
            eventually(function() { return first.cameras.length === 2 }, 4000)
            equal(first.selectedCameraId, firstId, "global selection cannot change a pinned camera ID")
            equal(first.config.username, "front", "pin keeps its own playback credentials")
            second.pinned = true
            button.triggerPress(Qt.LeftButton)
            var third = widget.panel
            eventually(function() { return third.cameras.length === 2 }, 4000)
            third.editSettings(); third.selectCamera(0)
            assertOk(third.configuring, "explicit Config opens after async load")
            eventually(function() { return third.selectedCameraId === firstId }, 4000)
            equal(second.selectedCameraId, secondId, "settings selection leaves other pin unchanged")
            assertOk(third.configuring, "selectable viewer stays in settings")
            first.editSettings()
            find(first, function(i) { return i.objectName === "cameraName" }).text = "Unsaved pin draft"
            third.runProfileOperation({action: "save", camera: {id: firstId, name: "Renamed pin", url: "rtsp://127.0.0.1:1/front", username: "front", password: ""}})
            eventually(function() { return first.cameras[0].name === "Renamed pin" && !third.configuring }, 4000)
            assertOk(first.configuring, "profile watcher does not eject explicitly opened Config")
            equal(find(first, function(i) { return i.objectName === "cameraName" }).text,
                "Unsaved pin draft", "profile watcher preserves active draft")
            mouseClick(find(first, function(i) { return i.text === "Cancel" && i.clicked !== undefined }))
            equal(first.selectedCameraId, firstId, "rename preserves pinned identity")
            assertOk(!find(first, function(i) { return i.objectName === "cameraSelector" }).enabled,
                "pinned camera selector cannot retarget its identity")
            third.runProfileOperation({action: "save", camera: {id: secondId, name: "Pin back", url: "rtsp://127.0.0.1:1/back-updated", username: "updated", password: ""}})
            eventually(function() { return second.config.username === "updated" }, 4000)
            equal(second.selectedCameraId, secondId, "connection edits update the same pinned ID")
            equal(second.config.url, "rtsp://127.0.0.1:1/back-updated", "pin receives changed address")
            widget.closeForPopoutSwitch()
            assertOk(!third.opened && first.opened && second.opened, "popup coordination leaves both pins open")
            widget.open(); third = widget.panel
            eventually(function() { return third.cameras.length === 2 }, 4000)
            third.selectCamera(0)
            assertOk(!third.configuring && third.streaming, "reopened Widget viewer shows saved camera")
            eventually(function() { return third.selectedCameraId === firstId }, 4000)
            third.pinned = true
            assertOk(first.opened && third.opened && third.fixedCameraId === first.fixedCameraId,
                "duplicate pins are independent viewers")
            third.close()
            assertOk(first.opened && second.opened, "closing duplicate leaves original pins open")
            widget.open(); third = widget.panel
            eventually(function() { return third.cameras.length === 2 }, 4000)
            var firstPopup = find(first, function(i) { return i.cardOrigin !== undefined })
            var secondPopup = find(second, function(i) { return i.cardOrigin !== undefined })
            assertOk(!third.configuring && third.streaming, "fresh popup loads saved camera without test override")
            var otherSizes = [second, third].map(function(viewer) {
                return {viewer: viewer, width: viewer.viewerWidth, height: viewer.viewerHeight}
            })
            first.resizeViewer(720, 560)
            eventually(function() { return !JSON.parse(first.playbackStatus()).sizePending }, 4000)
            equal(first.sizeSaveError, "", "pin resize persisted")
            wait(500) // Allow both other viewers' shared view.json watchers to reload.
            var sizeErrors = []
            for (var saved of otherSizes) {
                if (saved.viewer.viewerWidth !== saved.width) sizeErrors.push("width " + saved.viewer.viewerWidth + " != " + saved.width)
                if (saved.viewer.viewerHeight !== saved.height) sizeErrors.push("height " + saved.viewer.viewerHeight + " != " + saved.height)
            }
            assertOk(sizeErrors.length === 0, "resizing one pin must not resize other pin or selectable popup: " + sizeErrors.join("; "))
            third.close()
            button.triggerPress(Qt.LeftButton)
            third = widget.panel
            eventually(function() { return third.cameras.length === 2 && third.viewerWidth === first.viewerWidth
                && third.viewerHeight === first.viewerHeight }, 4000)
            assertOk(!third.configuring && third.streaming, "new viewer uses saved size and shows camera")
            var pinSizes = [first, second].map(function(viewer) {
                return {viewer: viewer, width: viewer.viewerWidth, height: viewer.viewerHeight}
            })
            third.resizeViewer(680, 520)
            eventually(function() { return !JSON.parse(third.playbackStatus()).sizePending }, 4000)
            wait(500)
            for (var saved of pinSizes) {
                equal(saved.viewer.viewerWidth, saved.width, "selectable resize leaves pin width independent")
                equal(saved.viewer.viewerHeight, saved.height, "selectable resize leaves pin height independent")
            }
            var secondOrigin = Qt.point(secondPopup.cardOrigin.x, secondPopup.cardOrigin.y)
            firstPopup.movePinned(firstPopup.cardOrigin.x + 100, firstPopup.cardOrigin.y + 100)
            eventually(function() { return !JSON.parse(first.playbackStatus()).positionPending }, 4000)
            wait(300)
            equal(secondPopup.cardOrigin.x, secondOrigin.x, "moving one pin does not move another horizontally")
            equal(secondPopup.cardOrigin.y, secondOrigin.y, "moving one pin does not move another vertically")
            for (var viewer of [first, second]) {
                viewer.config = {url: Qt.resolvedUrl(viewer === first ? "sample.mp4" : "rotation.mp4").toString(), username: "", password: ""}
                viewer.play()
            }
            eventually(function() { return first.live && second.live }, 5000)
            first.toggleAppearance()
            var firstRotation = find(first, function(i) { return i.objectName === "videoRotation" })
            firstRotation.currentIndex = 1
            equal(second.videoRotation, 0, "rotation preview stays local to one pin")
            mouseClick(find(first, function(i) { return i.objectName === "applyStyle" }))
            eventually(function() { return !first.editingAppearance && first.videoRotation === 90 }, 4000)
            equal(second.videoRotation, 0, "rotation Apply saves only that pinned camera")
            second.toggleAppearance()
            find(second, function(i) { return i.objectName === "videoRotation" }).currentIndex = 3
            find(second, function(i) { return i.objectName === "videoStyle" }).currentIndex = 0
            mouseClick(find(second, function(i) { return i.objectName === "applyStyle" }))
            eventually(function() { return !second.editingAppearance && first.videoStyle === "original" }, 4000)
            equal(first.videoRotation, 90, "second pin Apply preserves first pin rotation")
            equal(second.videoRotation, 270, "second pin stores its own rotation")
            var frameCount = second.framesReceived
            first.toggleAudio()
            assertOk(JSON.parse(second.playbackStatus()).muted, "audio mute is independent")
            first.close()
            wait(300)
            assertOk(second.live && second.framesReceived > frameCount, "closing one pin preserves other decoder")
            second.pinned = false
            equal(widget.panel, second, "unpin adopts viewer as selectable popup")
            assertOk(!third.opened, "unpin replaces only existing selectable popup")
            button.triggerPress(Qt.LeftButton)
            eventually(function() { return widget.viewers.length === 0 }, 3000)
            button.triggerPress(Qt.LeftButton)
            third = widget.panel
            eventually(function() { return third.cameras.length === 2 }, 4000)
            third.pinned = true
            button.triggerPress(Qt.LeftButton)
            var editor = widget.panel
            eventually(function() { return editor.cameras.length === 2 && editor.canDispose }, 4000)
            editor.runProfileOperation({action: "delete", id: firstId})
            eventually(function() { return !third.opened && editor.cameras.length === 1 && editor.canDispose }, 4000)
            equal(editor.selectedCameraId, secondId, "deleted pin closes without retargeting")
            editor.runProfileOperation({action: "delete", id: secondId})
            eventually(function() { return editor.cameras.length === 0 }, 4000)
            editor.close()
            eventually(function() { return widget.viewers.length === 0 }, 3000)
            console.log("PASS: real Widget async saved-profile open/reopen, Config drafts, independent resize/default size, multi-pin identity, settings, rename/delete, playback/audio, unpin, cleanup")
        }
        function runFreshSelection() {
            // runMultiPin leaves an empty temporary library; use real saves and
            // the real bar button rather than injecting a panel's loaded state.
            function add(name) {
                panel.runProfileOperation({action: "save", camera: {name: name,
                    url: "rtsp://127.0.0.1:1/selection", username: "", password: ""}})
                eventually(function() { return panel.cameras.some(function(c) { return c.name === name }) && panel.canDispose }, 4000)
                return panel.selectedCameraId
            }
            var firstId = add("Selection first"), secondId = add("Selection second")
            var button = find(widget, function(i) { return i.triggerPress !== undefined })
            button.triggerPress(Qt.LeftButton)
            var pin = widget.panel
            eventually(function() { return pin.selectedCameraId === secondId }, 4000)
            pin.pinned = true
            button.triggerPress(Qt.LeftButton)
            var viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 2 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, firstId, "fresh bar viewer automatically selects the other saved camera")
            equal(pin.selectedCameraId, secondId, "automatic selection leaves pin unchanged")
            var thirdId = add("Selection third")
            eventually(function() { return viewer.cameras.length === 3 && viewer.selectedCameraId === thirdId }, 4000)
            viewer.selectCamera(1)
            eventually(function() { return viewer.selectedCameraId === secondId && viewer.canDispose }, 4000)
            viewer.close()
            button.triggerPress(Qt.LeftButton)
            viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 3 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, firstId, "three cameras choose first list entry, not cyclic next after middle pin")
            viewer.pinned = true
            var firstPin = viewer
            button.triggerPress(Qt.LeftButton)
            viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 3 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, thirdId, "fresh viewer skips ALL open pinned IDs")
            viewer.pinned = true
            var thirdPin = viewer
            button.triggerPress(Qt.LeftButton)
            viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 3 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, thirdId, "all-pinned library keeps remembered selection")
            viewer.selectCamera(1)
            eventually(function() { return viewer.selectedCameraId === secondId && viewer.canDispose }, 4000)
            viewer.editSettings()
            find(viewer, function(i) { return i.objectName === "cameraName" }).text = "Selection draft"
            panel.runProfileOperation({action: "save", camera: {id: secondId, name: "Selection renamed",
                url: "rtsp://127.0.0.1:1/selection", username: "", password: ""}})
            eventually(function() { return viewer.cameras[1].name === "Selection renamed" && panel.canDispose }, 4000)
            wait(300)
            equal(viewer.selectedCameraId, secondId, "watchers do not undo manual selection")
            assertOk(viewer.configuring, "watchers preserve explicit Config")
            equal(find(viewer, function(i) { return i.objectName === "cameraName" }).text,
                "Selection draft", "watchers preserve Config draft after auto selection")
            equal(pin.selectedCameraId, secondId, "rename retains pinned stable ID")
            viewer.close(); pin.close(); firstPin.close(); thirdPin.close()
            eventually(function() { return widget.viewers.length === 0 }, 3000)
            // With no pins, opening must not prefer the first saved entry.
            panel.runProfileOperation({action: "select", id: secondId})
            eventually(function() { return panel.selectedCameraId === secondId && panel.canDispose }, 4000)
            button.triggerPress(Qt.LeftButton)
            viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 3 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, secondId, "no pins restore remembered camera")
            viewer.close()
            for (var id of [secondId, thirdId]) {
                panel.runProfileOperation({action: "delete", id: id})
                eventually(function() { return !panel.cameras.some(function(c) { return c.id === id }) && panel.canDispose }, 4000)
            }
            button.triggerPress(Qt.LeftButton)
            pin = widget.panel
            eventually(function() { return pin.cameras.length === 1 }, 4000)
            pin.pinned = true
            button.triggerPress(Qt.LeftButton)
            viewer = widget.panel
            eventually(function() { return viewer.cameras.length === 1 && viewer.canDispose }, 4000)
            equal(viewer.selectedCameraId, firstId, "single pinned camera falls back to remembered camera")
            viewer.close(); pin.close()
            eventually(function() { return widget.viewers.length === 0 }, 3000)
            panel.runProfileOperation({action: "delete", id: firstId})
            eventually(function() { return panel.cameras.length === 0 && panel.canDispose }, 4000)
            console.log("PASS: fresh bar selection: two/three cameras, saved list order, all pins skipped, all-pinned/single/no-pin fallbacks, manual selection, Config/watchers, stable rename")
        }
        function runGeometryRestart() {
            var ids = JSON.parse(Quickshell.env("CAMERA_TEST_GEOMETRY_RESTART"))
            widget.open(); var viewer = widget.panel
            // A fresh layer surface can land on another compositor output.
            // Restore the recorded scope explicitly rather than reading a
            // different monitor's correctly absent position file.
            viewer.geometryMonitorName = ids.screen
            // Keep the synthetic restart probe immune to outside-click dismissal
            // during asynchronous geometry loading, as in the other pin checks.
            viewer.pinned = true
            eventually(function() { return viewer.selectedCameraId === ids.a && viewer.viewerWidth === 710 }, 4000)
            var popup = find(viewer, function(i) { return i.cardOrigin !== undefined })
            eventually(function() { return popup.savedPosition !== null }, 4000)
            equal(popup.cardOrigin.x, 150, "new shell restores A x")
            equal(popup.cardOrigin.y, 170, "new shell restores A y")
            viewer.pinned = false; viewer.selectCamera(1)
            eventually(function() { return viewer.selectedCameraId === ids.b && viewer.viewerWidth === 670 }, 4000)
            viewer.pinned = true
            eventually(function() { return popup.savedPosition !== null }, 4000)
            equal(popup.cardOrigin.x, 230, "new shell restores B x")
            equal(popup.cardOrigin.y, 250, "new shell restores B y")
            viewer.close()
            eventually(function() { return widget.viewers.length === 0 }, 4000)
            console.log("PASS: per-camera geometry restored in a separate shell process")
        }
        function runGeometry() {
            widget.open()
            var viewer = widget.panel
            equal(viewer.cameraToken("front/雪 !'()-"), "front%2F%E9%9B%AA%20!'()%2D", "QML geometry encoding matches Python")
            eventually(function() { return viewer.cameras.length === 0 }, 4000)
            function add(name) {
                viewer.runProfileOperation({action: "save", camera: {name: name,
                    url: "rtsp://127.0.0.1:1/geometry", username: "", password: ""}})
                eventually(function() { return viewer.cameras.some(function(c) { return c.name === name }) && viewer.canDispose }, 4000)
                return viewer.selectedCameraId
            }
            var a = add("Geometry A"), b = add("Geometry B")
            var popup = find(viewer, function(i) { return i.cardOrigin !== undefined })
            function select(index) {
                viewer.pinned = false
                viewer.selectCamera(index)
                eventually(function() { return viewer.selectedCameraIndex === index && viewer.canDispose }, 4000)
                viewer.pinned = true
            }
            select(0)
            // Seed stale disk geometry, then return to the same ID while its
            // newer geometry is queued or deliberately held in a real Process.
            viewer.resizeViewer(640, 500); popup.movePinned(50, 60)
            eventually(function() { return viewer.canDispose }, 4000)
            var sizeProcess = find(viewer, function(i) { return i.command && i.command.indexOf("--view-size") >= 0 })
            var positionProcess = find(viewer, function(i) { return i.command && i.command.indexOf("--position") >= 0 })
            var originalSizeCommand = sizeProcess.command.slice()
            var originalPositionCommand = positionProcess.command.slice()
            function hold(command) {
                return ["python3", "-c", "import os,sys,time; time.sleep(1.5); os.execvp(sys.argv[1],sys.argv[1:])"].concat(command)
            }
            function stopDebounce() {
                // Both production geometry debounce timers are 300ms.
                for (var item of viewer.data) if (item.interval === 300 && item.stop) item.stop()
            }
            function switchBeforeSave(index) {
                viewer.pinned = false; viewer.selectCamera(index)
                eventually(function() { return viewer.selectedCameraIndex === index }, 4000)
                viewer.pinned = true
            }
            function latestGeometry(label, width, height, x, y) {
                equal(viewer.viewerWidth, width, label + " width")
                equal(viewer.viewerHeight, height, label + " height")
                equal(popup.cardOrigin.x, x, label + " x")
                equal(popup.cardOrigin.y, y, label + " y")
            }
            for (var inflight of [false, true]) {
                var w = inflight ? 750 : 730, h = inflight ? 590 : 570
                var x = inflight ? 120 : 110, y = inflight ? 140 : 130
                sizeProcess.command = hold(originalSizeCommand)
                positionProcess.command = hold(originalPositionCommand)
                viewer.resizeViewer(w, h); popup.movePinned(x, y)
                stopDebounce()
                if (inflight) {
                    viewer.saveViewerSize(); viewer.saveViewerPosition()
                    assertOk(sizeProcess.running && positionProcess.running, "real geometry saves held in flight")
                }
                switchBeforeSave(1); switchBeforeSave(0)
                latestGeometry("same-ID switchback immediately " + inflight, w, h, x, y)
                wait(200) // Give stale FileViews time to deliver their result.
                latestGeometry("same-ID switchback after readers " + inflight, w, h, x, y)
                var monitor = viewer.geometryMonitorName
                var delayedMonitor = "Geometry delayed monitor " + inflight
                viewer.geometryMonitorName = delayedMonitor
                wait(100)
                equal(popup.savedPosition, null, "unvisited monitor has no local position")
                popup.movePinned(180, 200); stopDebounce()
                viewer.geometryMonitorName = monitor
                latestGeometry("monitor switchback immediately " + inflight, w, h, x, y)
                wait(200)
                latestGeometry("monitor switchback after readers " + inflight, w, h, x, y)
                viewer.saveViewerSize(); viewer.saveViewerPosition()
                eventually(function() { return viewer.canDispose }, 6000)
                latestGeometry("switchback after delayed saves " + inflight, w, h, x, y)
                viewer.geometryMonitorName = delayedMonitor
                equal(popup.cardOrigin.x, 180, "second monitor restores its local snapshot")
                equal(popup.cardOrigin.y, 200, "second monitor restores its local y")
                viewer.geometryMonitorName = monitor
            }
            sizeProcess.command = originalSizeCommand
            positionProcess.command = originalPositionCommand
            console.log("PASS: real Widget queued/in-flight same-ID and same-monitor switchbacks, immediate/async/post-save geometry")
            viewer.resizeViewer(730, 570); popup.movePinned(110, 130)
            // Selection may finish before debounce; the snapshot must keep A's ID.
            viewer.pinned = false; viewer.selectCamera(1)
            eventually(function() { return viewer.selectedCameraId === b }, 4000)
            viewer.pinned = true
            viewer.resizeViewer(670, 510); popup.movePinned(230, 250)
            viewer.close() // Flush B before the debounce expires, then destroy/recreate.
            eventually(function() { return widget.viewers.length === 0 }, 4000)
            widget.open(); viewer = widget.panel
            eventually(function() { return viewer.selectedCameraId === b }, 4000)
            viewer.pinned = true // May precede the async geometry read.
            popup = find(viewer, function(i) { return i.cardOrigin !== undefined })
            eventually(function() { return viewer.viewerWidth === 670 && popup.savedPosition !== null }, 4000)
            equal(viewer.viewerHeight, 510, "B height survives recreation")
            equal(popup.cardOrigin.x, 230, "B x survives recreation")
            equal(popup.cardOrigin.y, 250, "B y survives recreation")
            select(0)
            eventually(function() { return viewer.viewerWidth === 730 && popup.savedPosition !== null }, 4000)
            equal(viewer.viewerHeight, 570, "A height survives rapid switch")
            equal(popup.cardOrigin.x, 110, "A x uses its own ID")
            equal(popup.cardOrigin.y, 130, "A y uses its own ID")
            // A duplicate's persistence must not live-teleport or resize this pin.
            widget.open(); var duplicate = widget.panel
            eventually(function() { return duplicate.cameras.length === 2 && duplicate.canDispose }, 4000)
            duplicate.selectCamera(0)
            eventually(function() { return duplicate.selectedCameraId === a && duplicate.viewerWidth === 730 }, 4000)
            duplicate.pinned = true
            var duplicatePopup = find(duplicate, function(i) { return i.cardOrigin !== undefined })
            duplicate.resizeViewer(710, 550); duplicatePopup.movePinned(150, 170)
            eventually(function() { return duplicate.canDispose }, 4000)
            equal(viewer.viewerWidth, 730, "duplicate write does not resize existing pin")
            equal(popup.cardOrigin.x, 110, "duplicate write does not teleport existing pin")
            duplicate.runProfileOperation({action: "save", camera: {id: a, name: "Geometry renamed",
                url: "rtsp://127.0.0.1:1/geometry", username: "", password: ""}})
            eventually(function() { return duplicate.cameras[0].name === "Geometry renamed" && duplicate.canDispose }, 4000)
            viewer.close(); duplicate.close()
            eventually(function() { return widget.viewers.length === 0 }, 4000)
            widget.open(); viewer = widget.panel
            eventually(function() { return viewer.selectedCameraId === a && viewer.viewerWidth === 710 }, 4000)
            viewer.pinned = true
            popup = find(viewer, function(i) { return i.cardOrigin !== undefined })
            eventually(function() { return popup.savedPosition !== null }, 4000)
            equal(popup.cardOrigin.x, 150, "rename restores same stable geometry ID")
            equal(popup.cardOrigin.y, 170, "rename restores y")
            var realMonitor = viewer.geometryMonitorName
            assertOk(typeof realMonitor === "string" && realMonitor.length > 0, "geometry has explicit monitor scope")
            viewer.geometryMonitorName = "Geometry test monitor/2"
            wait(150)
            equal(viewer.viewerWidth, 710, "monitor switch preserves camera size")
            equal(popup.savedPosition, null, "other monitor does not inherit position")
            equal(popup.cardOrigin.x, popup.anchoredOrigin.x, "unsaved monitor uses bar anchor")
            popup.movePinned(190, 210)
            eventually(function() { return viewer.canDispose }, 4000)
            viewer.geometryMonitorName = realMonitor
            eventually(function() { return popup.savedPosition !== null }, 4000)
            equal(popup.cardOrigin.x, 150, "returning monitor restores its own x")
            equal(popup.cardOrigin.y, 170, "returning monitor restores its own y")
            viewer.resetGeometry()
            viewer.resizeViewer(700, 540); popup.movePinned(160, 180)
            wait(200)
            equal(viewer.viewerWidth, 700, "late async size load cannot overwrite user's resize")
            equal(popup.cardOrigin.x, 160, "late async position load cannot overwrite user's move")
            viewer.resizeViewer(710, 550); popup.movePinned(150, 170)
            eventually(function() { return viewer.canDispose }, 4000)
            console.log("GEOMETRY_FILES " + JSON.stringify({a: a, b: b, screen: popup.screen.name}))
            popup.savedPosition = Qt.point(32768, 32768)
            viewer.pinned = false; viewer.pinned = true
            assertOk(popup.cardOrigin.x + popup.contentWidth <= popup.screenW
                && popup.cardOrigin.y + popup.contentHeight <= popup.screenH, "camera position clamps to monitor")
            viewer.close()
            eventually(function() { return widget.viewers.length === 0 }, 4000)
            for (var id of [a, b]) {
                panel.runProfileOperation({action: "delete", id: id})
                eventually(function() { return !panel.cameras.some(function(c) { return c.id === id }) && panel.canDispose }, 4000)
            }
            console.log("PASS: per-camera geometry, queued switch/close snapshots, recreate, early pin, duplicate isolation, rename, clamping")
        }
        function runProfiles() {
            panel.open()
            panel.editSettings(true)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var content = popup.contentItem[0]
            function field(name) { return find(content, function(i) { return i.objectName === name }) }
            field("cameraName").text = "Front door"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/front"
            field("cameraUsername").text = "test-user"
            field("cameraPassword").text = "test-password"
            panel.submitProfile()
            eventually(function() { return panel.cameras.length === 1 && !panel.configuring }, 4000)
            var offlineOverlay = field("videoOverlay")
            assertOk(offlineOverlay.item !== null && offlineOverlay.width > 0 && offlineOverlay.height > 0,
                "offline feed displays corner borders before its first video frame")
            equal(find(offlineOverlay.item, function(i) { return i.objectName === "overlayCorner" }).color.toString(),
                "#ff4545", "offline camera shows red corner borders")
            capture(content, "offline-feed")
            var firstId = panel.selectedCameraId
            panel.editSettings(true)
            equal(field("cameraUsername").text, "", "new camera does not inherit credentials")
            field("cameraName").text = "Garage"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/garage"
            panel.submitProfile()
            eventually(function() { return panel.cameras.length === 2 && !panel.configuring }, 4000)
            var secondId = panel.selectedCameraId
            equal(panel.config.url, "rtsp://127.0.0.1:1/garage", "new camera selected")
            var selector = field("cameraSelector")
            assertOk(field("nextCameraButton") === null && field("cameraTitle") === null,
                "standalone camera title and next button removed")
            assertOk(selector.visible && !field("addCameraButton").visible, "main header shows selector without add button")
            equal(selector.displayText, "Garage", "header selector shows current camera")
            panel.pinned = true
            mouseMove(selector, 20, selector.height / 2)
            wait(250)
            mouseClick(selector)
            wait(100)
            assertOk(selector.popup.visible, "camera dropdown opens")
            // Select the first actual dropdown entry with a mouse click.
            var entry = find(selector.popup.contentItem, function(i) { return i.text === "Front door" && i.clicked !== undefined })
            assertOk(entry !== null, "named camera appears in dropdown")
            mouseClick(entry)
            eventually(function() { return panel.selectedCameraId === firstId }, 4000)
            assertOk(!panel.configuring, "main selector switches feed without opening settings")
            equal(selector.displayText, "Front door", "selector updates after switch")
            panel.editSettings()
            assertOk(field("addCameraButton").visible, "add button is in Config")
            panel.selectCamera(1)
            eventually(function() { return panel.selectedCameraId === secondId }, 4000)
            assertOk(panel.configuring, "config selection stays in settings")
            panel.selectCamera(0)
            eventually(function() { return panel.selectedCameraId === firstId }, 4000)
            equal(field("cameraName").text, "Front door", "config selection populates camera form")
            equal(panel.config.username, "test-user", "switch restores per-camera credentials")
            equal(panel.config.url, "rtsp://127.0.0.1:1/front", "switch uses selected stream")
            panel.editSettings()
            field("cameraName").text = "Entrance"
            panel.submitProfile()
            eventually(function() { return panel.cameras[0].name === "Entrance" && !panel.configuring }, 4000)
            panel.editSettings(true)
            field("cameraName").text = "Entrance"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/duplicate"
            panel.submitProfile()
            eventually(function() { return panel.message !== "" }, 4000)
            equal(panel.cameras.length, 2, "duplicate name leaves profiles intact")
            assertOk(panel.configuring, "failed save keeps form open")
            panel.configuring = false
            panel.selectCamera(1)
            eventually(function() { return panel.selectedCameraId === secondId }, 4000)
            for (var newCamera of [false, true]) {
                panel.editSettings(newCamera)
                field("cameraAddress").text = "rtsp://127.0.0.1:1/unsaved"
                panel.close()
                panel.open()
                assertOk(!panel.configuring && panel.streaming, "reopening from Config returns to main camera screen")
                equal(panel.selectedCameraId, secondId, "reopening keeps the selected camera")
                equal(panel.config.url, "rtsp://127.0.0.1:1/garage", "closing Config does not save its draft")
            }
            panel.close()
            var restored = newPanel.createObject(barWindow.contentItem)
            eventually(function() { return restored.cameras.length === 2 }, 4000)
            equal(restored.selectedCameraId, secondId, "last selected camera restored")
            restored.destroy()
            panel.runProfileOperation({action: "delete", id: secondId})
            eventually(function() { return panel.cameras.length === 1 }, 4000)
            equal(panel.selectedCameraId, firstId, "deleting selected camera selects remaining one")
            panel.runProfileOperation({action: "delete", id: firstId})
            eventually(function() { return panel.cameras.length === 0 }, 4000)
            assertOk(!panel.configured && panel.configuring, "last deletion returns to setup")
            panel.open(); panel.close(); panel.open()
            assertOk(panel.configuring, "camera setup remains available when no cameras exist")
            console.log("PASS: profile form, dropdown switching, rename, duplicate handling, persistence, deletion")
        }
        function runRotation() {
            panel.open(); panel.pinned = true
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var content = popup.contentItem[0]
            parent = content
            function field(name) { return find(content, function(i) { return i.objectName === name }) }
            function add(name) {
                panel.editSettings(true)
                field("cameraName").text = name
                field("cameraAddress").text = "rtsp://127.0.0.1:1/rotation"
                panel.submitProfile()
                eventually(function() { return !panel.configuring }, 4000)
                return panel.selectedCameraId
            }
            var first = add("Rotate front"), second = add("Rotate back")
            var effect = field("videoEffect"), video = effect.sourceItem
            var overlay = field("videoOverlay")
            panel.viewerWidth = 860; panel.viewerHeight = 680
            panel.config = {url: Qt.resolvedUrl("rotation.mp4").toString(), username: "", password: ""}
            panel.play()
            eventually(function() { return panel.live }, 5000)
            panel.toggleAppearance()
            var rotation = field("videoRotation")
            assertOk(rotation !== null, "appearance editor offers per-camera rotation")
            equal(video.orientation, 0, "existing cameras default to zero rotation")
            field("overlayStyle").currentIndex = 0
            field("tintStrength").value = 35
            var corners = [["r","g","b","w"], ["b","r","w","g"],
                           ["w","b","g","r"], ["g","w","r","b"]]
            for (var style = 0; style < 4; style++) {
                field("videoStyle").currentIndex = style
                for (var index = 0; index < 4; index++) {
                    rotation.currentIndex = index
                    wait(300)
                    var rect = video.contentRect
                    assertOk(Math.abs(rect.width / rect.height - (index % 2 ? 0.75 : 4/3)) < 0.02,
                        "rotation preserves video proportions")
                    var name = "rotation-" + style + "-" + index
                    // QtTest's window grab is offset for this layer-shell popup.
                    // Item capture includes the whole feed; the Python runner checks its pixels.
                    capture(effect.parent, name, Quickshell.env("CAMERA_TEST_ROTATION_DIR"))
                    var points = []
                    for (var corner = 0; corner < 4; corner++) {
                        points.push([Math.floor(video.x + rect.x + rect.width * (corner % 2 ? 0.75 : 0.25)),
                                     Math.floor(video.y + rect.y + rect.height * (corner < 2 ? 0.25 : 0.75))])
                    }
                    console.log("ROTATION_PIXELS " + JSON.stringify({name: name, points: points, expected: corners[index]}))
                    equal(overlay.rotation, 0, "overlay remains upright")
                }
            }
            rotation.currentIndex = 1
            capture(content, "rotation-preview")
            var restored = newPanel.createObject(barWindow.contentItem)
            eventually(function() { return restored.selectedCameraId === second }, 4000)
            equal(restored.videoRotation, 0, "preview remains local before Apply")
            mouseClick(field("applyStyle"))
            eventually(function() { return !panel.editingAppearance && restored.videoRotation === 90 }, 4000)
            equal(video.orientation, 90, "Apply keeps the rotation")
            for (var size of [[860,440], [420,650]]) {
                panel.viewerWidth = size[0]; panel.viewerHeight = size[1]; wait(150)
                for (var name of ["audioButton", "themeButton"]) {
                    var button = field(name), point = button.mapToItem(overlay, 0, 0)
                    assertOk(point.x >= 0 && point.y >= 0 && point.x + button.width <= overlay.width + 1
                        && point.y + button.height <= overlay.height + 1, "controls fit rotated feed after resize")
                }
            }
            panel.toggleAppearance(); rotation.currentIndex = 2; panel.toggleAppearance()
            equal(video.orientation, 90, "closing the editor cancels the draft")
            panel.toggleAppearance(); rotation.currentIndex = 2; panel.close(); panel.open(); panel.pinned = true
            equal(video.orientation, 90, "closing the viewer cancels the draft")
            panel.toggleAppearance(); rotation.currentIndex = 2; panel.editSettings(); panel.configuring = false
            equal(video.orientation, 90, "opening Config cancels the draft")
            panel.toggleAppearance(); rotation.currentIndex = 2
            panel.selectCamera(0)
            eventually(function() { return panel.selectedCameraId === first }, 4000)
            assertOk(!panel.editingAppearance, "switching cameras discards the draft")
            equal(video.orientation, 0, "another camera keeps its own rotation")
            panel.toggleAppearance(); rotation.currentIndex = 3
            mouseClick(field("applyStyle"))
            eventually(function() { return !panel.editingAppearance }, 4000)
            panel.selectCamera(1)
            eventually(function() { return panel.selectedCameraId === second }, 4000)
            equal(video.orientation, 90, "switching back restores the camera rotation")
            panel.editSettings(); field("cameraName").text = "Rotated back"; panel.submitProfile()
            eventually(function() { return !panel.configuring }, 4000)
            equal(video.orientation, 90, "renaming keeps rotation by stable camera ID")
            restored.destroy()
            restored = newPanel.createObject(barWindow.contentItem)
            eventually(function() { return restored.selectedCameraId === second && restored.videoRotation === 90 }, 4000)
            restored.destroy()
            panel.close()
            console.log("PASS: rotation pixels in all styles, preview/cancel/apply, per-camera persistence, rename, switching, resize")
        }
        function runAppearance() {
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.configured = true; panel.configuring = false; panel.open()
            eventually(function() { return state().live }, 5000)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var content = popup.contentItem[0]
            // Give QtTest a window for key events even when the compositor has
            // not focused this pinned viewer after a synthetic mouse click.
            parent = content
            // Keep the synthetic interaction sequence safe from outside-click dismissal.
            // Explicit close/reopen and pin behavior are checked separately below.
            function click(item) { panel.pinned = true; wait(80); mouseClick(item); wait(80) }
            function field(name) { return find(content, function(i) { return i.objectName === name }) }
            var themeButton = field("themeButton")
            assertOk(themeButton !== null, "feed offers a theme button")
            var editor = field("themeEditor")
            var chooser = field("videoStyle"), strength = field("tintStrength"), pixelSize = field("pixelSize")
            var apply = field("applyStyle"), effect = field("videoEffect")
            var overlayChooser = field("overlayStyle"), overlay = field("videoOverlay")
            assertOk(overlayChooser !== null && overlay !== null, "theme editor offers overlays")
            equal(overlayChooser.model[2], "Hackerman", "overlay chooser uses the Hackerman name")
            equal(overlay.mode, "default", "first run uses Default overlay")
            assertOk(overlay.item !== null, "Default draws corner borders")
            assertOk(!editor.visible, "theme editor starts hidden")
            var fullHeight = effect.height, beforeFrames = panel.framesReceived
            click(themeButton)
            wait(150)
            assertOk(editor.visible && !panel.configuring && state().live, "theme button opens editor while video plays")
            assertOk(effect.height >= 120 && effect.height < fullHeight, "editor leaves space for live feed")
            assertOk(editor.y >= effect.parent.y + effect.parent.height, "theme section sits below video")
            equal(panel.videoStyle, "theme", "first run uses theme tint")
            assertOk(!pixelSize.visible && strength.visible, "default theme tint shows strength slider")
            click(chooser)
            wait(100)
            assertOk(chooser.popup.visible, "video style dropdown opens")
            var choice = find(chooser.popup.contentItem, function(i) { return i.text === "Omarchy Pixel" && i.clicked !== undefined })
            assertOk(choice !== null, "Omarchy Pixel is available in dropdown")
            click(choice)
            assertOk(strength.visible && pixelSize.visible, "Omarchy Pixel shows both sliders")
            equal(pixelSize.value, 3, "default preserves previous pixel look")
            pixelSize.value = 8; strength.value = 60
            overlayChooser.currentIndex = 2
            wait(200)
            equal(effect.style, "theme-pixel", "style previews before saving; opened=" + panel.opened
                + ", editing=" + panel.editingAppearance + ", selected=" + chooser.currentIndex)
            equal(effect.pixelSize, 8, "pixel size previews before saving")
            equal(effect.strength, 0.6, "tint previews before saving")
            equal(overlay.mode, "hacker", "overlay previews before saving")
            assertOk(overlay.item !== null, "selected overlay is rendered")
            equal(panel.overlayStyle, "default", "overlay preview does not change saved setting")
            equal(panel.videoStyle, "theme", "preview does not change saved style")
            assertOk(panel.framesReceived > beforeFrames, "preview keeps receiving video")
            var universalAudio = field("audioButton")
            for (var styleIndex = 0; styleIndex < 4; styleIndex++) {
                chooser.currentIndex = styleIndex
                for (var overlayIndex = 0; overlayIndex < 3; overlayIndex++) {
                    overlayChooser.currentIndex = overlayIndex
                    wait(30)
                    assertOk(universalAudio.visible && universalAudio.enabled, "waveform available with every style and overlay")
                    click(universalAudio)
                    assertOk(!state().muted, "waveform unmutes with style " + styleIndex + " overlay " + overlayIndex)
                    click(universalAudio)
                    assertOk(state().muted, "waveform mutes with every style and overlay")
                }
            }
            chooser.currentIndex = 3; overlayChooser.currentIndex = 2
            wait(100)
            var restored = newPanel.createObject(barWindow.contentItem)
            wait(200)
            equal(restored.videoStyle, "theme", "draft stays local to current viewer")
            capture(content, "theme-preview")
            click(apply)
            eventually(function() { return !editor.visible && restored.videoStyle === "theme-pixel" }, 3000)
            equal(panel.tintStrength, 60, "tint strength saved")
            equal(panel.pixelSize, 8, "pixel size saved")
            equal(panel.overlayStyle, "hacker", "overlay saved")
            equal(restored.overlayStyle, "hacker", "other viewer receives saved overlay")
            equal(restored.tintStrength, 60, "other viewer receives saved tint")
            equal(restored.pixelSize, 8, "other viewer receives saved pixel size")
            eventually(function() { return effect.height === fullHeight }, 1000)
            var overlayTick = overlay.item.tick
            wait(600)
            assertOk(overlay.item.tick !== overlayTick, "terminal clock advances while real video frames arrive")
            var waveButton = field("audioButton")
            assertOk(waveButton.enabled && state().muted, "waveform starts ready to unmute the camera")
            click(waveButton)
            assertOk(!state().muted, "clicking waveform unmutes real audio output")
            waveButton.forceActiveFocus()
            keyClick(Qt.Key_Space)
            assertOk(state().muted, "keyboard activates waveform mute button")
            assertOk(waveButton.parent === overlay.parent, "waveform is independent of overlay selection")
            assertOk(find(content, function(i) { return i.text === "LIVE" || i.text === "OFFLINE" }) === null, "LIVE/OFFLINE chip is removed")
            var consoleLine = find(overlay.item, function(i) { return i.text === "$ monitor --stream" })
            assertOk(consoleLine !== null, "terminal readout is available")
            var headerLine = find(overlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf(">_ ") === 0 })
            equal(headerLine.parent.color.a, 0, "terminal header background is transparent")
            assertOk(Math.abs(consoleLine.parent.parent.color.a - 0.39) < 0.01, "lower console background has half its previous opacity")
            var consoleBox = consoleLine.parent.parent
            assertOk(Math.abs(consoleBox.mapToItem(content, 0, consoleBox.height).y
                - themeButton.mapToItem(content, 0, themeButton.height).y) < 1,
                "console and theme button align at the bottom")
            capture(content, "theme-applied")
            var savedWidth = panel.viewerWidth, savedHeight = panel.viewerHeight
            for (var size of [[860, 440], [420, 650], [420, 440]]) {
                panel.viewerWidth = size[0]; panel.viewerHeight = size[1]
                wait(150)
                var audioPosition = waveButton.mapToItem(overlay, 0, 0)
                assertOk(audioPosition.x >= overlay.width / 2
                    && audioPosition.x + waveButton.width <= overlay.width - overlay.item.inset - 4
                    && audioPosition.y >= overlay.item.inset + 4
                    && audioPosition.y + waveButton.height <= overlay.height,
                    "waveform stays inside video clear of top-right corner after resize")
                for (var control of themeButton.parent.children) {
                    if (control.text === undefined || !control.visible) continue
                    var position = control.mapToItem(overlay, 0, 0)
                    assertOk(position.x >= overlay.item.inset + 4
                        && position.x + control.width <= overlay.width - overlay.item.inset - 4,
                        "feed controls stay within video sides after resize")
                    assertOk(position.y >= 0
                        && position.y + control.height <= overlay.height - overlay.item.inset - 8,
                        "feed controls clear bottom overlay corners after resize")
                }
            }
            panel.viewerWidth = savedWidth; panel.viewerHeight = savedHeight
            wait(150)
            for (var profile of ["default", "coder", "hacker"]) {
                panel.overlayStyle = profile
                wait(100)
                var lowerConsole = field("terminalConsole")
                var topLine = find(overlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf(">_ ") === 0 })
                equal(lowerConsole.visible, profile !== "default", "Coder and Hacker show the lower terminal")
                equal(topLine.visible, profile === "hacker", "only Hacker shows the top terminal")
                equal(field("terminalScanBand").visible, profile === "hacker", "only Hacker shows the sweep")
                if (lowerConsole.visible) {
                    assertOk(lowerConsole.mapToItem(content, lowerConsole.width, 0).x + 8
                        <= themeButton.mapToItem(content, 0, 0).x, "terminal clears the theme button")
                }
                capture(content, "profile-" + profile)
            }
            equal(effect.parent.border.color.toString(), Color.accent.toString(), "video frame follows theme accent")
            equal(effect.style, "theme-pixel", "applied effect remains after editor hides")
            click(themeButton)
            equal(chooser.currentIndex, 3, "reopening loads saved style")
            equal(overlayChooser.currentIndex, 2, "reopening loads saved overlay")
            overlayChooser.currentIndex = 1
            wait(100)
            assertOk(waveButton.visible, "waveform remains available with HUD")
            chooser.currentIndex = 2
            assertOk(pixelSize.visible && !strength.visible, "Pixel shows only pixel size")
            chooser.currentIndex = 1
            assertOk(!pixelSize.visible && strength.visible, "Omarchy shows only tint strength")
            click(themeButton)
            assertOk(!editor.visible, "theme button can dismiss editor")
            equal(effect.style, "theme-pixel", "dismissal restores applied appearance")
            equal(overlay.mode, "hacker", "dismissal restores applied overlay")
            click(themeButton)
            chooser.currentIndex = 0
            panel.editSettings()
            assertOk(!editor.visible && !chooser.visible, "connection Config contains no theme controls")
            panel.configuring = false
            equal(effect.style, "theme-pixel", "opening connection Config discards preview")
            click(themeButton)
            chooser.currentIndex = 0
            panel.close()
            panel.open()
            assertOk(!editor.visible, "closing viewer hides theme section")
            equal(effect.style, "theme-pixel", "closing viewer discards preview")
            click(themeButton)
            chooser.currentIndex = 0
            click(apply)
            eventually(function() { return !editor.visible && restored.videoStyle === "original" }, 3000)
            restored.destroy()
            panel.close(); panel.configured = false
            console.log("PASS: live theme preview, apply/collapse, persistence, shared settings, draft cancellation")
        }
        function runEffectPixels() {
            effectWindow.visible = true
            wait(200)
            var original = grabImage(fixture)
            fixtureEffect.style = "pixel"
            wait(200)
            assertOk(!fixtureEffect.failed, "pixel shader compiles")
            var pixel = grabImage(fixture)
            assertOk(!original.equals(pixel), "pixel style changes the rendered image")
            var scale = pixel.width / fixture.width
            // Sample block interiors; exact boundaries can round to either texel on the GPU.
            equal(pixel.red(31 * scale, 80 * scale), pixel.red(32 * scale, 80 * scale), "adjacent pixels form crisp blocks")
            assertOk(pixel.red(34 * scale, 80 * scale) !== pixel.red(31 * scale, 80 * scale), "neighboring blocks retain detail")
            fixtureEffect.pixelSize = 12
            wait(200)
            var coarse = grabImage(fixture)
            equal(coarse.red(25 * scale, 80 * scale), coarse.red(33 * scale, 80 * scale), "larger size creates larger blocks")
            assertOk(!pixel.equals(coarse), "changing pixel size updates rendered output")
            fixtureEffect.pixelSize = 1
            wait(200)
            assertOk(sameResampledImage(original, grabImage(fixture)), "one pixel size preserves detail on scaled monitors")
            fixtureEffect.pixelSize = 3
            var oldBackground = Color.background, oldForeground = Color.foreground, oldAccent = Color.accent
            try {
                Color.background = "black"; Color.foreground = "red"; Color.accent = "red"
                fixtureEffect.style = "theme"; fixtureEffect.strength = 1
                wait(200)
                var tinted = grabImage(fixture)
                assertOk(tinted.red(180 * scale, 80 * scale) > 100 && tinted.green(180 * scale, 80 * scale) < 5,
                    "theme maps feed to the active palette")
                equal(tinted.red(20 * scale, 25 * scale), 255, "overlay remains sharp and unfiltered")
                fixtureEffect.strength = 0
                wait(200)
                assertOk(sameResampledImage(original, grabImage(fixture)), "zero tint preserves original colors on scaled monitors")
                fixtureEffect.strength = 1
                Color.foreground = "lime"; Color.accent = "lime"
                wait(200)
                var changed = grabImage(fixture)
                assertOk(changed.green(180 * scale, 80 * scale) > 100 && changed.red(180 * scale, 80 * scale) < 5,
                    "theme switches update the existing effect")
                fixtureEffect.style = "theme-pixel"
                wait(200)
                var combined = grabImage(fixture)
                equal(combined.green(31 * scale, 80 * scale), combined.green(32 * scale, 80 * scale), "combined style retains crisp pixels")
                fixtureEffect.active = false
                wait(100)
                assertOk(original.equals(grabImage(fixture)) && fixtureEffect.item === null, "inactive effect releases capture and restores source")
            } finally {
                Color.background = oldBackground; Color.foreground = oldForeground; Color.accent = oldAccent
                fixtureEffect.style = "original"; fixtureEffect.active = true
                effectWindow.visible = false
            }
            console.log("PASS: rendered pixels, tint strength, live palette changes, sharp overlay, effect cleanup")
        }
        function cpuTicks() {
            processStats.reload()
            var fields = processStats.text().split(") ")[1].split(" ")
            return Number(fields[11]) + Number(fields[12])
        }
        function runOverlayPixels() {
            effectWindow.visible = true
            wait(150)
            var original = grabImage(fixture)
            fixtureOverlay.mode = "default"; fixtureOverlay.active = true
            wait(100)
            var corner = find(fixtureOverlay.item, function(i) { return i.objectName === "overlayCorner" })
            equal(corner.color.toString(), "#ff4545", "offline corners are red")
            assertOk(find(fixtureOverlay.item, function(i) { return i.objectName === "overlayActivityDot" }) === null,
                "Default has no activity dots")
            assertOk(!find(fixtureOverlay.item, function(i) { return i.objectName === "terminalScanBand" }).visible,
                "Default has no scanning band")
            var defaultTick = fixtureOverlay.item.tick
            wait(200)
            equal(fixtureOverlay.item.tick, defaultTick, "Default needs no terminal animation clock")
            fixtureOverlay.live = true
            equal(corner.color.toString(), Color.accent.toString(), "connected corners use theme accent")
            var defaultImage = grabImage(fixture)
            capture(fixture, "overlay-default")
            fixtureOverlay.mode = "coder"
            wait(150)
            var hudImage = grabImage(fixture)
            assertOk(!defaultImage.equals(hudImage), "Coder adds right-side activity dots")
            assertOk(find(fixtureOverlay.item, function(i) { return i.objectName === "overlayActivityDot" }) !== null,
                "Coder includes activity dots")
            assertOk(!find(fixtureOverlay.item, function(i) { return i.objectName === "terminalScanBand" }).visible,
                "Coder has no scanning band")
            capture(fixture, "overlay-coder")
            fixtureOverlay.mode = "hacker"; fixtureOverlay.live = false
            wait(150)
            var terminalImage = grabImage(fixture)
            assertOk(!hudImage.equals(terminalImage), "terminal overlay has its own visible design")
            capture(fixture, "overlay-terminal")
            fixtureOverlay.live = true
            fixtureOverlay.framesReceived = 42
            wait(100)
            var liveImage = grabImage(fixture)
            assertOk(!terminalImage.equals(liveImage), "overlay reflects actual live status")
            wait(350)
            assertOk(!liveImage.equals(grabImage(fixture)), "live terminal overlay animates")
            eventually(function() {
                return find(fixtureOverlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf("0000002A") >= 0 }) !== null
            }, 1500)
            var terminal = fixtureOverlay.item
            var band = find(terminal, function(i) { return i.objectName === "terminalScanBand" })
            assertOk(band !== null, "scanner exists")
            var wave = fixtureWave
            wave.visible = true
            assertOk(!wave.enabled, "waveform button is disabled without an audio track")
            var audioRequests = 0
            var onAudioRequest = function() { audioRequests++ }
            wave.clicked.connect(onAudioRequest)
            mouseClick(wave)
            equal(audioRequests, 0, "disabled waveform cannot request audio playback")
            wave.clicked.disconnect(onAudioRequest)
            var waveImage = grabImage(wave)
            wait(250)
            assertOk(!waveImage.equals(grabImage(wave)), "decorative waveform animates")
            wave.visible = false
            var waveTick = wave.tick
            wait(200)
            equal(wave.tick, waveTick, "hidden waveform stops its timer")
            var previous = band.y
            var minY = previous, maxY = previous, stationary = 0, down = 0, up = 0
            // Exercise more than the reported 30-second freeze, including status churn.
            for (var sample = 0; sample < 400; sample++) {
                fixtureOverlay.live = false
                fixtureOverlay.live = true
                wait(80)
                var current = band.y
                if (Math.abs(current - previous) < 0.1) stationary++
                else stationary = 0
                assertOk(stationary < 3, "scan keeps moving despite frame-status changes")
                if (current > previous) down++
                if (current < previous) up++
                minY = Math.min(minY, current); maxY = Math.max(maxY, current)
                assertOk(current >= terminal.inset - 1 && current + band.height <= terminal.height - terminal.inset + 1,
                    "scanner stays inside the video")
                previous = current
            }
            assertOk(down > 100 && up > 100, "scanner continuously travels in both directions")
            assertOk(maxY - minY > (terminal.height - terminal.inset * 2 - band.height) * 0.9,
                "scanner sweeps the full video height")
            fixtureOverlay.live = false
            previous = band.y
            wait(400)
            equal(band.y, previous, "Hackerman sweep freezes in place while offline")
            fixtureOverlay.live = true
            assertOk(Math.abs(band.y - previous) < 1, "reconnection preserves the sweep position")
            wait(240)
            assertOk(Math.abs(band.y - previous) > 1, "Hackerman sweep resumes when connected")
            terminal.visible = false
            wait(100)
            var hiddenTick = terminal.tick, hiddenProgress = terminal.scanProgress
            wait(250)
            equal(terminal.tick, hiddenTick, "hidden overlay stops its decoration clock")
            equal(terminal.scanProgress, hiddenProgress, "hidden overlay stops its sweep")
            terminal.visible = true
            wait(100)
            liveImage = grabImage(fixture)
            var oldAccent = Color.accent
            try {
                Color.accent = Color.accent.toString() === "#ff0000" ? "lime" : "red"
                wait(100)
                assertOk(!liveImage.equals(grabImage(fixture)), "overlay follows palette changes")
            } finally { Color.accent = oldAccent }
            fixtureOverlay.active = false
            wait(100)
            assertOk(fixtureOverlay.item === null && original.equals(grabImage(fixture)), "inactive overlay releases geometry")
            fixtureOverlay.mode = "default"; fixtureOverlay.active = true
            wait(100)
            assertOk(fixtureOverlay.item !== null && !original.equals(grabImage(fixture)), "Default restores corner borders")
            fixtureOverlay.active = false
            effectWindow.visible = false
            console.log("PASS: Default/Coder/Hacker pixels, continuous sweep, decorative waveform, frame counter, hidden pause, palette binding, overlay cleanup")
        }
        function runVideoStyles(benchmark) {
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.configured = true; panel.configuring = false; panel.open(); panel.pinned = true
            eventually(function() { return state().live }, 5000)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var effect = find(popup.contentItem[0], function(i) { return i.objectName === "videoEffect" })
            var baseline
            for (var style of ["original", "theme", "pixel", "theme-pixel"]) {
                panel.videoStyle = style
                wait(300)
                assertOk(!effect.failed, style + " shader loads")
                var beforeFrames = panel.framesReceived, beforeTime = Date.now(), beforeCpu = cpuTicks()
                wait(benchmark ? 4000 : 400)
                assertOk(panel.framesReceived > beforeFrames && state().live, style + " receives live video")
                var elapsed = Date.now() - beforeTime
                if (benchmark) console.log("BENCHMARK", style,
                    "CPU % of one core:", ((cpuTicks() - beforeCpu) / Number(Quickshell.env("CAMERA_CLOCK_TICKS")) / (elapsed / 1000) * 100).toFixed(1),
                    "frames/s:", ((panel.framesReceived - beforeFrames) / (elapsed / 1000)).toFixed(1))
                var frame = grabImage(effect.parent)
                capture(effect.parent, style)
                if (style === "original") { baseline = frame; assertOk(effect.item === null, "Original bypasses effect") }
                if (style === "theme" || style === "theme-pixel") assertOk(!baseline.equals(frame), style + " filters actual video frames")
            }
            panel.editSettings()
            assertOk(effect.item === null, "settings unload video effect")
            panel.close()
            panel.videoStyle = "original"
            console.log("PASS: playback in all four styles and resource cleanup")
        }
        function state() { return JSON.parse(panel.playbackStatus()) }
        function runReconnect() {
            // Keep synthetic recovery waits immune to outside-click dismissal.
            panel.config = {url: "rtsp://127.0.0.1:1/live", username: "", password: ""}
            panel.configured = true
            panel.configuring = false
            panel.open()
            panel.pinned = true
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 2000, "first retry delay")
            eventually(function() { return state().retryAttempt >= 2 }, 5000)
            equal(state().retryDelay, 4000, "second retry delay")
            eventually(function() { return state().retryAttempt >= 3 }, 6000)
            equal(state().retryDelay, 8000, "third retry delay")
            panel.scheduleReconnect("Duplicate failure")
            equal(state().retryAttempt, 3, "duplicate failure does not enqueue another retry")
            panel.retryAttempt = 5
            panel.play(false)
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 30000, "retry delay capped")
            panel.play()
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 2000, "manual retry resets delay")
            panel.editSettings()
            assertOk(!state().reconnectPending, "settings cancel reconnect")
            wait(2200)
            assertOk(!state().playing && !state().timeoutRunning, "settings remain stopped")
            panel.configuring = false
            eventually(function() { return state().reconnectPending }, 4000)
            panel.close()
            assertOk(!state().reconnectPending, "close cancels reconnect")
            wait(2200)
            assertOk(!state().playing && !state().timeoutRunning, "closed viewer remains stopped")
            panel.open()
            panel.pinned = true
            eventually(function() { return state().reconnectPending }, 4000)
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.play(false)
            eventually(function() { return state().live }, 5000)
            equal(state().retryAttempt, 0, "healthy frames reset retry delay")
            assertOk(!state().reconnectPending, "healthy stream cancels retries")
            var player = find(panel, function(i) { return i.playbackState !== undefined && i.source !== undefined })
            player.stop()
            eventually(function() { return state().reconnectPending }, 2000)
            equal(state().retryDelay, 2000, "interrupted live stream retries")
            panel.config = {url: Qt.resolvedUrl("stall.mp4").toString(), username: "", password: ""}
            panel.play()
            eventually(function() { return state().live }, 5000)
            eventually(function() { return state().reconnectPending }, 7000)
            assertOk(state().message.indexOf("Video stalled.") === 0, "stalled frames trigger recovery")
            panel.close()
            console.log("PASS: automatic reconnect, backoff, recovery, stall detection, and cancellation")
        }
        function runDrag() {
            panel.open()
            panel.pinned = true
            wait(500)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            console.log("POPUP", popup)
            var title = find(popup.contentItem[0], function(i) { return i.objectName === "headerDragSpace" })
            console.log("TITLE", title)
            console.log("GEOMETRY", title.width, title.height, popup.cardOrigin)
            var pin = find(popup.contentItem[0], function(i) { return i.checkable === true })
            assertOk(pin !== null && pin.checked, "pin toggle reflects pinned mode")
            mouseClick(pin)
            assertOk(!panel.pinned && !pin.checked, "pin toggle unpins")
            mouseClick(pin)
            assertOk(panel.pinned && pin.checked, "pin toggle pins")
            console.log("PASS: pin toggle switches both ways")
            var origin = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            mousePress(title, 20, title.height / 2, Qt.LeftButton)
            mouseMove(title, -80, title.height / 2 + 100, 100)
            mouseRelease(title, 20, title.height / 2, Qt.LeftButton)
            wait(100)
            console.log("AFTER", popup.cardOrigin)
            assertOk(popup.cardOrigin.x < origin.x, "moves left")
            assertOk(popup.cardOrigin.y > origin.y, "moves down")
            console.log("PASS: pinned mouse drag moved left and down")
            var header = title.parent
            var gapX = title.x + title.width / 2
            var beforeGap = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            mousePress(header, gapX, header.height / 2, Qt.LeftButton)
            mouseMove(header, gapX - 60, header.height / 2 + 60, 100)
            mouseRelease(header, gapX, header.height / 2, Qt.LeftButton)
            wait(100)
            assertOk(popup.cardOrigin.x < beforeGap.x && popup.cardOrigin.y > beforeGap.y,
                "empty header space drags pinned camera")
            console.log("PASS: empty header drag area")
            panel.configuring = false
            wait(250)
            var status = find(popup.contentItem[0], function(i) { return i.text === "OFFLINE" || i.text === "LIVE" })
            var theme = find(popup.contentItem[0], function(i) { return i.objectName === "themeButton" })
            assertOk(status === null, "no status chip while offline")
            assertOk(theme !== null && theme.visible, "theme button visible")
            console.log("PASS: theme control visible without status chip")
            mouseMove(theme, 10, 10)
            wait(250)
            equal(popup.chromeOpacity, 1, "hover restores surrounding UI")
            mouseMove(popup.contentItem[0], -80, -80)
            wait(250)
            equal(popup.chromeOpacity, 0, "leaving pinned viewer hides surrounding UI")
            equal(title.parent.parent.opacity, 0, "header fades out")
            equal(theme.parent.opacity, 1, "feed controls remain opaque")
            equal(theme.parent.parent.opacity, 1, "feed remains opaque")
            panel.pinned = false
            wait(250)
            equal(popup.chromeOpacity, 1, "unpinned UI stays visible without hover")
            panel.pinned = true
            wait(250)
            console.log("PASS: pinned hover fade preserves feed and overlay controls")
            var saved = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            eventually(function() { return !JSON.parse(panel.playbackStatus()).positionPending }, 3000)
            equal(panel.positionSaveError, "", "position saved")
            panel.close()
            var restoredPanel = newPanel.createObject(barWindow.contentItem)
            wait(500)
            restoredPanel.open()
            restoredPanel.pinned = true
            var restored = find(restoredPanel, function(i) { return i.cardOrigin !== undefined })
            eventually(function() { return restored.savedPosition !== null }, 3000)
            equal(restored.cardOrigin.x, saved.x, "new viewer restores saved x")
            equal(restored.cardOrigin.y, saved.y, "new viewer restores saved y")
            restored.savedPosition = Qt.point(32768, 32768)
            restoredPanel.pinned = false
            restoredPanel.pinned = true
            assertOk(restored.cardOrigin.x + restored.contentWidth <= restored.screenW, "position clamped horizontally")
            assertOk(restored.cardOrigin.y + restored.contentHeight <= restored.screenH, "position clamped vertically")
            restoredPanel.close()
            restoredPanel.destroy()
            console.log("PASS: saved position survives new viewer and clamps to screen")

        }
    }
}
