import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
    id: root
    moduleName: "yani.camera"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    // Only the selectable popup participates in the bar's popup lifecycle.
    property var panel: null
    property var viewers: []
    readonly property bool opened: !!panel && panel.opened
    readonly property bool popoutSwitchClosing: !!panel && panel.popoutSwitchClosing
    readonly property var currentViewer: panel || viewers.slice().reverse().find(function(viewer) { return viewer.opened }) || null

    function open() {
        if (!panel) {
            // Snapshot stable IDs before the new viewer's asynchronous file load.
            panel = viewerComponent.createObject(root, {initialPinnedCameraIds: viewers
                .filter(function(viewer) { return viewer.opened && viewer.pinned })
                .map(function(viewer) { return viewer.fixedCameraId || viewer.selectedCameraId })})
            viewers = viewers.concat([panel])
        }
        panel.open()
    }
    function close() { if (currentViewer) currentViewer.close() }
    function togglePanel() { opened ? panel.close() : open() }
    function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }
    function viewerPinned(viewer) {
        if (!viewer.opened) return
        if (viewer.pinned) {
            viewer.fixedCameraId = viewer.selectedCameraId
            if (panel === viewer) panel = null
        } else {
            // Unpinning replaces only the selectable popup, never another pin.
            if (panel && panel !== viewer) panel.close()
            panel = viewer
            viewer.fixedCameraId = ""
        }
    }
    function viewerClosed(viewer) {
        if (panel === viewer) panel = null
        cleanup.start()
    }
    Timer {
        id: cleanup
        interval: 200
        repeat: true
        onTriggered: {
            var remaining = []
            for (var viewer of root.viewers) {
                if (!viewer.opened && viewer.canDispose) viewer.destroy()
                else remaining.push(viewer)
            }
            root.viewers = remaining
            if (!remaining.some(function(viewer) { return !viewer.opened })) stop()
        }
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\udb81\udfae" // Material Design CCTV (U+F07AE).
        fontFamily: "JetBrainsMono Nerd Font"
        tooltipText: "Camera"
        onPressed: root.togglePanel()
    }
    Component {
        id: viewerComponent
        CameraPanel {
            bar: root.bar
            anchorItem: button
            independentViewerSize: true
            onPinnedChanged: root.viewerPinned(this)
            onOpenedChanged: if (!opened) root.viewerClosed(this)
        }
    }
    IpcHandler {
        target: "yani.camera"
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.togglePanel() }
        function status(): string { return root.currentViewer ? root.currentViewer.playbackStatus() : "{}" }
        function toggleAudio(): void { if (root.currentViewer) root.currentViewer.toggleAudio() }
        function resize(width: int, height: int): void { if (root.currentViewer) root.currentViewer.resizeViewer(width, height) }
        function togglePin(): void { if (root.currentViewer) root.currentViewer.pinned = !root.currentViewer.pinned }
    }
}
