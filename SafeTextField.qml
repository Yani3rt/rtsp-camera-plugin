import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Ui

// Native input remains read-only for its entire lifetime. Only local key text
// and the bounded helper result may mutate text; never call native paste().
TextField {
    id: field
    readOnly: true
    // Override Controls' deferred TextEditingContextMenu, including keyboard
    // invocation. A read-only native input must not expose native edit actions.
    Controls.ContextMenu.menu: null
    selectByMouse: true
    activeFocusOnTab: true
    maximumLength: 4096
    rightPadding: 60
    property int editEpoch: 0
    property string requestScope: ""
    onRequestScopeChanged: editEpoch++
    property var pasteSnapshot: null
    readonly property bool pastePending: pasteSnapshot !== null || pasteProcess.running
    signal pasteRejected()
    onTextChanged: editEpoch++
    onCursorPositionChanged: editEpoch++
    onSelectionStartChanged: editEpoch++
    onSelectionEndChanged: editEpoch++
    onActiveFocusChanged: editEpoch++
    onEnabledChanged: editEpoch++

    function replaceSelection(value) {
        if (!enabled || /[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(value)) return
        var start = selectionStart, end = selectionEnd
        var next = text.slice(0, start) + value + text.slice(end)
        if (next.length > maximumLength) { pasteRejected(); return }
        text = next
        cursorPosition = start + value.length
    }
    function requestPaste() {
        if (!enabled || pastePending) return
        forceActiveFocus()
        pasteSnapshot = {epoch: editEpoch, start: selectionStart, end: selectionEnd}
        pasteProcess.running = true
    }
    // Read-only Qt navigation and mouse selection are safe. Intercept all
    // modifying shortcuts BEFORE native TextInput; cut/copy are disabled.
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
        var altGr = event.modifiers & Qt.GroupSwitchModifier
        var ctrl = (event.modifiers & Qt.ControlModifier) && !altGr
        var shift = event.modifiers & Qt.ShiftModifier
        if (event.key === Qt.Key_Menu || (shift && event.key === Qt.Key_F10)) {
            event.accepted = true; return
        }
        if ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
            event.accepted = true; requestPaste(); return
        }
        if ((ctrl && (event.key === Qt.Key_X || event.key === Qt.Key_C || event.key === Qt.Key_Insert))
            || (shift && event.key === Qt.Key_Delete)) { event.accepted = true; return }
        if (ctrl && event.key === Qt.Key_A) { selectAll(); event.accepted = true; return }
        if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
            if (selectionStart === selectionEnd) {
                var pos = cursorPosition
                var start = event.key === Qt.Key_Backspace ? Math.max(0, pos - 1) : pos
                var end = event.key === Qt.Key_Delete ? Math.min(text.length, pos + 1) : pos
                // Do not split a UTF-16 surrogate pair.
                if (start > 0 && /[\uDC00-\uDFFF]/.test(text.charAt(start))) start--
                if (end < text.length && /[\uDC00-\uDFFF]/.test(text.charAt(end))) end++
                select(start, end)
            }
            replaceSelection(""); event.accepted = true; return
        }
        if ((altGr || !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
            && event.text.length && !/[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(event.text)) {
            replaceSelection(event.text); event.accepted = true
        }
    }
    // No primary-selection retrieval and no native context menu.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.RightButton
        onPressed: function(mouse) { mouse.accepted = true }
    }
    Controls.Button {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 54
        height: parent.height
        text: "Paste"
        focusPolicy: Qt.NoFocus
        enabled: field.enabled && !field.pastePending
        Accessible.name: "Paste into " + field.Accessible.name
        onClicked: field.requestPaste()
    }
    Process {
        id: pasteProcess
        command: ["python3", Qt.resolvedUrl("clipboard.py").toString().replace(/^file:\/\//, "")]
        stdout: StdioCollector { id: pasteResult }
        // Helper never prints payloads to stderr; do not log collector contents.
        onExited: function(code) {
            var snapshot = field.pasteSnapshot
            field.pasteSnapshot = null
            if (!snapshot || !field.activeFocus || !field.enabled || snapshot.epoch !== field.editEpoch) return
            try {
                var result = JSON.parse(pasteResult.text)
                if (code !== 0 || result.ok !== true || typeof result.text !== "string" || result.text.length > 4096) {
                    field.pasteRejected(); return
                }
                field.replaceSelection(result.text)
            } catch (error) { field.pasteRejected() }
        }
    }
    Component.onDestruction: { pasteSnapshot = null; pasteProcess.running = false }
}
