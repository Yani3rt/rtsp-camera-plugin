// Offscreen only: never touch the live Wayland clipboard.
#include <QGuiApplication>
#include <QClipboard>
#include <QMimeData>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQuickItem>
#include <QQuickWindow>
#include <QInputMethodEvent>
#include <QDropEvent>
#include <QTest>
#include <QDir>

#include <iostream>

class CountingMime : public QMimeData {
public:
    mutable int reads = 0;
    QStringList formats() const override { return {"text/plain"}; }
protected:
    QVariant retrieveData(const QString &, QMetaType) const override {
        ++reads;
        return QString("sentinel");
    }
};
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (argc != 2 || app.platformName() != "offscreen") return 9;
    // Install before engine/component creation, not after the input has already
    // completed. This covers inherited bindings and deferred menu construction.
    auto *mime = new CountingMime;
    app.clipboard()->setMimeData(mime);
    QQmlEngine engine;
    engine.addImportPath(argv[1]);
    const auto base = QUrl::fromLocalFile(QDir(argv[1]).filePath("probe.qml"));
    QQuickWindow window;
    window.resize(300, 80);
    window.show();
    for (bool password : {false, true}) {
        QQmlComponent component(&engine);
        component.setData(QByteArray("import QtQuick; import QtQuick.Controls as Controls; import \".\"; SafeTextField { width: 280; height: 50; text: 'local'; password: ")
            + (password ? "true" : "false")
            + "; readonly property bool noNativeMenu: Controls.ContextMenu.menu === null }", base);
        auto *field = qobject_cast<QQuickItem *>(component.create());
        if (!field) { std::cerr << component.errorString().toStdString(); return 10; }
        if (mime->reads || !field->property("readOnly").toBool()) return 16;
        field->setParentItem(window.contentItem());
        field->forceActiveFocus();
        app.processEvents();
        if (field->property("canPaste").toBool() || mime->reads) return 11;
        if (password && field->property("displayText").toString() == "local") return 17;
        QMetaObject::invokeMethod(field, "paste");
        QTest::keyClick(&window, Qt::Key_V, Qt::ControlModifier);
        QTest::keyClick(&window, Qt::Key_Insert, Qt::ShiftModifier);
        QTest::mouseClick(&window, Qt::MiddleButton, Qt::NoModifier, QPoint(5,5));
        QTest::mouseClick(&window, Qt::RightButton, Qt::NoModifier, QPoint(5,5));
        QTest::keyClick(&window, Qt::Key_Menu);
        QTest::keyClick(&window, Qt::Key_F10, Qt::ShiftModifier);
        if (!field->property("noNativeMenu").toBool()) return 18;
        // Normal platform IME delivery is disabled by readOnly. A forged direct
        // input-method event bypasses Qt's delivery gate, not a provider route.
        if (field->inputMethodQuery(Qt::ImEnabled).toBool()
            || field->flags().testFlag(QQuickItem::ItemAcceptsInputMethod)) return 15;
        CountingMime dropMime;
        QDropEvent drop(QPointF(5,5), Qt::CopyAction, &dropMime, Qt::LeftButton, Qt::NoModifier);
        QCoreApplication::sendEvent(field, &drop);
        if (dropMime.reads) return 14;
        app.processEvents();
        if (mime->reads || field->property("text").toString() != "local"
            || !field->property("readOnly").toBool()) return 12;
        delete field;
        app.processEvents();
        if (mime->reads) return 19;
    }
    // Separate isolated positive control; never toggle a production field.
    QQmlComponent positive(&engine);
    positive.setData("import QtQuick; TextInput { readOnly: false; property bool eagerCanPaste: canPaste }", base);
    auto *editable = positive.create();
    if (!editable) return 20;
    // The eager binding must have been counted during construction, before
    // this code asks for any property (the old late-install probe missed it).
    if (mime->reads == 0) return 21;
    bool canPaste = editable->property("eagerCanPaste").toBool();
    if (!canPaste || mime->reads == 0) return 13;
    std::cout << "PASS: production SafeTextField normal/password construction: zero clipboard retrievals; native/context/IME/drop/destruction routes zero; isolated editable positive control reads=" << mime->reads << std::endl;
    delete editable;
    return 0;
}
