"""Bounded execution supervision and live, structured activity relay."""
import json
import math
import sys
import time


class Supervision:
    def __init__(self, timeout, environment, monotonic=time.monotonic, emit=None):
        self.clock = monotonic
        self.allowance = float(timeout)
        if not math.isfinite(self.allowance) or self.allowance <= 0:
            raise ValueError("execution timeout must be positive and finite")
        self.accounted = monotonic()
        self.deadline = self.accounted + self.allowance
        self.preparations = {}
        self.seen_preparations = set()
        self.seen_waits = set()
        self.wait = None
        self.progress = {}
        self.attempt = environment.get("MN_WORKFLOW_ATTEMPT_ID")
        self.pending = bytearray()
        self.emit = emit or self._emit

    @staticmethod
    def _emit(line):
        sys.stdout.buffer.write(line + b"\n")
        sys.stdout.buffer.flush()

    def account(self):
        now = self.clock()
        if self.preparations:
            until = min(now, min(self.preparations.values()))
            self.deadline += max(0, until - self.accounted)
        self.accounted = now
        return now

    def expired(self):
        now = self.account()
        return (any(deadline <= now for deadline in self.preparations.values())
                or now >= max(self.deadline, self.wait or self.deadline))

    def feed(self, data):
        # Relay protocol records only; normal stdout remains a bounded artifact.
        self.pending.extend(data)
        while b"\n" in self.pending:
            line, _, rest = self.pending.partition(b"\n")
            self.pending = bytearray(rest)
            if len(line) <= 16384:
                self.line(bytes(line).rstrip(b"\r"))
        if len(self.pending) > 16384:
            self.pending.clear()

    def line(self, line):
        prefix = next((p for p in (b"__MN_EVENT__", b"__MN_AGENT_BEACON__") if line.startswith(p)), None)
        if prefix is None:
            return
        try:
            record = json.loads(line[len(prefix):])
            if not isinstance(record, dict):
                return
            self.observe(record if prefix == b"__MN_EVENT__" else {"type": "agent_beacon", "payload": record})
        except (ValueError, TypeError, OverflowError):
            return
        self.emit(line)

    def observe(self, record):
        now = self.account()
        payload = record.get("payload")
        if not isinstance(payload, dict):
            return
        if payload.get("attempt_id") not in (None, self.attempt):
            return
        kind = record.get("type")
        identity = payload.get("preparation_id")
        if kind == "runtime_preparation_started":
            timeout = payload.get("timeout_ms")
            if (payload.get("attempt_id") == self.attempt and self.attempt
                    and isinstance(identity, str) and 0 < len(identity) <= 128
                    and payload.get("kind") in {"model", "dependencies", "service"}
                    and type(timeout) is int and 0 < timeout <= 86400000
                    and identity not in self.seen_preparations and len(self.seen_preparations) < 1024
                    and not self.expired()):
                self.preparations[identity] = now + timeout / 1000
                self.seen_preparations.add(identity)
        elif kind == "runtime_preparation_finished":
            if (payload.get("attempt_id") == self.attempt and identity in self.preparations
                    and self.preparations[identity] > now):
                self.preparations.pop(identity)
        elif kind == "agent_beacon" and payload.get("source") == "agent":
            sequence, pid = payload.get("progress_sequence"), payload.get("pid")
            if type(sequence) is not int or sequence < 0 or type(pid) is not int or pid <= 0:
                return
            if sequence <= self.progress.get(pid, -1):
                return
            if len(self.progress) >= 1024 and pid not in self.progress:
                return
            self.progress[pid] = sequence
            wait, timeout = payload.get("wait_id"), payload.get("wait_timeout_ms")
            if (isinstance(wait, str) and 0 < len(wait) <= 128
                    and type(timeout) is int and 0 < timeout <= 86400000):
                if wait not in self.seen_waits and len(self.seen_waits) < 1024:
                    self.seen_waits.add(wait)
                    self.wait = now + timeout / 1000 + self.allowance
            else:
                self.wait = None
                self.deadline = now + self.allowance


def execute_command(spec):
    """Drain both pipes continuously, relay activity, and own process cleanup."""
    import os
    import selectors
    import signal
    import subprocess

    environment = {**os.environ, **spec.get("environment", {})}
    supervision = Supervision(spec.get("timeout_seconds", 600), environment)
    command = spec["command"]
    process = subprocess.Popen(command, cwd=spec["workdir"], env=environment,
        shell=isinstance(command, str), start_new_session=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limit = spec.get("max_result_bytes", 1000000)
    killed = False
    try:
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            selector.register(stream, selectors.EVENT_READ, name)
        # A child can close both pipes and keep running. Continue supervising
        # until the process actually exits, rather than blocking in wait().
        while selector.get_map() or process.poll() is None:
            if supervision.expired() and not killed:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                killed = True
            for key, _ in selector.select(timeout=0.1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                else:
                    if key.data == "stdout":
                        supervision.feed(data)
                    buffers[key.data].extend(data)
                    del buffers[key.data][:-limit]
        code = process.wait()
        if killed and code == 0:
            code = 124
    finally:
        selector.close()
        for stream in (process.stdout, process.stderr):
            stream.close()
        # Also retire descendants which inherited a pipe after their parent
        # exited, and commands whose transport was cancelled mid-collection.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    stdout = buffers["stdout"].decode("utf-8", errors="replace")
    stdout = "\n".join(line for line in stdout.splitlines()
                        if not line.startswith(("__MN_EVENT__", "__MN_AGENT_BEACON__")))
    return {"exit_code": code, "stdout": stdout,
            "stderr": buffers["stderr"].decode("utf-8", errors="replace")}


if __name__ == "__main__":
    from pathlib import Path
    spec = json.load(sys.stdin)
    result = execute_command(spec)
    Path(spec["stdout_path"]).write_text(result["stdout"])
    Path(spec["stderr_path"]).write_text(result["stderr"])
    code = result["exit_code"]
    sys.exit(code if code >= 0 else 128 - code)
