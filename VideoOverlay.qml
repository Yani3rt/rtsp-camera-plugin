import QtQuick

// All profiles share the same corners and spacing; extra decorations are tiered.
Loader {
    id: root
    property string mode: "default"
    property string cameraName: "Camera"
    property bool live: false
    property real rightHeaderSpace: 0
    property double framesReceived: 0
    clip: true
    sourceComponent: Component {
        TerminalOverlay {
            profile: root.mode
            cameraName: root.cameraName
            live: root.live
            framesReceived: root.framesReceived
            rightHeaderSpace: root.rightHeaderSpace
        }
    }
}
