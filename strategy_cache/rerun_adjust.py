"""Re-run a portfolio strategy with adjustments (opt-in MCP action).

Wraps ``scripts/buildalpha_rerun_adjust.ps1``, which drives the BuildAlpha GUI:
it filters the grid, opens *Run strategy with adjustments*, applies the
requested change, reads the form back, and (unless ``dry_run``) runs the
simulation and returns its results row.

Only a **closed set** of adjustments is exposed, each one only after its
interaction was verified end to end. Today that is the symbol:

    {"kind": "builtin", "name": "BTC", "timeframe": "1h"}
    {"kind": "server",  "name": "ETH-USDT", "timeframe": "1 hour"}

Results are never written to the cache: the cache only holds what a portfolio
contains, and these variant runs are deliberately not saved into a portfolio.
"""
from __future__ import annotations

import json
import subprocess
import time
from datetime import datetime
from pathlib import Path

from sqlalchemy import text

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ADJUST_SCRIPT = ROOT / "scripts" / "buildalpha_rerun_adjust.ps1"

#: script verdict -> tool status
STATUS_BY_EXIT = {
    0: "COMPLETED",          # success (or DRY_RUN, decided by the output line)
    1: "NEW_SYMBOL_REQUIRED",
    2: "NO_BUILDALPHA",
    3: "GRID_MISSING",
    4: "FILTER_EMPTY",
    6: "WRONG_ROW",
    # the shared search's refusals, reported as themselves instead of as a generic failure
    20: "IDENTITY_MISMATCH",
    27: "SELECTION_FAILED",   # 27 was free; 20-26 are taken
    30: "GRID_NOT_VISIBLE",
    7: "RERUN_MENU_FAILED",
    8: "RERUN_WINDOW_MISSING",
    9: "TAB_MISSING",
    10: "SELECTOR_MISSING",
    11: "PICKER_NOT_OPENED",
    12: "SYMBOL_NOT_FOUND",
    13: "TIMEFRAME_NOT_FOUND",
    14: "SELECTION_CELL_MISSING",
    15: "SELECTION_DID_NOT_STICK",
    16: "RUN_BUTTON_MISSING",
    17: "RESULTS_WINDOW_TIMEOUT",
    18: "RESULTS_GRID_MISSING",
    19: "WINDOWS_LEFT_OPEN",
    20: "IDENTITY_MISMATCH",
    21: "DATE_NOT_APPLIED",
    22: "FORM_READ_FAILED",
    23: "NEW_SYMBOL_REQUIRED",
    24: "VERIFY_FAILED",        # the form did not show what we asked for (e.g. wrong symbol)
    25: "INPUT_BLOCKED",        # another program (or a dialog we did not open) held the foreground
    26: "RESULTS_EMPTY",        # grid readable but no metrics row: never report success with blanks    27: "STALE_WINDOW",         # a window this call did not open and cannot close (close it by hand)
    # 1 is what an unhandled PowerShell exception exits with: it must not be
    # mislabelled as a specific precondition failure
    1: "SCRIPT_FAILED",
}


class AdjustError(RuntimeError):
    """The script could not be run at all (missing file, timeout, no powershell)."""


def resolve(conn, tag: str, portfolio: str = "") -> dict:
    """Cache -> everything the script needs to find the row deterministically.

    ``name`` is the exact grid Name cell: ``custom_name`` when the strategy has
    one, otherwise the rule expression. The caller never composes a search.
    """
    from . import queries

    row = queries.get_strategy(conn, tag)
    if row is None:
        raise AdjustError(f"unknown tag {tag!r}")
    symbol_full = (row.get("symbol") or "").strip()
    portfolios = [
        r[0]
        for r in conn.execute(
            text("SELECT portfolio FROM strategy_portfolios WHERE tag = :t ORDER BY portfolio"),
            {"t": tag},
        )
    ]
    if not portfolios and row.get("portfolio"):
        portfolios = [row["portfolio"]]
    target = portfolio or (portfolios[0] if portfolios else "")
    if portfolio and portfolios and portfolio not in portfolios:
        raise AdjustError(
            f"{tag} is not in {portfolio!r} (it is in: {', '.join(portfolios)})"
        )
    name = (row.get("custom_name") or row.get("entry_rules") or "").strip()
    if not name or not symbol_full:
        raise AdjustError(f"{tag} has no name/symbol in the cache; re-ingest its grid")
    return {
        "tag": tag,
        "portfolio": target,
        "name": name,
        "symbol": symbol_full.split("|")[0],      # 'HYPE-USDT|1h' -> 'HYPE-USDT'
        "symbol_full": symbol_full,
        "strategy_type": row.get("strategy_type"),
        "expected": {
            "trades": row.get("trade_count"),
            "sharpe": row.get("sharpe"),
            "net_pnl": row.get("net_pnl"),
        },
    }


