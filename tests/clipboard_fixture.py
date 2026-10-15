"""Test-copy helper ONLY. Production never imports this fixture."""
import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('bounded', Path(__file__).with_name('bounded_original.py'))
assert spec is not None and spec.loader is not None
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
mode = json.loads(Path(os.environ['CAMERA_TEST_CLIPBOARD_FIXTURE']).read_text())['mode']
sources = {
    'small': 'import os; os.write(1,"café".encode())',
    'delay': 'import os,time; time.sleep(.3); os.write(1,b"late")',
    'oversize': 'import os; os.write(1,b"x"*4097)',
    'invalid': 'import os; os.write(1,b"\\xff")',
    'multiline': 'import os; os.write(1,b"a\\nb")',
    'timeout': 'import time; time.sleep(30)',
}
try:
    text = helper.read_bounded([sys.executable, '-c', sources[mode]])
    print(json.dumps({'ok': True, 'text': text}))
except helper.ClipboardError:
    print('{"ok":false}')
    raise SystemExit(1)
