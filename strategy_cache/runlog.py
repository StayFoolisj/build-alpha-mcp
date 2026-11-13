"""Append-only JSONL run log for MCP tool calls.

One line per phase, so a killed or hung call is identifiable by a ``tool_call_start``
with no matching ``tool_call_finish``:

    {"ts":"...","event":"tool_call_start","run_id":"9f3c1a2b7e40","tool":"rerun_with_adjustments","tag":"...","args":{...}}
    {"ts":"...","event":"tool_call_finish","run_id":"9f3a...","tool":"...","tag":"...","status":"COMPLETED",
     "exit_code":0,"duration_ms":268413,"windows":["Build Alpha"],"stdout":"...","stderr":"","result":{...}}

Retention is the stdlib handler's job: rotate at midnight *or* at ``max_bytes``,
keeping ``backup_count`` files. Nothing else prunes.

Two deliberate rules:

* Big text fields are capped (``FIELD_CAP``) with an explicit ``*_truncated`` flag,
  so a pathological script dump cannot blow the log up.
* Read-only *successful* calls store a digest of their result instead of the rows
  (``compacted: true``) - nobody ever needs to recover a 50-row page from the log,
  and this is what keeps 'very frequent use' in the tens of MB. Action calls and
  every failure keep the payload in full, because those are the ones worth
  recovering.

``last_result(tag)`` is what makes a caller-side timeout harmless: the tool's work
is already journalled when it finishes, so the result can be fetched afterwards
instead of re-running the simulation.
"""
from __future__ import annotations

import json
import logging
import logging.handlers
import threading
import time
import uuid
from pathlib import Path

# Every cap here exists so that a payload's size can never decide a log line's size. A 256 KB
# field produced 2-3 KB finish lines and, on a bad day, one line large enough to be unreadable in a
# terminal and expensive to parse - while the full payload is already in the tool's reply.
FIELD_CAP = 4096        # any single string value
ARRAY_CAP = 8           # items kept from a list (the rest become a count)
KEY_CAP = 16384         # a value that is itself a nested object, serialised

LEVELS = {"debug": logging.DEBUG, "info": logging.INFO, "warn": logging.WARNING,
          "warning": logging.WARNING, "error": logging.ERROR}

#: Successes from these tools are journalled as a digest; everything else keeps
#: its payload verbatim (see the module docstring).
#: Tools that must never journal their own call: the two log readers (they would
#: shadow the run they are looking up) and the rerun tool (it journals explicitly,
#: because a run may be handed off to the background and finish later).
NO_JOURNAL = frozenset({"get_last_result", "recent_runs", "rerun_with_adjustments",
                         "capture_variance_test", "capture_mc_analysis",
                         "capture_mc_drawdown", "capture_eratio",
                         # a chunked read carries base64 in every reply
                         "buildalpha_read_capture"})

READ_ONLY_TOOLS = frozenset({
    "query_strategies", "list_strategies", "get_strategy", "list_portfolios",
    "cache_stats", "describe_metrics", "portfolio_changes", "buildalpha_status",
    "get_last_result", "recent_runs",
})

logger = logging.getLogger("strategy_cache.runlog")
_state = threading.local()


class TimeSizeRotatingFileHandler(logging.handlers.TimedRotatingFileHandler):
    """Rotate at midnight, or early once the file passes ``max_bytes``.

    ``TimedRotatingFileHandler`` alone cannot bound a burst; this adds the size
    trigger while keeping its date-suffixed backups and retention count.
    """

    def __init__(self, filename, *, when="midnight", backup_count=14, max_bytes=0,
                 encoding="utf-8", utc=True):
        super().__init__(filename, when=when, backupCount=backup_count,
                         encoding=encoding, utc=utc)
        self.max_bytes = max_bytes

    def shouldRollover(self, record) -> bool:  # type: ignore[override]
        if super().shouldRollover(record):
            return True
        if not self.max_bytes:
            return False
        if self.stream is None:  # pragma: no cover - opened lazily by the base class
            self.stream = self._open()
        if self.stream.tell() + len(self.format(record).encode(self.encoding or "utf-8")) >= self.max_bytes:
            self.rollover_at = self.computeRollover(int(time.time()))
            return True
        return False