def write_plan(conn, tag: str, portfolio: str = "") -> str:
    """Write identify.plan() to a file and return its path.

    The row search is one script now. Rather than re-deriving a filter string here (and re-doing
    the scan inside buildalpha_rerun_adjust.ps1), the plan - candidates in selectivity order plus
    the numbers to verify - is written out and executed by scripts/buildalpha_find_strategy.ps1.
    """
    import os
    import tempfile

    from . import identify

    plan = identify.plan(conn, tag=tag, portfolio=portfolio)
    path = Path(tempfile.gettempdir()) / f"ba-rerun-{tag}-{os.getpid()}.plan.json"
    path.write_text(json.dumps(plan), encoding="utf-8")
    return str(path)


def build_args(
    filter: str,
    expect_symbol: str,
    symbol: dict | None,
    dry_run: bool,
    row_timeout_sec: int = 300,
    expect_name: str = "",
    portfolio: str = "",
    expected: dict | None = None,
    start_date: str = "",
    stop_date: str = "",
    include_trades: bool = False,
    trades_path: str = "",
    dump_fields: str = "",
    plan_path: str = "",
) -> list[str]:
    """Turn the tool arguments into the script's command line."""
    args = ["-Filter", filter, "-ExpectSymbol", expect_symbol]
    if plan_path:
        # the shared row search: scripts/buildalpha_find_strategy.ps1 does the filtering,
        # the metric verification and the click, so this script no longer repeats any of it
        args += ["-PlanFile", plan_path]
    if expect_name:
        args += ["-ExpectName", expect_name]
    if portfolio:
        args += ["-Portfolio", portfolio]
    if start_date:
        args += ["-StartDate", start_date]
    if stop_date:
        args += ["-StopDate", stop_date]
    if dump_fields:
        args += ["-DumpFields", dump_fields]
    if include_trades:
        if dry_run:
            raise AdjustError("include_trades needs a real run: a dry run simulates nothing")
        args += ["-IncludeTrades"]
        if trades_path:
            args += ["-TradesOut", trades_path]
    for key, flag in (("trades", "-ExpectedTrades"), ("sharpe", "-ExpectedSharpe"), ("net_pnl", "-ExpectedPnl")):
        value = (expected or {}).get(key)
        if value is not None:
            args += [flag, str(value)]
    if symbol:
        kind = (symbol.get("kind") or "").strip().lower()
        if kind not in ("builtin", "server"):
            raise AdjustError("symbol.kind must be 'builtin' or 'server'")
        name = (symbol.get("name") or "").strip()
        if not name:
            raise AdjustError("symbol.name is required when symbol is given")
        args += ["-SymbolKind", kind, "-NewSymbol", name]
        if symbol.get("timeframe"):
            args += ["-Timeframe", str(symbol["timeframe"]).strip()]
    if dry_run:
        args.append("-DryRun")
    args += ["-RowTimeoutSec", str(int(row_timeout_sec))]
    return args


def release_topmost(timeout: int = 20) -> dict:
    """Pre-flight: clear WS_EX_TOPMOST on every existing BuildAlpha window.

    A PowerShell `finally` does not run when the process is killed, and a timeout kill,
    a host reboot or an RDP loss all skip teardown, so a window pinned by an older build
    (or by a killed run) can outlive its script. Healing on the next run means a pinned
    window cannot survive indefinitely. Idempotent and cheap; never fatal.
    """
    script = DEFAULT_ADJUST_SCRIPT.parent / "buildalpha_release.ps1"
    if not script.is_file():
        return {"status": "SKIPPED", "reason": "release script missing"}
    command = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(script), "-Json",
    ]
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"status": "SKIPPED", "reason": str(exc)}
    text = (proc.stdout or "").strip().splitlines()
    if not text:
        return {"status": "SKIPPED", "reason": "no output", "exit_code": proc.returncode}
    try:
        payload = json.loads(text[-1])
    except ValueError:
        return {"status": "SKIPPED", "reason": text[-1][:200], "exit_code": proc.returncode}
    if isinstance(payload, dict):
        payload.setdefault("exit_code", proc.returncode)
    return payload


