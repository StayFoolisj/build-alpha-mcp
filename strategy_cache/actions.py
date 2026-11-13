"""Action bridge: the two-phase continuous-simulation script, callable from MCP.

The MCP server must stay read-only by default, so these are *opt-in*: the
server only registers the tools when started with ``--allow-actions``. The work
itself happens in ``buildalpha_continuous.ps1`` (UI Automation); this module
just runs it, enforces a timeout, and turns its stdout into a dict.

    prepare  -> configures the builder, audits every setting, starts NOTHING
    start    -> re-reads/compares, then clicks Continuous simulation
    cancel   -> closes the builder and drops the pending request
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCRIPT = ROOT / "scripts" / "buildalpha_continuous.ps1"
DEFAULT_FILTER_SCRIPT = ROOT / "scripts" / "buildalpha_filter.ps1"
PENDING_NAME = "continuous-pending.json"

#: first stdout tokens that mean "this did not work"
_FAILURE_PREFIXES = (
    "NO_", "BUILDER_NOT", "PICKER_NOT", "TAB_NOT_FOUND", "SYMBOL_FAILED",
    "SYMBOL_NOT_IN_FORM", "TIMEFRAME_FAILED", "START_FAILED", "STOP_FAILED",
    "FILTER_FAILED", "FILTER_DIALOG_NOT_OPENED", "REFUSING",
    "RUN_BUTTON_NOT_FOUND", "BUILTIN_SYMBOLS_UNSUPPORTED",
)


class ActionError(RuntimeError):
    """The script could not be run at all (missing file, timeout, no powershell)."""


#: verdict lines printed by the script (used to pick the status)
_VERDICT = (
    "PREPARED", "STARTED", "DRY_RUN", "REFUSING", "CANCELLED", "FILTERS",
    "SYMBOL_STEP_SKIPPED", "SYMBOL_FAILED", "SYMBOL_NOT_IN_FORM",
    "TIMEFRAME_FAILED", "START_FAILED", "STOP_FAILED", "FILTER_FAILED",
    "FILTER_DIALOG_NOT_OPENED", "NO_BUILDER", "NO_PICKER", "BUILDER_NOT_OPENED",
    "TAB_NOT_FOUND", "PICKER_NOT_OPENED", "RUN_BUTTON_NOT_FOUND",
    "BUILTIN_SYMBOLS_UNSUPPORTED", "NO_BUILDALPHA", "NO_PENDING",
    "STOPPED", "STOP_TIMEOUT", "NOT_RUNNING",
)


def _run(args: list[str], script: Path, timeout: int) -> subprocess.CompletedProcess:
    if not script.is_file():
        raise ActionError(f"continuous-sim script not found: {script}")
    command = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(script), *args,
    ]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise ActionError(f"continuous-sim {args[0]} timed out after {timeout}s") from exc
    except OSError as exc:
        raise ActionError(f"cannot run powershell: {exc}") from exc


def summarize(action: str, proc: subprocess.CompletedProcess, pending_path: Path | None = None) -> dict:
    """Turn script output into a small, client-friendly result."""
    lines = [line.rstrip() for line in proc.stdout.splitlines() if line.strip()]
    # the script prints comparisons first and the verdict in ALL_CAPS on any line
    verdict = next(
        (
            line
            for line in reversed(lines)
            if line.split(" ", 1)[0] in _VERDICT
        ),
        "",
    )
    message = verdict or (lines[0] if lines else proc.stderr.strip()[:300])
    status = message.split(" ", 1)[0] if message else "NO_OUTPUT"
    if "\t" in status:
        status = status.split("\t", 1)[0]
    ok = proc.returncode == 0 and not status.startswith(_FAILURE_PREFIXES)

    audit: dict[str, str] = {}
    for line in lines:
        if line.startswith("  ") and " = " in line:
            label, value = line.strip().split(" = ", 1)
            audit[label] = value

    result: dict = {
        "ok": ok,
        "action": action,
        "status": status,
        "message": message,
        "exit_code": proc.returncode,
    }
    if audit:
        result["settings"] = audit
    if pending_path and pending_path.is_file():
        try:
            # PowerShell writes UTF-8 with a BOM; json.loads chokes on it
            pending = json.loads(pending_path.read_text(encoding="utf-8-sig"))
            # drop the duplicated raw settings list: `settings` already has it and
            # echoing both makes the MCP response large enough to upset SSE clients
            result["pending"] = {k: v for k, v in pending.items() if k != "settings"}
        except ValueError as exc:
            result["pending_error"] = str(exc)
    if not ok and proc.stderr.strip():
        result["stderr"] = proc.stderr.strip()[-400:]
    return result


def prepare(
    *,
    symbol: str,
    timeframe: str,
    start: str,
    stop: str,
    group: str = "Crypto",
    filter: str = "",
    skip_symbol: bool = False,
    script: Path = DEFAULT_SCRIPT,
    timeout: int = 300,
) -> dict:
    args = ["-Action", "prepare", "-Symbol", symbol, "-Timeframe", timeframe,
            "-Start", start, "-Stop", stop, "-Group", group]
    if filter:
        args += ["-Filter", filter]
    if skip_symbol:
        args.append("-SkipSymbol")
    proc = _run(args, script, timeout)
    return summarize("prepare", proc, script.parent / PENDING_NAME)


def list_filters(*, script: Path = DEFAULT_SCRIPT, timeout: int = 180) -> dict:
    """Saved filter groups in the Strategy Builder, with the active one marked."""
    proc = _run(["-Action", "filters"], script, timeout)
    result = summarize("filters", proc)
    names = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] == "FILTER":
            names.append({"name": parts[1], "selected": len(parts) > 2 and parts[2] == "selected"})
    result["filters"] = names
    return result


def start(*, dry_run: bool = False, force: bool = False, script: Path = DEFAULT_SCRIPT, timeout: int = 300) -> dict:
    args = ["-Action", "start"]
    if dry_run:
        args.append("-DryRun")
    if force:
        args.append("-Force")
    proc = _run(args, script, timeout)
    return summarize("start", proc, script.parent / PENDING_NAME)


# --------------------------------------------------------------- post filtering
_FILTER_VERDICTS = (
    "RESULTS", "FILTERED", "RUNNING", "BUSY", "UNREADABLE", "NO_RESULTS_WINDOW",
    "TEST_FILTERS_NOT_OPENED", "FILTER_NOT_FOUND", "FILTER_NOT_SELECTED", "APPLY_NOT_FOUND",
)


def _summarize_filter(action: str, proc: subprocess.CompletedProcess) -> dict:
    lines = [line.rstrip() for line in proc.stdout.splitlines() if line.strip()]
    verdict = next((l for l in reversed(lines) if l.split(" ", 1)[0] in _FILTER_VERDICTS), "")
    message = verdict or (lines[0] if lines else proc.stderr.strip()[:300])
    status = message.split(" ", 1)[0] if message else "NO_OUTPUT"
    result: dict = {
        "ok": proc.returncode == 0 and status in ("RESULTS", "FILTERED"),
        "action": action,
        "status": status,
        "message": message,
        "exit_code": proc.returncode,
    }
    if status == "BUSY":
        result["busy"] = True
    running = re.search(r"running=(True|False|true|false)", proc.stdout)
    if running:
        result["running"] = running.group(1).lower() == "true"
    match = re.search(r"before=(-?\d+) after=(-?\d+)", proc.stdout)
    if match:
        before, after = int(match.group(1)), int(match.group(2))
        result["before"] = before if before >= 0 else None
        result["after"] = after if after >= 0 else None
        if before >= 0 and after >= 0:
            result["changed"] = before != after
    total = re.search(r"total=(-?\d+)", proc.stdout)
    if total:
        value = int(total.group(1))
        result["results_total"] = value if value >= 0 else None
    expr = re.search(r"expression='(.*)'\s*$", proc.stdout, re.MULTILINE)
    if expr:
        result["expression"] = expr.group(1)
    name = re.search(r"filter='([^']*)'", proc.stdout)
    if name:
        result["filter"] = name.group(1)
    busy = re.search(r"busy=(true|false)", proc.stdout)
    if busy:
        result["busy"] = busy.group(1) == "true"
    if not result["ok"] and proc.stderr.strip():
        result["stderr"] = proc.stderr.strip()[-400:]
    return result


def current_test_filter(
    results: str = "",
    *,
    script: Path = DEFAULT_FILTER_SCRIPT,
    timeout: int = 60,
) -> dict:
    """Current row count and applied filter expression of a results window.

    ``results`` is a window-title substring, e.g. ``"SOL-USDT"`` for
    ``Continuous Simulation results - SOL-USDT_4h (Long)``.
    """
    args = ["-Action", "show"]
    if results:
        args += ["-Results", results]
    proc = _run(args, script, timeout)
    return _summarize_filter("show", proc)


def apply_test_filter(
    filter: str,
    results: str = "",
    *,
    script: Path = DEFAULT_FILTER_SCRIPT,
    timeout: int = 120,
) -> dict:
    """Apply a saved filter group to a finished run and report before/after."""
    args = ["-Action", "apply", "-Filter", filter, "-TimeoutSec", str(timeout)]
    if results:
        args += ["-Results", results]
    proc = _run(args, script, timeout + 150)   # opening Test Filters alone can take ~60 s
    return _summarize_filter("apply", proc)


def cancel(*, script: Path = DEFAULT_SCRIPT, timeout: int = 120) -> dict:
    proc = _run(["-Action", "cancel"], script, timeout)
    return summarize("cancel", proc, script.parent / PENDING_NAME)


def stop(*, script: Path = DEFAULT_SCRIPT, timeout: int = 180) -> dict:
    """Stop the running continuous simulation; windows stay open.

    Returns ``results_total`` - the number of candidates in the results window.
    """
    proc = _run(["-Action", "stop"], script, timeout)
    result = summarize("stop", proc, script.parent / PENDING_NAME)
    match = re.search(r"\btotal=(-?\d+)", proc.stdout)
    if match:
        total = int(match.group(1))
        result["results_total"] = total if total >= 0 else None
    return result