def configure(path: str | Path, *, backup_count: int = 14, max_bytes: int = 32 * 1024 * 1024,
              level: int = logging.INFO, echo: bool = False) -> logging.Logger:
    """Point the run log at ``path``. Safe to call twice (handlers are replaced)."""
    for handler in list(logger.handlers):
        logger.removeHandler(handler)
        try:
            handler.close()
        except Exception:  # pragma: no cover - closing a dead stream
            pass
    import os
    # BA_LOG_LEVEL wins over the caller's default; either may be a name ("debug") or a number
    set_level(os.environ.get("BA_LOG_LEVEL") or level)
    level = get_level()
    logger.setLevel(level)
    logger.propagate = False
    # Something else may have disabled this logger (alembic's fileConfig used to disable
    # every existing logger when migrations ran in-process, which silently stopped the
    # run log). Configuring the log is exactly the moment to be sure it is enabled.
    logger.disabled = False
    if path:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        handler = TimeSizeRotatingFileHandler(
            target, when="midnight", backup_count=backup_count, max_bytes=max_bytes,
        )
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
        if echo:
            stream = logging.StreamHandler()
            stream.setFormatter(logging.Formatter("%(message)s"))
            logger.addHandler(stream)
        logger.info(json.dumps({"ts": _now(), "event": "log_open", "path": str(target),
                                "backup_count": backup_count, "max_bytes": max_bytes}))
    return logger


def _now() -> str:
    """UTC ISO-8601 with milliseconds: capture stages are 100-900 ms apart, so seconds collide."""
    now = time.time()
    return (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now))
            + f".{int(now * 1000) % 1000:03d}Z")


def _cap(value, key: str) -> tuple:
    """Return (value, extra-fields) applying FIELD_CAP to strings."""
    if not isinstance(value, str) or len(value.encode("utf-8")) <= FIELD_CAP:
        return value, {}
    return value[: FIELD_CAP], {f"{key}_truncated": True, f"{key}_bytes": len(value)}


def attach(**fields) -> None:
    """Hand extra fields (e.g. the raw script stdout) to the wrapper's log line."""
    _state.extra = {**(getattr(_state, "extra", None) or {}), **fields}


def _drain_extra() -> dict:
    extra = getattr(_state, "extra", None) or {}
    _state.extra = {}
    return extra


_level = logging.INFO


def set_level(name: str | int) -> int:
    """Set the minimum level a record needs to be written (debug keeps stage lines)."""
    global _level
    _level = LEVELS.get(str(name).lower(), logging.INFO) if isinstance(name, str) else int(name)
    return _level


def get_level() -> int:
    return _level


#: Anything that looks like a credential is replaced before it can reach the file. No tool takes
#: one today; this is what keeps that true when one does.
_SECRET_KEY = ("password", "passwd", "secret", "token", "apikey", "api_key", "authorization",
               "cookie", "credential", "clipboard")


def _scrub(key: str, value):
    low = key.lower()
    if any(word in low for word in _SECRET_KEY):
        return "***"
    if isinstance(value, str):
        return value
    return value


def _bound(key: str, value):
    """Cap a value, returning (value, extra-fields). Never raises."""
    try:
        if isinstance(value, str):
            if len(value.encode("utf-8")) <= FIELD_CAP:
                return value, {}
            return value[:FIELD_CAP], {f"{key}_truncated": True,
                                       f"{key}_bytes": len(value)}
        if isinstance(value, (list, tuple)):
            if len(value) <= ARRAY_CAP:
                return list(value), {}
            return list(value[:ARRAY_CAP]), {f"{key}_truncated": True, f"{key}_count": len(value)}
        if isinstance(value, dict):
            # bound the leaves, keep the shape: turning the whole object into a string makes the
            # log unqueryable, which is the opposite of the point
            out, extras = {}, {}
            for k, v in value.items():
                out[k], ex = _bound(k, _scrub(k, v))
                extras.update(ex)
            blob = json.dumps(out, default=str, ensure_ascii=False)
            if len(blob) <= KEY_CAP:
                return out, extras
            # still too big after bounding the leaves: keep a digest, never a raw string blob -
            # a truncated JSON string is unreadable *and* unparseable
            return ({"compacted": True, "keys": sorted(out)[:12], "bytes": len(blob)},
                    {**extras, f"{key}_truncated": True, f"{key}_bytes": len(blob)})
        return value, {}
    except Exception:  # pragma: no cover - a value that cannot be inspected is not worth failing for
        return str(value)[:KEY_CAP], {f"{key}_truncated": True}


