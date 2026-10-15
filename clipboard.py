"""One-shot Wayland clipboard reader. No clipboard payload reaches Qt unbounded.

Production command is fixed. read_bounded accepts argv only for isolated unit
providers, not configuration or environment overrides. No newline stripping:
all line breaks/control characters are rejected, including terminal newlines.
"""
import json
import os
import selectors
import signal
import subprocess
import time

MAX_BYTES = 4096
TIMEOUT = 1.0


class ClipboardError(Exception):
    """A generic failure; never contains clipboard text."""


def read_bounded(command):
    deadline = time.monotonic() + TIMEOUT
    process = None
    selector = selectors.DefaultSelector()
    previous = {}
    cancelled = False

    def cancel(signum, frame):
        # Do not throw across Popen: a signal between fork and return must not
        # lose the child's process-group identity. The absolute deadline still
        # bounds an interrupted read/wait to one second.
        nonlocal cancelled
        cancelled = True

    try:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous[sig] = signal.signal(sig, cancel)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        assert process.stdout is not None
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        data = bytearray()
        eof = False
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or cancelled:
                raise ClipboardError()
            if eof:
                try:
                    code = process.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    raise ClipboardError() from None
                if code != 0:
                    raise ClipboardError()
                break
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, min(1024, MAX_BYTES + 1 - len(data)))
                if not chunk:
                    eof = True
                    break
                data.extend(chunk)
                if len(data) > MAX_BYTES:
                    raise ClipboardError()
        if time.monotonic() >= deadline or cancelled:
            raise ClipboardError()
        try:
            text = data.decode('utf-8', errors='strict')
        except UnicodeError:
            raise ClipboardError() from None
        if any(ord(c) < 32 or 127 <= ord(c) <= 159 or c in '\u2028\u2029' for c in text):
            raise ClipboardError()
        if time.monotonic() >= deadline or cancelled:
            raise ClipboardError()
        return text
    except (OSError, ValueError):
        raise ClipboardError() from None
    finally:
        # Also kill descendants after a successful provider exit; a malicious
        # provider must not leave an inherited pipe or background child alive.
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if process.stdout is not None:
                process.stdout.close()
        selector.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    try:
        text = read_bounded(['/usr/bin/wl-paste', '--no-newline', '--type', 'text/plain'])
        # ASCII JSON is at most 6*4096 bytes plus this fixed envelope.
        print(json.dumps({'ok': True, 'text': text}, ensure_ascii=True))
        return 0
    except ClipboardError:
        print('{"ok":false}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
