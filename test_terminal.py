"""Run the real picker in a PTY with synthetic history (no personal history)."""

import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import tempfile
import termios
import time
import unittest


SCRIPT = Path(__file__).resolve().parent / "reverse-history-bash.sh"
ANSI = re.compile(rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])")


class Picker:
    def __init__(self, rows=24, row=24, query="", reuse=False):
        self.tmp = tempfile.TemporaryDirectory(prefix="rhb-test-")
        self.home = Path(self.tmp.name)
        (self.home / ".bash_history").write_text(
            "".join(f"echo result-{i}\n" for i in range(1, 7))
        )
        self.result = self.home / "result"
        env = dict(os.environ, HOME=str(self.home), TERM="xterm-256color",
                   RHB_CACHE_DIR=str(self.home / "cache"),
                   RHB_RESULT_FILE=str(self.result), RHB_QUERY=query,
                   RHB_PROMPT="test$ ", RHB_PROMPT_EXPANDED="1",
                   RHB_REUSE_INITIAL_LINE=str(int(reuse)))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, 80, 0, 0))
        self.pid = os.fork()
        if self.pid == 0:
            os.close(master)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            for fd in range(3):
                os.dup2(slave, fd)
            if slave > 2:
                os.close(slave)
            os.execve("/bin/bash", ["bash", str(SCRIPT), "--print"], env)
        os.close(slave)
        self.fd = master
        self.buffer = b""
        self.read_until(b"\x1b[6n")
        os.write(self.fd, f"\x1b[{row};{7 + len(query)}R".encode())

    def read_until(self, marker):
        deadline = time.monotonic() + 5
        while marker not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise AssertionError(f"Picker timed out: {self.buffer!r}")
            self.buffer += os.read(self.fd, 65536)
        end = self.buffer.index(marker) + len(marker)
        result, self.buffer = self.buffer[:end], self.buffer[end:]
        return result

    def frame(self, key=None):
        if key:
            os.write(self.fd, key)
        return self.read_until(b"\x1b8")

    def finish(self, key):
        os.write(self.fd, key)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = None
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.01)
        raise AssertionError("Picker did not exit")

    def close(self):
        if self.pid is not None:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.fd)
        self.tmp.cleanup()


class TerminalTests(unittest.TestCase):
    def picker(self, **kwargs):
        picker = Picker(**kwargs)
        self.addCleanup(picker.close)
        return picker

    def test_bottom_row_shows_results_and_accepts_selection(self):
        picker = self.picker()
        frame = picker.frame()
        self.assertIn(b"echo result-6", ANSI.sub(b"", frame))
        self.assertIn(b"echo result-1", ANSI.sub(b"", frame))
        frame = picker.frame(b"\x1b[B")
        self.assertIn(b"> echo result-5", ANSI.sub(b"", frame))
        self.assertEqual(picker.finish(b"\r"), 0)
        self.assertEqual(picker.result.read_text(), "echo result-5")

    def test_near_bottom_also_shows_a_full_page(self):
        picker = self.picker(row=23, reuse=True)
        frame = ANSI.sub(b"", picker.frame())
        self.assertIn(b"echo result-6", frame)
        self.assertIn(b"echo result-1", frame)

    def test_middle_does_not_scroll_to_make_room(self):
        picker = self.picker(row=10)
        frame = picker.frame()
        self.assertIn(b"echo result-1", ANSI.sub(b"", frame))
        self.assertNotIn(b"\x1b[24;1H", frame)

    def test_short_terminal_keeps_selected_result_visible(self):
        picker = self.picker(rows=4, row=4)
        picker.frame()
        for _ in range(4):
            frame = picker.frame(b"\x1b[B")
        self.assertIn(b"> echo result-2", ANSI.sub(b"", frame))
        self.assertEqual(picker.finish(b"\r"), 0)
        self.assertEqual(picker.result.read_text(), "echo result-2")

    def test_cancel_after_scrolling_returns_query(self):
        picker = self.picker(query="result")
        picker.frame()
        self.assertEqual(picker.finish(b"\x03"), 130)
        self.assertEqual(picker.result.read_text(), "result")

    def test_single_row_terminal_can_exit(self):
        picker = self.picker(rows=1, row=1)
        picker.frame()
        self.assertEqual(picker.finish(b"\r"), 0)


if __name__ == "__main__":
    unittest.main()