def run(args: list[str], *, script: Path | None = None, timeout: int = 900) -> subprocess.CompletedProcess:
    script = script or DEFAULT_ADJUST_SCRIPT
    if not script.is_file():
        raise AdjustError(f"adjust script not found: {script}")
    command = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(script), *args,
    ]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise AdjustError(f"re-run with adjustments timed out after {timeout}s") from exc
    except OSError as exc:
        raise AdjustError(f"cannot run powershell: {exc}") from exc


def read_trades(run_id: str, *, offset: int = 0, limit: int = 500,
                runlog_path: str | Path | None = None) -> dict:
    """Page the trade TSV recorded for a run.

    The file is storage; this is the interface. A remote caller cannot read a local path,
    and returning a thousand rows inline would bloat every response, so the rows are
    paged here and the journal carries only the pointer.
    """
    from . import runlog as _runlog

    record = _runlog.load_run(run_id, path=runlog_path)
    if not record:
        return {"status": "RUN_NOT_FOUND", "run_id": run_id}
    results = ((record.get("result") or {}).get("results") or {})
    args = record.get("args") or {}
    info = results.get("trades_detail") or {}
    if isinstance(info, list):
        # an older build let log lines leak into the return value, so the record holds a
        # list of strings plus the object; take the object, never crash on it
        dicts = [x for x in info if isinstance(x, dict)]
        info = dicts[-1] if dicts else {}
    # "no file" has three very different meanings, and conflating them makes a caller
    # throw away a perfectly good run:
    #   - the run never asked for trades
    #   - the run asked, but took no trades
    #   - the run asked and took trades, and the export step itself failed
    if not info:
        if results.get("no_trades"):
            return {"status": "NO_TRADES", "run_id": run_id, "tag": record.get("tag"),
                    "hint": "the run completed with zero trades; there is nothing to page"}
        if args.get("include_trades"):
            return {"status": "TRADES_NOT_CAPTURED", "run_id": run_id,
                    "tag": record.get("tag"), "trades": results.get("trades"),
                    "hint": "include_trades was requested but no export was recorded; "
                            "the run's status field says why (e.g. INPUT_BLOCKED)"}
        return {"status": "NO_TRADES_RECORDED", "run_id": run_id, "tag": record.get("tag"),
                "hint": "the run was started without include_trades; re-run it with "
                        "include_trades=true to store the trade list"}
    if info.get("status") != "TRADES_OK":
        return {"status": "TRADES_EXPORT_FAILED", "run_id": run_id, "tag": record.get("tag"),
                "export_status": info.get("status"), "rows": info.get("rows"),
                "grid_rows": info.get("grid_rows"),
                "hint": "the simulation ran but the trade export failed on that run "
                        "(retry the run; the first right-click sometimes misses the menu)"}
    path = info.get("path")
    if not path:
        return {"status": "NO_TRADES_RECORDED", "run_id": run_id,
                "hint": "the record carries no trade file"}
    file = Path(path)
    if not file.is_file():
        return {"status": "TRADES_FILE_MISSING", "run_id": run_id, "path": path}
    lines = [ln for ln in file.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
    if not lines:
        return {"status": "TRADES_FILE_EMPTY", "run_id": run_id, "path": path}
    header = lines[0].split("\t")
    rows = [ln.split("\t") for ln in lines[1:]]
    offset = max(0, offset)
    limit = max(1, min(limit, 5000))
    page = rows[offset: offset + limit]
    return {
        "status": "OK",
        "run_id": run_id,
        "tag": record.get("tag"),
        "columns": header,
        "rows": len(rows),
        "offset": offset,
        "limit": limit,
        "returned": len(page),
        # BuildAlpha renders trade times in the host's local zone and writes no offset.
        # A join against UTC data is off by this much, so say it explicitly.
        "trade_times": {
            "source": "BuildAlpha local rendering (no offset in the data)",
            "utc_offset": datetime.now().astimezone().strftime("%z"),
            "zone": time.strftime("%Z"),
        },
        "verification": {k: info.get(k) for k in ("rows", "grid_rows", "header_ok", "pnl_ok", "result_sum", "status")},
        "trades": page,
    }


def summarize(proc: subprocess.CompletedProcess) -> dict:
    """Script stdout -> {ok, status, ...parsed blocks...}."""
    lines = [line.rstrip() for line in (proc.stdout or "").splitlines() if line.strip()]
    stderr = (proc.stderr or "").strip()
    verdicts = [
        line for line in lines
        if line.strip()
        and not line.startswith(
            ("filter ", "row symbol", "row ", "running", "VERIFY", "ADJUST", "RESULT", "DRY_RUN", "BASELINE", "CLEANED_UP")
        )
    ]

    payload: dict | None = None
    for line in lines:
        if line.startswith(("RESULT ", "DRY_RUN ", "NO_TRADES ")):
            try:
                payload = json.loads(line.split(" ", 1)[1])
            except ValueError:
                payload = None
    baseline: dict | None = None
    for line in lines:
        if line.startswith("BASELINE "):
            try:
                baseline = json.loads(line.split(" ", 1)[1])
            except ValueError:
                baseline = None
    dry_run = any(line.startswith("DRY_RUN ") for line in lines)
    adjust = next((line[7:] for line in lines if line.startswith("ADJUST ")), "")
    verify = [line[7:] for line in lines if line.startswith("VERIFY ")]

    # The script reports the windows it can actually see; derive the flag from that
    # list rather than from which cleanup branch ran.
    windows: list[str] | None = None
    for line in lines:
        if line.startswith("WINDOWS "):
            try:
                parsed = json.loads(line.split(" ", 1)[1])
                windows = parsed if isinstance(parsed, list) else [parsed]
            except ValueError:
                windows = None
    if windows is None:
        cleaned = any(line.strip() == "CLEANED_UP" for line in lines)
    else:
        leftovers = [
            t for t in windows
            if t == "Re-Run" or t.startswith("Re-Run results") or t.startswith("Results window closing")
        ]
        cleaned = not leftovers

    status = "BUSY" if proc.returncode == 40 else STATUS_BY_EXIT.get(proc.returncode, "FAILED")
    # exit 6 covers both guards; the message says which one fired
    if any(line.startswith("ROW_NOT_FOUND") for line in verdicts):
        status = "ROW_NOT_FOUND"
    if any(line.startswith("SYMBOL_MISMATCH") for line in verdicts):
        status = "SYMBOL_MISMATCH"
    # An empty results grid means the run took no trades - a completed outcome, not a
    # failure (the symbol cannot be confirmed from a grid with no row, hence the
    # 'no_results' evidence).
    no_trades = any(line.startswith("NO_TRADES") for line in verdicts)
    if no_trades:
        status = "NO_TRADES"
    # symbols_line is OCR of the drawn selector: a stray glyph can be glued onto the
    # name (builtin:XRP once read back as 'IXRP'). Reported as an OCR disagreement, with
    # no claim about symbol codes - the results grid is what proves the series.
    ocr_differs = next((line for line in lines if line.startswith("FORM_LABEL_OCR_MISMATCH")), "")
    if proc.returncode == 0 and dry_run:
        status = "DRY_RUN"
    elif proc.returncode == 0 and no_trades:
        status = "NO_TRADES"
    elif proc.returncode == 0 and payload is None:
        status = "NO_RESULT"

    result = {
        "ok": proc.returncode == 0,
        "status": status,
        "exit_code": proc.returncode,
        "dry_run": dry_run,
        "adjustment": adjust,
        "verification": verify,
        "windows_cleaned": cleaned,
        "windows": windows,
        "verdicts": verdicts,
        "form_label_ocr_differs": bool(ocr_differs),
        "form_label_ocr_mismatch": ocr_differs or None,
        "baseline": baseline,
        "results": payload,
    }
    if stderr:
        result["stderr"] = stderr[-800:]
    return result
