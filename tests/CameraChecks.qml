import QtQuick
import QtTest
import Quickshell
import "Camera"
ShellRoot {
    PanelWindow {
        id: barWindow
        anchors { top: true; left: true; right: true }
        implicitHeight: 28
        Item { id: anchor; x: 700; width: 30; height: 28 }
    }
    QtObject {
        id: fakeBar
        property string position: "top"
        property int barSize: 28
        property color foreground: "white"
        property color barForeground: "white"
        property var activePopout: null
        function requestPopout(key) { activePopout = key }
        function releasePopout(key) { activePopout = null }
    }
    CameraPanel { id: panel; bar: fakeBar; anchorItem: anchor }
    Component { id: newPanel; CameraPanel { bar: fakeBar; anchorItem: anchor } }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            try { probe.runDrag(); if (Quickshell.env("CAMERA_TEST_UI_ONLY") !== "1") probe.runReconnect(); probe.runProfiles(); console.log("CAMERA_CHECKS_PASSED") }
            catch (error) { console.error("CAMERA_CHECKS_FAILED", error) }
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
            console.log("PASS: profile form, dropdown switching, rename, duplicate handling, persistence, deletion")
        }
        function state() { return JSON.parse(panel.playbackStatus()) }
        function runReconnect() {
            panel.config = {url: "rtsp://127.0.0.1:1/live", username: "", password: ""}
            panel.configured = true
            panel.configuring = false
            panel.open()
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
            var status = find(popup.contentItem[0], function(i) { return i.text === "OFFLINE" })
            var reconnect = find(popup.contentItem[0], function(i) { return i.text === "\u21bb" })
            assertOk(status !== null && status.visible, "offline pill visible")
            assertOk(reconnect !== null && reconnect.visible, "reconnect visible")
            console.log("PASS: overlay controls visible", status.width, status.height)
            mouseMove(status, 10, 10)
            wait(250)
            equal(popup.chromeOpacity, 1, "hover restores surrounding UI")
            mouseMove(popup.contentItem[0], -80, -80)
            wait(250)
            equal(popup.chromeOpacity, 0, "leaving pinned viewer hides surrounding UI")
            equal(title.parent.parent.opacity, 0, "header fades out")
            equal(status.parent.opacity, 1, "feed controls remain opaque")
            equal(status.parent.parent.opacity, 1, "feed remains opaque")
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
