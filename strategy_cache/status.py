"""BuildAlpha status snapshots.

BuildAlpha is a GUI app: the only way to see whether a simulation is running is
UI Automation (``buildalpha_status.ps1``). That work stays out of the MCP
server, which must remain read-only and GUI-free. So the pipeline is:

    python -m strategy_cache.status capture     # runs the PS script, writes JSON
    (MCP tool `buildalpha_status`)              # reads the JSON, never captures

This module uses the standard library plus subprocess only - no ``computer``,
no ``pyautogui``, no database.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "buildalpha_status.ps1"
DEFAULT_NAME = "buildalpha_status.json"

#: a snapshot older than this is flagged ``stale`` (a live capture is ~1 s)
STALE_AFTER_SECONDS = 300

#: default subprocess timeout for a live capture
DEFAULT_TIMEOUT = 30

#: per-run observation history, so an end time can be observed after the fact
MAX_HISTORY_ENTRIES = 2000
_HISTORY_FIELDS = ("captured_at", "state", "active_job", "job_started", "results_total")

#: one UI Automation reader at a time, even with several clients connected
_CAPTURE_LOCK = threading.Lock()


class StatusError(RuntimeError):
    """Missing snapshot, failed capture, or unparsable output."""


def snapshot_path(db_path: Path | None = None, override: str | None = None) -> Path:
    """Where the snapshot lives: --status / BA_STATUS_FILE, else beside the database."""
    raw = override or os.environ.get("BA_STATUS_FILE")
    if raw:
        path = Path(raw).expanduser()
        if not path.is_absolute():
            raise StatusError(f"status snapshot path must be absolute: {raw!r}")
        return path.resolve()
    return ((db_path.parent if db_path else ROOT) / DEFAULT_NAME).resolve()


def _parse(stdout: str) -> dict:
    """Pull the JSON object out of capture output (PowerShell may print noise)."""
    text = stdout.strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise StatusError(f"no JSON object in capture output: {text[:200]!r}")
    try:
        payload = json.loads(text[start : end + 1])
    except ValueError as exc:
        raise StatusError(f"cannot parse capture output: {exc}") from exc
    if not isinstance(payload, dict):
        raise StatusError("capture output is not a JSON object")
    return payload


def capture(out: Path, log_path: str | None = None, timeout: int = DEFAULT_TIMEOUT) -> dict:
    """Run the UI-Automation status script and write the snapshot atomically."""
    if not SCRIPT.is_file():
        raise StatusError(f"status script not found: {SCRIPT}")
    command = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(SCRIPT), "-Json",
    ]
    if log_path:
        command += ["-LogPath", log_path]
    with _CAPTURE_LOCK:
        try:
            proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise StatusError(f"capture failed: {exc}") from exc
        if proc.returncode != 0:
            raise StatusError(f"capture failed ({proc.returncode}): {proc.stderr.strip()[:400]}")

    payload = _parse(proc.stdout)
    payload["captured_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    payload.setdefault("source", "buildalpha_status.ps1")

    out = out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(out.parent), prefix=".status-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, out)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return payload


def _annotate(
    payload: dict, path: Path, mode: str, history: list[dict] | None = None
) -> dict:
    """Add ``age_seconds``, ``stale``, ``mode``, ``job`` and ``snapshot``."""
    now = datetime.now(timezone.utc)
    age: int | None = None
    captured = payload.get("captured_at")
    if isinstance(captured, str):
        try:
            moment = datetime.fromisoformat(captured.replace("Z", "+00:00"))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=timezone.utc)
            age = int((now - moment).total_seconds())
        except ValueError:
            age = None
    payload["age_seconds"] = age
    payload["stale"] = True if age is None else age > STALE_AFTER_SECONDS
    payload["mode"] = mode
    payload["snapshot"] = str(path)
    payload["job"] = _job_block(payload, now, history or [])
    return payload


# --------------------------------------------------------------------- history
def history_path(snapshot: Path) -> Path:
    snapshot = snapshot.resolve()
    return snapshot.with_name(snapshot.stem + ".history.jsonl")


def _load_history(snapshot: Path) -> list[dict]:
    path = history_path(snapshot)
    if not path.is_file():
        return []
    entries: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries[-MAX_HISTORY_ENTRIES:]


def _append_history(snapshot: Path, record: dict) -> list[dict]:
    """Record this observation (one line per capture) and return the recent window."""
    entries = _load_history(snapshot)
    entry = {field: record.get(field) for field in _HISTORY_FIELDS}
    if entries and entries[-1].get("captured_at") == entry.get("captured_at"):
        return entries
    entries = (entries + [entry])[-MAX_HISTORY_ENTRIES:]
    path = history_path(snapshot)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(item) + "\n" for item in entries), encoding="utf-8")
    os.replace(tmp, path)
    return entries


# ----------------------------------------------------------------- job summary
def _parse_local(value) -> datetime | None:
    """BuildAlpha log timestamps are local wall-clock, e.g. '2026-10-18 13:30:31'."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        moment = datetime.strptime(value.strip(), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return moment.astimezone()