def _emit(payload: dict, level: int = logging.INFO) -> None:
    """Write one line. Logging must never fail the tool that is being logged."""
    try:
        if level < _level:
            return
        logger.log(level, json.dumps(payload, default=str, ensure_ascii=False))
    except Exception:  # pragma: no cover - full disk, closed stream, unserialisable value
        pass


def record_stage(run_id: str, tool: str, stage: str, ms) -> None:
    """One line per step, at debug. A timeline is greppable and sortable; a nested array is not."""
    try:
        _emit({"ts": _now(), "lvl": "debug", "event": "stage", "run_id": run_id,
               "tool": tool, "stage": stage, "ms": int(ms)}, logging.DEBUG)
    except Exception:  # pragma: no cover
        pass


def record_start(tool: str, args: dict, *, tag: str | None = None) -> str:
    run_id = uuid.uuid4().hex[:12]
    clean = {k: _scrub(k, v) for k, v in (args or {}).items()}
    args_out, extra = _bound("args", clean)
    _emit({"ts": _now(), "lvl": "info", "event": "tool_call_start", "run_id": run_id,
           "tool": tool, "tag": tag, "args": args_out, **extra})
    return run_id


def _digest(result) -> dict:
    if isinstance(result, list):
        return {"compacted": True, "type": "list", "items": len(result)}
    if not isinstance(result, dict):
        return {"compacted": True, "type": type(result).__name__}
    rows = result.get("rows")
    return {
        "compacted": True,
        "keys": sorted(result)[:12],
        "bytes": len(json.dumps(result, default=str)),
        "total": result.get("total"),
        "rows": len(rows) if isinstance(rows, list) else None,
    }


def record_finish(run_id: str, tool: str, args: dict, *, tag: str | None, status: str,
                  exit_code: int | None = None, duration_ms: int = 0, result=None,
                  stdout: str = "", stderr: str = "", windows=None,
                  error: str | None = None) -> dict:
    extra = _drain_extra()
    stdout = extra.pop("stdout", stdout)
    stderr = extra.pop("stderr", stderr)
    windows = extra.pop("windows", windows)

    failed = status not in ("OK", "COMPLETED", "DRY_RUN", "SIZE_CAP")
    run_stages = []
    if isinstance(result, dict) and isinstance(result.get("stages"), list):
        run_stages = [s for s in result["stages"] if isinstance(s, dict)]
        # the timeline goes out as its own small lines (record_stage), not nested in here
    clean_args = {k: _scrub(k, v) for k, v in (args or {}).items()}
    args_out, aextra = _bound("args", clean_args)
    payload = {
        "ts": _now(), "lvl": "warn" if failed else "info",
        "event": "tool_call_finish", "run_id": run_id, "tool": tool,
        "tag": tag, "args": args_out, "status": status, "exit_code": exit_code,
        "ok": not failed, "duration_ms": int(duration_ms or 0), "windows": windows,
        **aextra,
    }
    payload["stdout"], t1 = _cap((stdout or "")[-KEY_CAP:], "stdout")
    payload["stderr"], t2 = _cap((stderr or "")[-KEY_CAP:], "stderr")
    payload.update(t1)
    payload.update(t2)
    if error:
        payload["error"], t3 = _cap(error, "error")
        payload.update(t3)

    keep_full = tool not in READ_ONLY_TOOLS or status not in ("OK", "DRY_RUN")
    body = result if keep_full else _digest(result)
    if isinstance(body, dict) and "stages" in body:
        body = {k: v for k, v in body.items() if k != "stages"}
    body_out, rextra = _bound("result", body)
    payload["result"] = body_out
    payload.update(rextra)
    # the stage the call reached is a top-level scalar: one grep answers "where did it stop"
    if isinstance(result, dict) and result.get("last_stage"):
        payload["last_stage"] = result["last_stage"]
    for entry in run_stages:
        record_stage(run_id, tool, entry.get("stage"), entry.get("ms"))
    payload.update(extra)

    _emit(payload, logging.WARNING if failed else logging.INFO)
    return payload


