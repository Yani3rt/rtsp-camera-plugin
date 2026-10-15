"""Exercise bounded reads using real isolated subprocesses, never desktop clipboard."""
import importlib.util
from pathlib import Path
import sys
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


class ClipboardTests(unittest.TestCase):
    def reader(self):
        path = Path(__file__).with_name('clipboard.py')
        self.assertTrue(path.exists(), 'isolated bounded clipboard helper is missing')
        spec = importlib.util.spec_from_file_location('camera_clipboard', path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_small_and_empty_real_provider(self):
        helper = self.reader()
        for data in (b'', 'hello café'.encode(), b'x' * 4096):
            self.assertEqual(helper.read_bounded([sys.executable, '-c', f'import os; os.write(1, {data!r})']), data.decode())

    def test_rejected_providers(self):
        helper = self.reader()
        for data in (b'x' * 4097, b'\xff', b'a\nb', b'a\r', b'a\x00', b'a\t', '\u2028'.encode()):
            with self.subTest(size=len(data)):
                with self.assertRaises(helper.ClipboardError):
                    helper.read_bounded([sys.executable, '-c', f'import os; os.write(1, {data!r})'])

    def test_absolute_deadline_including_exit_and_trickle(self):
        helper = self.reader()
        for source in ('import time; time.sleep(30)',
                       'import os,time; os.close(1); time.sleep(30)',
                       'import os,time\nfor i in range(100):\n os.write(1,b"a"); time.sleep(.1)'):
            start = time.monotonic()
            with self.assertRaises(helper.ClipboardError):
                helper.read_bounded([sys.executable, '-c', source])
            self.assertLess(time.monotonic() - start, 1.5)
    def test_stderr_discard_and_failed_exit(self):
        helper = self.reader()
        self.assertEqual(helper.read_bounded([sys.executable, '-c',
            'import os; os.write(2,b"x"*1000000); os.write(1,b"ok")']), 'ok')
        with self.assertRaises(helper.ClipboardError):
            helper.read_bounded([sys.executable, '-c', 'import sys; print("secret"); sys.exit(1)'])

    def test_cancel_and_timeout_kill_provider_descendants(self):
        helper_path = Path(__file__).with_name('clipboard.py')
        with tempfile.TemporaryDirectory() as directory:
            for cancellation in (False, True):
                pidfile = Path(directory) / 'pid'
                pidfile.unlink(missing_ok=True)
                provider = ('import os,time; from pathlib import Path; child=os.fork(); '
                            f'Path({str(pidfile)!r}).write_text(str(child)) if child else None; '
                            'time.sleep(30)')
                wrapper = ('import importlib.util; '
                    f's=importlib.util.spec_from_file_location("bounded",{str(helper_path)!r}); '
                    'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                    f'm.read_bounded({[sys.executable, "-c", provider]!r})')
                process = subprocess.Popen([sys.executable, '-c', wrapper],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    deadline = time.monotonic() + 2
                    while not pidfile.exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue(pidfile.exists())
                    child = int(pidfile.read_text())
                    if cancellation:
                        process.send_signal(signal.SIGTERM)
                    process.wait(timeout=2)
                    self.assertNotEqual(process.returncode, 0)
                    stat = Path(f'/proc/{child}/stat')
                    deadline = time.monotonic() + 1
                    while stat.exists() and stat.read_text().split()[2] != 'Z' and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z', 'provider descendant still alive')
                finally:
                    if process.poll() is None:
                        process.kill(); process.wait()

    def test_offscreen_native_clipboard_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory) / 'probe')
            root = Path(directory)
            # Keep both input layers byte-for-byte production source. Only
            # styling dependencies and process IO are inert isolated stubs.
            shutil.copy2(Path(__file__).with_name('SafeTextField.qml'), root)
            ui = root / 'qs/Ui'
            commons = root / 'qs/Commons'
            io = root / 'Quickshell/Io'
            for path in (ui, commons, io):
                path.mkdir(parents=True)
            shutil.copy2('/usr/share/omarchy/shell/Ui/TextField.qml', ui)
            (ui / 'qmldir').write_text('module qs.Ui\nTextField 1.0 TextField.qml\n')
            (ui / 'BorderSurface.qml').write_text('import QtQuick\nRectangle { property var borderSpec; }')
            (commons / 'qmldir').write_text('module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\nsingleton Border 1.0 Border.qml\n')
            (commons / 'Color.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property color foreground: "white"; property color accent: "blue" }')
            (commons / 'Style.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property var spacing: ({controlPaddingX: 6, inputPaddingY: 6}); property var font: ({family: "sans", body: 14}); property int cornerRadius: 4; function selectionFillFor(f,a) { return a } function controlFill(f,h,c,a) { return "black" } }')
            (commons / 'Border.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { function controlSpec(f,c,a) { return ({}) } function left(s) { return 0 } function right(s) { return 0 } function top(s) { return 0 } function bottom(s) { return 0 } }')
            (io / 'qmldir').write_text('module Quickshell.Io\nProcess 1.0 Process.qml\nStdioCollector 1.0 StdioCollector.qml\n')
            (io / 'Process.qml').write_text('import QtQuick\nQtObject { default property list<QtObject> data; property var command; property bool running: false; property QtObject stdout; signal exited(int code); }')
            (io / 'StdioCollector.qml').write_text('import QtQuick\nQtObject { property string text: "" }')
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
                                                        'Qt6Quick', 'Qt6Gui', 'Qt6Qml', 'Qt6Test'], text=True))
            subprocess.run(['c++', '-std=c++17', '-fPIC', str(Path(__file__).parent / 'tests/clipboard_probe.cpp'),
                            '-o', binary] + flags, check=True, capture_output=True, text=True)
            result = subprocess.run([binary, str(root)], env=dict(os.environ, QT_QPA_PLATFORM='offscreen',
                QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic'), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('production SafeTextField normal/password construction: zero clipboard retrievals', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
