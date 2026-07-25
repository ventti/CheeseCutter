"""Persistent ccdriver protocol used by ordered headless usage tests."""

from __future__ import annotations

import os
import select
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "ccdriver"

# Multiply every driver timeout by this. An instrumented (ASan) ccdriver runs
# several times slower than the release binary, so the sanitizer job sets e.g.
# CCDRIVER_TIMEOUT_SCALE=8 to avoid spurious TimeoutErrors; normal runs use 1.0.
TIMEOUT_SCALE = float(os.environ.get("CCDRIVER_TIMEOUT_SCALE", "1"))


class CCDriverSession:
    """One stateful editor process with flush-delimited command checkpoints."""

    def __init__(self, *startup_commands: str, timeout: float = 10.0) -> None:
        env = os.environ.copy()
        env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        self.timeout = timeout * TIMEOUT_SCALE
        self._counter = 0
        self._buffer = bytearray()
        self.process = subprocess.Popen(
            [str(DRIVER), *startup_commands, "serve"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self.startup_output = self._read_until(
            lambda line: line.startswith("serve: ready"), self.timeout
        )

    def _readline(self, deadline: float) -> str:
        assert self.process.stdout is not None
        while True:
            newline = self._buffer.find(b"\n")
            if newline >= 0:
                raw = bytes(self._buffer[:newline])
                del self._buffer[: newline + 1]
                return raw.decode("utf-8", errors="replace")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for ccdriver output")
            ready, _, _ = select.select([self.process.stdout.fileno()], [], [], remaining)
            if not ready:
                raise TimeoutError("timed out waiting for ccdriver output")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError(
                    f"ccdriver exited {self.process.poll()} before its checkpoint"
                )
            self._buffer.extend(chunk)

    def _read_until(self, predicate, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        lines: list[str] = []
        while True:
            line = self._readline(deadline)
            lines.append(line)
            if predicate(line):
                return "\n".join(lines) + "\n"

    def run(self, command: str, *, timeout: float | None = None) -> str:
        """Run one command and return all output through its ordered marker."""
        if self.process.poll() is not None:
            raise RuntimeError(f"ccdriver already exited {self.process.returncode}")
        self._counter += 1
        marker = f"session-{self._counter:04d}"
        assert self.process.stdin is not None
        self.process.stdin.write(f"{command}\ncheckpoint:{marker}\n".encode())
        self.process.stdin.flush()
        expected = f"checkpoint: {marker}"
        deadline = timeout * TIMEOUT_SCALE if timeout is not None else self.timeout
        return self._read_until(lambda line: line == expected, deadline)

    def close(self) -> None:
        wait = 3 * TIMEOUT_SCALE
        if self.process.poll() is None:
            assert self.process.stdin is not None
            try:
                self.process.stdin.write(b"quit\n")
                self.process.stdin.flush()
                self.process.wait(timeout=wait)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                self.process.wait(timeout=wait)
        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()

    def __enter__(self) -> "CCDriverSession":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()