def _log_files(path: Path) -> list[Path]:
    base = path.name
    files = [p for p in path.parent.glob(base + "*") if p.is_file()]
    return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)


def _scan(path: Path, *, tag: str | None = None, tool: str | None = None,
          status: str | None = None, limit: int = 1, event: str = "tool_call_finish",
          dry_run: bool | None = None) -> list[dict]:
    """Newest-first scan across the current file and its rotated backups."""
    found: list[dict] = []
    for file in _log_files(path):
        try:
            with open(file, encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
        except OSError:
            continue
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("event") != event:
                continue
            if tag is not None and rec.get("tag") != tag:
                continue
            if tool is not None and rec.get("tool") != tool:
                continue
            if status is not None and rec.get("status") != status:
                continue
            if dry_run is not None and bool((rec.get("args") or {}).get("dry_run")) != dry_run:
                continue
            found.append(rec)
            if len(found) >= limit:
                return found
    return found


def load_run(run_id: str, *, path: str | Path | None = None) -> dict | None:
    """The finished record for one run id (any tool), or None.

    Used by the trades reader: the journal carries where the TSV is, and a run id is the
    only key that cannot be confused with an earlier run of the same tag.
    """
    target = Path(path) if path else _default_path()
    if not target:
        return None
    for file in _log_files(target):
        try:
            with open(file, encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line or run_id not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("run_id") == run_id and rec.get("event") == "tool_call_finish":
                return rec
    return None


def last_result(tag: str, *, path: str | Path | None = None,
                tool: str | None = "rerun_with_adjustments",
                include_dry_run: bool = False) -> dict:
    """Most recent journalled *run* for a tag, plus any run still in flight.

    Returns ``{"record": <newest finish or None>, "in_flight": <start with no
    finish or None>, "dry_run_record": <newest dry run or None>}``.

    ``include_dry_run=False`` (the default) prefers a real run: otherwise a caller
    that polls while the real run is still going would be handed the earlier dry
    run and mistake it for the result. ``in_flight`` exists for exactly that case -
    a start record with no matching finish means "wait", not "nothing happened".
    """
    target = Path(path) if path else _default_path()
    if not target:
        return {"record": None, "in_flight": None, "dry_run_record": None}

    real = _scan(target, tag=tag, tool=tool, limit=1, dry_run=False) if tool else \
        _scan(target, tag=tag, limit=1, dry_run=False)
    dry = _scan(target, tag=tag, tool=tool, limit=1, dry_run=True) if tool else \
        _scan(target, tag=tag, limit=1, dry_run=True)

    # a start whose run_id has no finish is still running
    starts = _scan(target, tag=tag, tool=tool, limit=20, event="tool_call_start")
    finished_ids = {r.get("run_id") for r in _scan(target, tag=tag, tool=tool, limit=20)}
    in_flight = next((s for s in starts if s.get("run_id") not in finished_ids), None)

    record = (real or [None])[0]
    dry_record = (dry or [None])[0]
    if record is None and include_dry_run:
        record = dry_record
    return {"record": record, "in_flight": in_flight, "dry_run_record": dry_record}


def recent(*, limit: int = 20, tool: str | None = None, status: str | None = None,
           tag: str | None = None, path: str | Path | None = None) -> list[dict]:
    target = Path(path) if path else _default_path()
    if not target:
        return []
    return _scan(target, tool=tool, status=status, tag=tag, limit=limit)


def _default_path() -> Path | None:
    for handler in logger.handlers:
        base = getattr(handler, "baseFilename", None)
        if base:
            return Path(base)
    return None