def _parse_utc(value) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def humanize(seconds: float) -> str:
    """Compact duration: 45s, 37m, 4h 32m, 2d 3h."""
    total = int(max(0, seconds))
    if total < 60:
        return f"{total}s"
    minutes = total // 60
    if minutes < 60:
        return f"{minutes}m"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours}h {minutes:02d}m" if minutes else f"{hours}h"
    days, hours = divmod(hours, 24)
    return f"{days}d {hours}h" if hours else f"{days}d"


def _iso_local(moment: datetime | None) -> str | None:
    return moment.astimezone().isoformat(timespec="seconds") if moment else None


def _job_block(record: dict, now: datetime, history: list[dict]) -> dict:
    """When did the job start/end, how long did it run, and how do we know?"""
    started = _parse_local(record.get("job_started"))
    started_key = record.get("job_started")
    state = record.get("state") or "idle"
    running = state == "running"

    entries = [e for e in history if started_key and e.get("job_started") == started_key]
    runs = [t for t in (_parse_utc(e.get("captured_at")) for e in entries if e.get("active_job")) if t]
    idles = [t for t in (_parse_utc(e.get("captured_at")) for e in entries if not e.get("active_job")) if t]

    ended: datetime | None = None
    source = "none"
    window: tuple[datetime, datetime] | None = None
    if not running:
        marker = _parse_local(record.get("job_stop_marker"))
        if marker and (started is None or marker >= started):
            ended, source = marker, "log"          # exact: BuildAlpha logged the stop
        elif runs:
            last_run = max(runs)
            later = [t for t in idles if t > last_run]
            ended = min(later) if later else last_run
            source = "observed"
            window = (last_run, min(later) if later else now)
        elif idles:
            # only an upper bound: the job was already finished when first seen
            ended = min(idles)
            source = "before" if len(entries) > 1 else "single"

    duration_seconds: int | None = None
    max_duration_seconds: int | None = None
    if started is not None:
        if running:
            duration_seconds = int((now - started).total_seconds())
        elif source in ("log", "observed") and ended is not None:
            duration_seconds = int((ended - started).total_seconds())
        elif ended is not None:                    # before | single: an upper bound
            max_duration_seconds = int((ended - started).total_seconds())

    ago = int((now - ended).total_seconds()) if ended else None
    if running:
        summary = f"running for {humanize(duration_seconds)}" if duration_seconds is not None else "running"
    elif source == "log":
        summary = f"completed {humanize(ago)} ago"
    elif source == "observed" and window and window[0] != window[1]:
        summary = (
            f"completed {humanize(ago)} ago "
            f"(between {window[0].astimezone():%H:%M} and {window[1].astimezone():%H:%M})"
        )
    elif source == "observed":
        summary = f"completed {humanize(ago)} ago"
    elif source == "before":
        summary = f"completed before {ended.astimezone():%H:%M} (end not logged)"
    elif source == "single":
        summary = f"not running at {ended.astimezone():%H:%M} (run end not recorded)"
    else:
        summary = "not running (no start/end recorded)"

    return {
        "state": "running" if running else ("completed" if ended else "idle"),
        "started": _iso_local(started),
        "ended": _iso_local(ended),
        "ended_source": source,          # log | observed | before | single | none
        "seen_between": [_iso_local(t) for t in window] if window else None,
        "duration_seconds": duration_seconds,
        "duration": humanize(duration_seconds) if duration_seconds is not None else None,
        "max_duration_seconds": max_duration_seconds,
        "max_duration": humanize(max_duration_seconds) if max_duration_seconds is not None else None,
        "summary": summary,
    }


