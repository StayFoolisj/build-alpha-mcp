"""Background jobs for long tool calls.

A real rerun takes 52-75 s while a caller may give up at 60 s: waiting inside the
request makes the timeout arithmetic rather than a fault. So the work runs in a
thread, the tool waits a bounded time for it, and if it is not done the tool
returns ``{"status": "RUNNING", "run_id": ...}`` - the caller then fetches the
outcome with ``get_last_result(tag)`` instead of re-running the simulation.

Only one BuildAlpha job may run at a time: two would fight over the same UI.
``start()`` raises :class:`Busy` with the active job so the caller can wait for
that one rather than queueing a second UI automation.
"""
from __future__ import annotations

import threading
import time
import uuid
from typing import Any, Callable

_lock = threading.Lock()
_active: "Job | None" = None
_jobs: dict[str, "Job"] = {}
KEEP = 50


class Busy(RuntimeError):
    def __init__(self, job: "Job"):
        super().__init__(f"busy: {job.name} run {job.id} started at {job.started_at}")
        self.job = job


class Job:
    def __init__(self, name: str, fn: Callable[[], Any]):
        self.id = uuid.uuid4().hex[:12]
        self.name = name
        self.started_at = time.time()
        self.finished_at: float | None = None
        self.result: Any = None
        self.error: str | None = None
        self._done = threading.Event()
        self._fn = fn

    # -- state ------------------------------------------------------------
    @property
    def running(self) -> bool:
        return not self._done.is_set()

    @property
    def duration_ms(self) -> float:
        end = self.finished_at or time.time()
        return round((end - self.started_at) * 1000, 1)

    def state(self) -> dict:
        out = {
            "run_id": self.id,
            "tool": self.name,
            "status": "RUNNING" if self.running else ("ERROR" if self.error else "DONE"),
            "duration_ms": self.duration_ms,
        }
        if self.result is not None:
            out["result"] = self.result
        if self.error:
            out["error"] = self.error
        return out

    def wait(self, timeout: float | None) -> bool:
        """True when finished within ``timeout`` seconds (None waits forever)."""
        return self._done.wait(timeout)

    def _run(self) -> None:
        global _active
        try:
            self.result = self._fn()
        except BaseException as exc:  # noqa: BLE001 - recorded, then surfaced by state()
            self.error = f"{type(exc).__name__}: {exc}"
        finally:
            self.finished_at = time.time()
            self._done.set()
            with _lock:
                if _active is self:
                    _active = None


def start(name: str, fn: Callable[[], Any]) -> Job:
    """Start ``fn`` in the background. Raises :class:`Busy` if one is already running."""
    global _active
    with _lock:
        if _active is not None and _active.running:
            raise Busy(_active)
        job = Job(name, fn)
        _active = job
        _jobs[job.id] = job
        while len(_jobs) > KEEP:
            for old in sorted(_jobs.values(), key=lambda j: j.started_at):
                if not old.running:
                    _jobs.pop(old.id, None)
                    break
            else:
                break
    threading.Thread(target=job._run, name=f"job-{job.id}", daemon=True).start()
    return job


def get(run_id: str) -> Job | None:
    return _jobs.get(run_id)


def active() -> Job | None:
    job = _active
    return job if job is not None and job.running else None