def read(path: Path) -> dict:
    """Load the last snapshot (no capture) and annotate it."""
    path = path.resolve()
    if not path.is_file():
        raise StatusError(
            f"no status snapshot at {path}; capture one with "
            f"'python -m strategy_cache.status capture'"
        )
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise StatusError(f"status snapshot {path} is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise StatusError(f"status snapshot {path} is not a JSON object")
    return _annotate(payload, path, "cached", _load_history(path))


def refresh(path: Path, timeout: int = DEFAULT_TIMEOUT, capture_fn=None) -> dict:
    """Capture now, persist snapshot + history, and return the annotated result."""
    payload = (capture_fn or capture)(path, timeout=timeout)
    history = _append_history(path, payload)
    return _annotate(payload, path.resolve(), "live", history)


def latest(
    path: Path, *, live: bool = True, timeout: int = DEFAULT_TIMEOUT, capture_fn=None
) -> dict:
    """Live status by default, falling back to the last snapshot if capture fails.

    With ``live=False`` the snapshot is read from disk and no UI Automation runs.
    A fallback is marked ``mode='cached'`` with ``capture_error`` explaining why.
    """
    if not live:
        return read(path)
    try:
        return refresh(path, timeout=timeout, capture_fn=capture_fn)
    except StatusError as exc:
        try:
            record = read(path)
        except StatusError as cached_exc:
            raise StatusError(
                f"live capture failed ({exc}) and there is no usable snapshot "
                f"({cached_exc})"
            ) from exc
        record["capture_error"] = str(exc)
        return record


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m strategy_cache.status",
        description="Capture or show the BuildAlpha status snapshot (read-only).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    cap = sub.add_parser("capture", help="run buildalpha_status.ps1 and write the snapshot")
    cap.add_argument("--out", default=None, help=f"snapshot path (default {DEFAULT_NAME} next to the DB)")
    cap.add_argument("--db", default=None, help="cache database path, used only to locate the default snapshot")
    cap.add_argument("--log-path", default=None, help="BuildAlpha app.log (defaults to the script's own default)")
    cap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="capture timeout in seconds")

    show = sub.add_parser("show", help="print the current snapshot as JSON")
    show.add_argument("--file", default=None, help="snapshot path (default: --db dir, else this repo)")

    args = parser.parse_args(argv)
    try:
        if args.command == "capture":
            db = Path(args.db).expanduser().resolve() if args.db else None
            out = snapshot_path(db, args.out)
            record = refresh(
                out,
                timeout=args.timeout,
                capture_fn=lambda path, timeout: capture(path, args.log_path, timeout),
            )
            print(json.dumps(
                {
                    "snapshot": str(out),
                    "state": record.get("state"),
                    "job": record.get("job"),
                    "throughput": record.get("throughput"),
                    "results_total": record.get("results_total"),
                },
                indent=2,
            ))
        else:
            path = Path(args.file).expanduser().resolve() if args.file else snapshot_path(None)
            print(json.dumps(read(path), indent=2))
    except StatusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
