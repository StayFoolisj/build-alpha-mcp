"""Minimal read-only stdio MCP server for the BuildAlpha strategy cache.

Run it with an absolute database path:

    python -m strategy_cache.mcp_server --db C:\\path\\to\\buildalpha_cache.sqlite3

or set ``BA_CACHE_DB``. The database is opened with SQLite ``mode=ro``; the
server never creates or migrates anything, and never prints to stdout (stdout
carries the JSON-RPC stream, logs go to stderr).
"""
from __future__ import annotations

import argparse
import base64
import functools
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from mcp.server import MCPServer
from mcp.server.mcpserver import Image
from mcp.server.mcpserver.exceptions import ToolError
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

from . import actions, db, jobs, metrics, queries, rerun_adjust, runlog, status as status_snapshot, variance_capture

# Trade TSVs live next to the captures, one file per (tag, run_id).
TRADES_DIR = Path(__file__).resolve().parent.parent / "captures" / "trades"

# A capture reply inlines its PNG when it is at most this big; above it the caller
# pulls the file in chunks with buildalpha_read_capture.
INLINE_MAX_BYTES = 65536
# Base for the download URL in every capture reply. Set BA_CAPTURE_BASE_URL to the address a
# remote caller can actually reach (e.g. http://100.112.4.96:8080); otherwise it is built from
# the bind host and port this server was started with.
CAPTURE_BASE_URL = os.environ.get("BA_CAPTURE_BASE_URL", "").rstrip("/")
READ_CHUNK_MAX = 65536

log = logging.getLogger("strategy_cache.mcp")

#: schema revision this server understands (see migrations/versions)
EXPECTED_REVISION = "0003"


def _fail(message: str, code: int = 2) -> "None":
    """Report on stderr and exit (stdout is reserved for the protocol)."""
    print(message, file=sys.stderr)
    raise SystemExit(code)


def resolve_db_path(cli_value: str | None) -> Path:
    """Absolute, resolved path from --db or BA_CACHE_DB. Relative paths are rejected."""
    raw = cli_value or os.environ.get("BA_CACHE_DB")
    if not raw:
        _fail("error: no cache database. Pass --db <absolute path> or set BA_CACHE_DB.")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        _fail(f"error: cache database path must be absolute: {raw!r}")
    return path.resolve()


def read_only_url(path: Path) -> str:
    return f"sqlite:///file:{path.as_posix()}?mode=ro&uri=true"


def _uvicorn_logs_to_stderr() -> None:
    """Uvicorn's default config sends access logs to stdout; stdout stays clean."""
    import uvicorn

    config = uvicorn.config.LOGGING_CONFIG
    for handler in config.get("handlers", {}).values():
        if handler.get("stream") == "ext://sys.stdout":
            handler["stream"] = "ext://sys.stderr"


def open_cache(path: Path):
    """Open an existing cache read-only and verify its schema revision."""
    if not path.is_file():
        _fail(f"error: cache database not found: {path}")
    engine = create_engine(read_only_url(path), future=True)
    try:
        with engine.connect() as conn:
            revision = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
    except SQLAlchemyError as exc:
        _fail(
            f"error: cannot read alembic_version from {path}: {exc}. "
            "Initialise it with 'alembic upgrade head' (this server never migrates)."
        )
    if revision != EXPECTED_REVISION:
        _fail(
            f"error: unsupported cache schema {revision!r} in {path}; "
            f"expected {EXPECTED_REVISION!r}. This server does not run migrations."
        )
    return engine


def _logged_tool(server, **kwargs):
    """Register a tool that also journals the call to the run log.

    One wrapper for every tool, so a call is recorded even when the tool raises
    (TOOL_ERROR / EXCEPTION) or is killed before it returns (a start line with no
    finish line). Tools keep their signatures - the wrapper is transparent.
    """

    def decorator(fn):
        name = fn.__name__

        if name in runlog.NO_JOURNAL:
            # self-journalling (rerun_with_adjustments) or a log reader that would
            # otherwise shadow the record it is looking up
            server.tool(**kwargs)(fn)
            return fn

        @functools.wraps(fn)
        def wrapper(*args, **kw):
            run_id = runlog.record_start(name, kw, tag=kw.get("tag"))
            started = time.perf_counter()
            try:
                result = fn(*args, **kw)
            except ToolError as exc:
                runlog.record_finish(
                    run_id, name, kw, tag=kw.get("tag"), status="TOOL_ERROR",
                    duration_ms=round((time.perf_counter() - started) * 1000, 1), error=str(exc),
                )
                raise
            except Exception as exc:  # noqa: BLE001 - journalled, then re-raised
                runlog.record_finish(
                    run_id, name, kw, tag=kw.get("tag"), status="EXCEPTION",
                    duration_ms=round((time.perf_counter() - started) * 1000, 1),
                    error=f"{type(exc).__name__}: {exc}",
                )
                raise
            payload = result if isinstance(result, dict) else None
            runlog.record_finish(
                run_id, name, kw, tag=kw.get("tag"),
                status=str((payload or {}).get("status") or "OK"),
                exit_code=(payload or {}).get("exit_code"),
                duration_ms=round((time.perf_counter() - started) * 1000, 1),
                result=result,
                windows=(payload or {}).get("windows"),
            )
            return result

        server.tool(**kwargs)(wrapper)
        return wrapper

    return decorator


def build_server(
    engine,
    db_path: Path,
    status_path: Path,
    status_timeout: int = status_snapshot.DEFAULT_TIMEOUT,
    *,
    allow_actions: bool = False,
    continuous_script: Path = actions.DEFAULT_SCRIPT,
) -> MCPServer:
    server = MCPServer(
        name="buildalpha-strategy-cache",
        version="0.3.0",
        instructions=(
            "Read-only access to a cached BuildAlpha strategy portfolio. "
            "Tags are deterministic (see strategy_cache.normalize). "
            "Use cache_stats to see what is cached and describe_metrics to learn "
            "the units of each metric before filtering or comparing."
            + (
                " Action tools are enabled: prepare_continuous_sim configures a "
                "run and audits it without starting, start_continuous_sim starts "
                "the prepared run."
                if allow_actions
                else ""
            )
        ),
    )

    @_logged_tool(server, description="List cached strategies; optionally filter by portfolio name.")
    def list_strategies(portfolio: str | None = None) -> list[dict]:
        with engine.connect() as conn:
            return queries.list_strategies(conn, portfolio)

    @_logged_tool(server, description="Full cached row for one tag, with settings_json parsed into an object.")
    def get_strategy(tag: str) -> dict:
        with engine.connect() as conn:
            record = queries.get_strategy(conn, tag)
        if record is None:
            raise ToolError(f"strategy {tag!r} not found")
        return record

    @_logged_tool(server, 
        description=(
            "Filter, sort and paginate cached strategies. Filters: portfolio, "
            "symbol (exact '@ES|1h' or bare '@ES' for all timeframes), "
            "strategy_type, name_contains (substring of entry_rules or custom_name), "
            "and min_metrics/max_metrics keyed by metric column name "
            "(see describe_metrics), e.g. {\"sharpe\": 1.5, \"trade_count\": 50}. "
            "sort is any metric or tag/symbol/portfolio/strategy_type; limit <= 500. "
            "Returns total (unpaginated) plus rows, so paging is honest."
        )
    )
    def query_strategies(
        portfolio: str | None = None,
        include_removed: bool = False,
        symbol: str | None = None,
        strategy_type: str | None = None,
        name_contains: str | None = None,
        min_metrics: dict[str, float] | None = None,
        max_metrics: dict[str, float] | None = None,
        sort: str = "sharpe",
        order: str = "desc",
        limit: int = 50,
        offset: int = 0,
    ) -> dict:
        try:
            with engine.connect() as conn:
                return queries.query_strategies(
                    conn,
                    portfolio=portfolio,
                    include_removed=include_removed,
                    symbol=symbol,
                    strategy_type=strategy_type,
                    name_contains=name_contains,
                    min_metrics=min_metrics,
                    max_metrics=max_metrics,
                    sort=sort,
                    order=order,
                    limit=limit,
                    offset=offset,
                )
        except ValueError as exc:
            raise ToolError(str(exc)) from exc

    @_logged_tool(server, 
        description=(
            "Portfolios with their *current* membership count, taken from the newest "
            "authoritative (ok) scan of each portfolio. Each entry carries as_of (when "
            "that scan finished), scan_id, ok and removed (how many strategies the "
            "ledger knows about that the newest snapshot no longer lists - i.e. deleted "
            "in BuildAlpha since then). Use include_removed=true for the append-only "
            "counts instead."
        )
    )
    def list_portfolios(include_removed: bool = False) -> list[dict]:
        with engine.connect() as conn:
            return queries.list_portfolios(conn, include_removed=include_removed)

    @_logged_tool(server, 
        description=(
            "What changed in a portfolio between its two most recent authoritative "
            "scans: added / removed tags, plus the scan ids and the older scan's time. "
            "This is how a deletion surfaces - a strategy removed in BuildAlpha is "
            "absent from the newest snapshot, and appears under 'removed'."
        )
    )
    def portfolio_changes(portfolio: str) -> dict:
        with engine.connect() as conn:
            latest = db.latest_scan(conn, portfolio)
            if not latest:
                raise ToolError(f"no scan recorded for portfolio {portfolio!r}")
            previous = conn.execute(
                db.text(
                    "SELECT id FROM portfolio_scans WHERE portfolio = :p AND ok = 1 "
                    "AND id < :s ORDER BY id DESC LIMIT 1"
                ),
                {"p": portfolio, "s": latest["id"]},
            ).scalar()
            if previous is None:
                return {
                    "portfolio": portfolio,
                    "scan": latest,
                    "previous_scan": None,
                    "note": "only one authoritative scan so far; nothing to diff yet",
                    "members": len(db.scan_members(conn, latest["id"])),
                }
            change = db.scan_diff(conn, portfolio, int(previous), int(latest["id"]))
            change["scan"] = latest
            return change

    @_logged_tool(server,
        description=(
            "The most recent journalled RUN for a tag, plus any run still in flight. "
            "Use this after a caller-side timeout or a RUNNING reply: the work was "
            "already done (or is still running), so fetch it instead of re-running "
            "the simulation. Returns {record, in_flight, dry_run_record}; 'record' "
            "is a real run by default (set include_dry_run=true to accept a dry run "
            "when no real run exists). If 'in_flight' is set, the run is still going."
        )
    )
    def get_last_result(tag: str, include_dry_run: bool = False) -> dict:
        found = runlog.last_result(tag, include_dry_run=include_dry_run)
        if not found["record"] and not found["in_flight"]:
            raise ToolError(f"no journalled run for tag {tag!r}")
        out: dict = {"status": "OK", "tag": tag, "record": found["record"]}
        if found["in_flight"]:
            out["in_flight"] = found["in_flight"]
            out["hint"] = "a run for this tag is still in flight; poll again"
        if not found["record"]:
            out["status"] = "RUNNING"
            out["dry_run_record"] = found["dry_run_record"]
        return out

    @_logged_tool(server,
        description=(
            "Recent journalled tool calls, newest first - the post-mortem view. "
            "Filter by tag, tool and/or status (e.g. status='FORM_READ_FAILED', "
            "'EXCEPTION', 'TOOL_ERROR', 'RUNNING') to find failures; tag='<tag>' "
            "returns every run for that strategy, so earlier evidence is never "
            "hidden by a later run."
        )
    )
    def recent_runs(limit: int = 20, tool: str = "", status: str = "", tag: str = "") -> list[dict]:
        return runlog.recent(limit=limit, tool=tool or None, status=status or None,
                             tag=tag or None)

    @_logged_tool(server,
        description=(
            "Page the trade list captured for one run (include_trades=true). "
            "The TSV is stored server-side; this returns it in pages so a remote caller "
            "gets rows, not a local path. verify status/rows before trusting a page. "
            "Call with offset=0 and step by `returned` until offset+returned >= rows."
        )
    )
    def trades(run_id: str, offset: int = 0, limit: int = 500) -> dict:
        try:
            return rerun_adjust.read_trades(run_id, offset=offset, limit=limit)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"cannot read trades for run {run_id}: {exc}") from exc

    @_logged_tool(server,
        description=(
            "Shape of the cache: row count, schema revision, portfolios, symbols, "
            "strategy types, first/last seen dates and logical families. "
            "Start here to learn what is available."
        )
    )
    def cache_stats() -> dict:
        with engine.connect() as conn:
            stats = queries.cache_stats(conn)
        stat_result = db_path.stat()
        stats["database"] = {
            "path": str(db_path),
            "size_bytes": stat_result.st_size,
            "modified_at": datetime.fromtimestamp(
                stat_result.st_mtime, timezone.utc
            ).isoformat(timespec="seconds"),
            "read_only": True,
        }
        return stats

    @_logged_tool(server, 
        description=(
            "Glossary for the 26 metric columns: label, unit, direction "
            "(higher/lower is better) and a short note. Units are conventional "
            "hints; BuildAlpha is the authority on the formulas."
        )
    )
    def describe_metrics() -> dict:
        return {
            "count": len(metrics.METRICS),
            "metrics": metrics.describe(),
            "note": (
                "direction is a conventional hint, not a BuildAlpha specification; "
                "percent values are stored as percentages (9.46 = 9.46%)."
            ),
        }

    @_logged_tool(server, 
        description=(
            "BuildAlpha status, captured live through UI Automation (~1 s): "
            "process state, state (running/results-open/idle), job lifecycle "
            "(job.summary: 'running for 4h 32m' or 'completed 37m ago', with "
            "started/ended/duration/ended_source), throughput, results count "
            "and filter. The capture is written to the snapshot file and "
            "returned with age_seconds=0. Pass fresh=false to read the last "
            "snapshot instead; if a live capture fails, the snapshot is "
            "returned with mode='cached' and capture_error set."
        )
    )
    def buildalpha_status(fresh: bool = True) -> dict:
        try:
            return status_snapshot.latest(status_path, live=fresh, timeout=status_timeout)
        except status_snapshot.StatusError as exc:
            raise ToolError(str(exc)) from exc

    if allow_actions:

        @_logged_tool(server, 
            description=(
                "STEP 1 of 2 for a continuous simulation. Configures the "
                "Strategy Builder for the given symbol/timeframe/date range, "
                "optionally activates a saved filter group (see list_filters), "
                "reads EVERY setting back (dates, IS/OOS, costs, fitness) and "
                "returns them for confirmation. It does NOT start the run. "
                "Server-side symbols only; set skip_symbol=true to keep the "
                "symbols already in the form. "
                "Call start_continuous_sim after the user confirms."
            )
        )
        def prepare_continuous_sim(
            symbol: str,
            timeframe: str,
            start: str,
            stop: str,
            group: str = "Crypto",
            filter: str = "",
            skip_symbol: bool = False,
        ) -> dict:
            try:
                return actions.prepare(
                    symbol=symbol,
                    timeframe=timeframe,
                    start=start,
                    stop=stop,
                    group=group,
                    filter=filter,
                    skip_symbol=skip_symbol,
                    script=continuous_script,
                )
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Saved filter groups in the Strategy Builder (Basic, Foundation, "
                "MCP Loose, ...) with the active one marked. Pass a name as "
                "prepare_continuous_sim(filter=...) to switch."
            )
        )
        def list_filters() -> dict:
            try:
                return actions.list_filters(script=continuous_script)
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "STEP 2 of 2: starts the continuous simulation prepared by "
                "prepare_continuous_sim. Re-reads the builder first and refuses "
                "if symbol/timeframe/dates drifted (force=true overrides). "
                "dry_run=true only verifies and reports the comparison."
            )
        )
        def start_continuous_sim(dry_run: bool = False, force: bool = False) -> dict:
            try:
                return actions.start(dry_run=dry_run, force=force, script=continuous_script)
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Applies a saved filter group to a FINISHED run's results "
                "(post-test filtering) and reports before/after candidate counts. "
                "results='SOL-USDT' (title substring) targets a specific run."
            )
        )
        def apply_test_filter(filter: str, results: str = "") -> dict:
            try:
                return actions.apply_test_filter(filter, results=results)
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Current candidate count and applied filter expression of the "
                "results window (no changes). Pass results='SOL-USDT' (a title "
                "substring) to pick a specific continuous run."
            )
        )
        def current_test_filter(results: str = "") -> dict:
            try:
                return actions.current_test_filter()
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Stops the running continuous simulation. No window is closed: "
                "the results window and the Strategy Builder stay open. Returns "
                "results_total - how many candidates the run produced."
            )
        )
        def stop_continuous_sim() -> dict:
            try:
                return actions.stop(script=continuous_script)
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Cancels a prepared continuous simulation: closes the Strategy "
                "Builder window and deletes the pending request."
            )
        )
        def cancel_continuous_sim() -> dict:
            try:
                return actions.cancel(script=continuous_script)
            except actions.ActionError as exc:
                raise ToolError(str(exc)) from exc

        @_logged_tool(server, 
            description=(
                "Re-run ONE cached strategy with an adjustment, identified by its tag. "
                "The caller passes ids, never search strings: the row is located from "
                "the cache (grid Name, symbol, baseline metrics), the grid is filtered "
                "by symbol only, and the located row must match the cached Name exactly "
                "AND carry the cached trades/sharpe/net P&L - otherwise nothing runs "
                "(status IDENTITY_MISMATCH). 'portfolio' is only needed when the tag is "
                "listed in several portfolios. Adjustable: the symbol (server-side or "
                "built-in) and the date window via start_date/stop_date ('yyyy-MM-dd'); "
                "the form normalises the stop time to end-of-day, so only the date is "
                "authoritative, and nothing runs if the dates do not read back (status "
                "DATE_NOT_APPLIED). When the dates change, the cached baseline no "
                "longer describes the run, so treat delta as symbol+window rather than "
                "as a like-for-like comparison. The response carries 'resolved' (what the "
                "cache said), 'baseline' (the located grid row before the run), the "
                "results row and its 'delta' (after - before) over the 26 shared "
                "metrics. dry_run=true applies and verifies only, then closes the "
                "window - no simulation is started. Results are NOT written to the "
                "cache."
            )
        )
        def rerun_with_adjustments(
            tag: str,
            symbol: dict | None = None,
            portfolio: str = "",
            start_date: str = "",
            stop_date: str = "",
            dry_run: bool = False,
            row_timeout_sec: int = 1500,
            max_wait_sec: int = 45,
            include_trades: bool = False,
        ) -> dict:
            call_args = {"tag": tag, "symbol": symbol, "portfolio": portfolio,
                         "start_date": start_date, "stop_date": stop_date,
                         "dry_run": dry_run, "row_timeout_sec": row_timeout_sec,
                         "include_trades": include_trades}
            started = time.perf_counter()
            # Journal first: everything below can block (resolve, the pre-flight subprocess,
            # the job lock) or throw, and a call with no record at all cannot be told apart
            # from a call that never happened.
            run_id = runlog.record_start("rerun_with_adjustments", call_args, tag=tag)

            # Trades land in a file keyed by tag AND run id: the same tag is re-run with
            # different windows, and a tag-only name would silently overwrite history.
            trades_path = ""
            if include_trades:
                trades_path = str(TRADES_DIR / f"{tag}-{run_id}.tsv")

            try:
                plan_path = ""
                from . import identify as identify_mod   # local: keeps the import graph flat
                with engine.connect() as conn:
                    resolved = rerun_adjust.resolve(conn, tag, portfolio)
                    try:
                        plan_path = rerun_adjust.write_plan(conn, tag, portfolio)
                    except identify_mod.IdentifyError:
                        # the search can still run on the legacy filter; a plan is an improvement,
                        # not a prerequisite
                        plan_path = ""
                args = rerun_adjust.build_args(
                    filter=resolved["symbol"],
                    expect_symbol=resolved["symbol"].split("-")[0],
                    symbol=symbol,
                    dry_run=dry_run,
                    row_timeout_sec=row_timeout_sec,
                    expect_name=resolved["name"],
                    portfolio=resolved["portfolio"],
                    expected=resolved["expected"],
                    start_date=start_date,
                    stop_date=stop_date,
                    include_trades=include_trades,
                    trades_path=trades_path,
                    plan_path=plan_path,
                )
            except rerun_adjust.AdjustError as exc:
                # journal the failed call too: a caller that sees "no journalled run" cannot
                # tell "never ran" from "ran and died", and that was a real complaint
                runlog.record_finish(
                    run_id, "rerun_with_adjustments", call_args, tag=tag,
                    status="FAILED", exit_code=None, duration_ms=0.0,
                    result={"ok": False, "status": "FAILED", "stage": "resolve",
                            "error": str(exc)},
                    stdout="", stderr=f"resolve: {exc}",
                )
                raise ToolError(str(exc)) from exc

            def work() -> dict:
                """Run the script, journal the outcome, return the summary."""
                proc = rerun_adjust.run(args)
                summary = rerun_adjust.summarize(proc)
                # The trade TSV is keyed by run id. A COMPLETED reply used to omit it, so a caller
                # that asked for trades had no handle to page them with (only the RUNNING branch
                # carried it).
                summary.setdefault("run_id", run_id)
                summary.setdefault("tag", tag)
                summary["resolved"] = resolved
                summary["preflight"] = preflight
                runlog.record_finish(
                    run_id, "rerun_with_adjustments", call_args, tag=tag,
                    status=summary["status"], exit_code=summary.get("exit_code"),
                    duration_ms=round((time.perf_counter() - started) * 1000, 1),
                    result=summary, stdout=proc.stdout or "", stderr=proc.stderr or "",
                    windows=summary.get("windows"),
                )
                return summary

            # Pre-flight: a killed run cannot clean up after itself (no finally runs when
            # the process is killed, and a timeout kill / reboot / RDP loss skips teardown
            # entirely), so clear topmost on every existing BuildAlpha window first. This
            # is what makes a leaked pin self-healing instead of requiring a reboot.
            try:
                preflight = rerun_adjust.release_topmost()
            except Exception as exc:  # noqa: BLE001 - never fatal, never a blank journal
                preflight = {"status": "SKIPPED", "reason": f"{type(exc).__name__}: {exc}"}
            try:
                job = jobs.start("rerun_with_adjustments", work)
            except jobs.Busy as busy:
                raise ToolError(
                    json.dumps({
                        "status": "BUSY",
                        "active_job_id": busy.job.id,
                        "active_tool": busy.job.name,
                        "hint": "another BuildAlpha run is in progress; poll "
                                "get_last_result(tag) for that tag instead of starting "
                                "a second one (two runs would fight over the same UI)",
                    })
                ) from busy

            if not job.wait(max_wait_sec if max_wait_sec > 0 else None):
                # Hand the work off: it keeps running and journals its own outcome.
                # run_id is the JOURNAL id - the one the record and trades(run_id) use.
                # job_id is an internal handle and must never be passed to those tools.
                return {
                    "ok": True,
                    "status": "RUNNING",
                    "run_id": run_id,
                    "job_id": job.id,
                    "tag": tag,
                    "dry_run": dry_run,
                    "elapsed_ms": job.duration_ms,
                    "hint": "not finished within max_wait_sec; the run continues in "
                            "the background. Poll get_last_result(tag) - do NOT re-run. "
                            "Take run_id from that record, not from this reply.",
                }

            if job.error:
                raise ToolError(json.dumps({"status": "EXCEPTION", "run_id": run_id,
                                            "error": job.error}))
            summary = job.result or {}
            if not summary.get("ok"):
                raise ToolError(json.dumps(summary))
            return summary

        def _capture_view(
            view: str,
            tag: str = "",
            run_id: str = "",
            name: str = "",
            timeout_sec: int = 150,
            max_image_bytes: int = 1048576,
            include_image: bool = True,
            include_base64: bool = True,
        ) -> list:
            call_args = {"tag": tag, "run_id": run_id, "name": name,
                         "timeout_sec": timeout_sec, "max_image_bytes": max_image_bytes,
                         "include_image": include_image, "include_base64": include_base64}
            started = time.perf_counter()
            # Self-journalled (name in runlog.NO_JOURNAL): the reply holds a base64 image,
            # and the journal must record the file, never the pixels.
            # Journalled for every outcome, including a raise from the script runner: a tool
            # that fails without a journal line cannot be seen in recent_runs at all.
            tool_name = f"capture_{view}"
            run_id_j = runlog.record_start(tool_name, call_args, tag=tag or None)

            def finish(payload: dict, image: list | None) -> list:
                # SIZE_CAP is a successful capture whose image block was too large, and
                reply = {"ok": payload.get("status") in ("OK", "SIZE_CAP"), **payload}
                runlog.record_finish(
                    run_id_j, tool_name, call_args, tag=tag or None,
                    status=str(payload.get("status")),
                    duration_ms=round((time.perf_counter() - started) * 1000, 1),
                    result=reply,
                )
                return [reply, *(image or [])]

            def failed(status: str, detail: str) -> list:
                reply = variance_capture.summarize(
                    subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr=detail),
                    include_view_fields=(view != "variance"))
                reply["status"] = status
                reply["detail"] = detail
                reply["image_omitted_reason"] = "NOT_FOUND" if status == "TAG_NOT_FOUND" else None
                reply["url"] = None
                reply["target"] = {"tag": tag or None, "run_id": run_id or None,
                                   "row": None, "symbol": None}
                return finish(reply, None)

            if not tag and not run_id:
                return failed("TAG_NOT_FOUND", "one of tag or run_id is required")
            try:
                with engine.connect() as conn:
                    target = variance_capture.resolve(conn, tag, run_id)
            except variance_capture.CaptureError as exc:
                return failed("TAG_NOT_FOUND", str(exc))

            # The file is named after what it shows: the tag, or the run when one was given.
            # A literal default ('target') made every capture overwrite the same file.
            # the file is named after the tag/run, with the view's own suffix
            stem_source = (name or run_id or tag or "target").strip()
            stem = "".join(c for c in stem_source if c.isalnum() or c in "-_.") or "target"
            out_path = variance_capture.SCREENS_DIR / f"{stem}{variance_capture.VIEWS[view]['suffix']}"
            # The row search, the re-run and the view are all decided in one place now:
            # identify.plan() (the order) and scripts/buildalpha_find_strategy.ps1 (the execution,
            # which also opens a Re-Run results window and selects the row there).
            # In the temp directory, not next to the capture: one plan file per call accumulated in
            # captures/screens/ forever, and a plan is scrap.
            plan_path = Path(tempfile.gettempdir()) / f"ba-{out_path.stem}.plan.json"
            try:
                from . import identify
                with engine.connect() as conn:
                    plan = identify.plan(conn, tag=tag, run_id=run_id, name=name,
                                         portfolio=target.get("portfolio") or "")
                plan_path.write_text(json.dumps(plan), encoding="utf-8")
            except Exception as exc:
                detail = getattr(exc, "detail", None) or str(exc)
                status = getattr(exc, "status", "IDENTITY_MISMATCH")
                return failed(status, detail)
            args = variance_capture.build_args(target, out_path, timeout_sec, view=view,
                                               plan_path=plan_path)
            try:
                proc = variance_capture.run(args, timeout_sec)
            except variance_capture.CaptureError as exc:
                variance_capture.record_tool_error(run_id_j, tool_name, call_args, tag, exc)
                # A timeout carries the stage trace the script had printed by then, so the reply
                # says *where* it stopped instead of only that it stopped.
                # stderr carries the child's own tail, never a copy of the exception text:
                # the same sentence in detail, stderr and error is three places to read, none
                # of which tells you more than the first
                reply = {
                    **variance_capture.summarize(
                        subprocess.CompletedProcess(args=[], returncode=1,
                                                   stdout="", stderr=getattr(exc, "tail", "")),
                        include_view_fields=(view != "variance")),
                    "status": "TIMEOUT" if "timed out" in str(exc) else "CAPTURE_FAILED",
                    "detail": str(exc),
                    "stages": getattr(exc, "stages", None) or None,
                    "last_stage": getattr(exc, "last_stage", None),
                }
                if getattr(exc, "tail", ""):
                    reply["stage_tail"] = exc.tail
                return finish(reply, None)

            payload = variance_capture.summarize(proc, target, include_view_fields=(view != "variance"))
            if payload["status"] != "OK":
                return finish(payload, None)

            image_blocks: list = []
            if include_image:
                try:
                    encoded = variance_capture.read_image(payload)
                except (OSError, variance_capture.CaptureError) as exc:
                    payload["status"] = "CAPTURE_FAILED"
                    payload["detail"] = str(exc)
                    return finish(payload, None)
                if encoded is None:
                    payload["status"] = "CAPTURE_FAILED"
                    payload["detail"] = "capture reported OK but wrote no file"
                    return finish(payload, None)
                data, encoded_len = encoded
                if variance_capture.apply_size_cap(payload, encoded_len, max_image_bytes):
                    payload["image_included"] = True
                    image_blocks = [Image(data=base64.b64decode(data), format="png")]
                else:
                    payload["bytes"] = payload["bytes"] or encoded_len
            else:
                payload["image_omitted_reason"] = "NOT_REQUESTED"

            # A caller on another machine cannot read a Windows path, so the bytes travel in the
            # reply when they are small enough to inline. Above the cap the reply says so and the
            # caller pulls it with buildalpha_read_capture.
            # a URL the caller can fetch the file from, whether or not the bytes are inlined
            payload["url"] = (f"{CAPTURE_BASE_URL}/captures/{Path(payload['path']).name}"
                              if payload.get("path") and CAPTURE_BASE_URL else None)
            payload["base64"] = None
            payload["chunked"] = False
            payload["size"] = None
            if include_base64:
                try:
                    raw = Path(payload["path"]).read_bytes()
                except OSError as exc:
                    payload["detail"] = (payload["detail"] or "") + f" (bytes unreadable: {exc})"
                    raw = b""
                payload["size"] = len(raw)
                if not raw:
                    pass
                elif len(raw) <= INLINE_MAX_BYTES:
                    payload["base64"] = base64.b64encode(raw).decode("ascii")
                else:
                    payload["chunked"] = True
                    payload["detail"] = (
                        f"image is {len(raw)} bytes, above the {INLINE_MAX_BYTES}-byte inline cap; "
                        "base64 is null - pull the file with buildalpha_read_capture(path)")
            return finish(payload, image_blocks)

        @_logged_tool(server,
            description=(
                "Screenshot BuildAlpha's Variance Testing view for one strategy. Identify "
                "it by tag (same identity check as rerun_with_adjustments: the located "
                "row must show the cached symbol AND carry the cached trades/sharpe/net "
                "P&L, else IDENTITY_MISMATCH and nothing is captured) or by run_id (a "
                "journalled re-run, whose own row is used). Opens the view from the "
                "right-hand navigation menu - accelerator V first, then the label by OCR "
                "- waits for two stable frames, captures the client area, downscales to "
                "at most 1568 px wide and saves captures/screens/<name>-variance.png. "
                "The reply carries path/bytes/sha256/width/height for the durable file "
                "and, unless include_image is false or the encoded image exceeds "
                "max_image_bytes (status SIZE_CAP), the image itself as a second "
                "content block. The dialog is left open on success and closed on "
                "failure. This is an action tool: it moves the pointer and clicks."
            )
        )
        def capture_variance_test(
            tag: str = "",
            run_id: str = "",
            name: str = "",
            timeout_sec: int = 150,
            max_image_bytes: int = 1048576,
            include_image: bool = True,
            include_base64: bool = True,
        ) -> list:
            return _capture_view(
                view="variance", tag=tag, run_id=run_id, name=name,
                timeout_sec=timeout_sec, max_image_bytes=max_image_bytes,
                include_image=include_image, include_base64=include_base64,
            )

        @_logged_tool(server,
            description=(
                "Screenshot BuildAlpha's Monte Carlo Analysis view for one strategy and, before "
                "capturing, click Resample so the picture shows a post-resample panel. Same "
                "shared path as capture_variance_test (portfolio select, grid filter, identity "
                "check, title check, client-area capture, 1568 px cap, panel OCR) with the view "
                "'MC Analysis', the button 'Resample' and the suffix '-mc.png'. Identify by tag "
                "or run_id. The reply carries the same fields plus view_opened_by (uia-name | "
                "label-ocr | accelerator) and button_clicked. The image block is sent whenever a "
                "file exists; RESAMPLE_NOT_FOUND means no file was written."
            )
        )
        def capture_mc_analysis(
            tag: str = "",
            run_id: str = "",
            name: str = "",
            timeout_sec: int = 150,
            max_image_bytes: int = 1048576,
            include_image: bool = True,
            include_base64: bool = True,
        ) -> list:
            return _capture_view(
                view="mc", tag=tag, run_id=run_id, name=name,
                timeout_sec=timeout_sec, max_image_bytes=max_image_bytes,
                include_image=include_image, include_base64=include_base64,
            )

        @_logged_tool(server,
            description=(
                "Screenshot BuildAlpha's Monte Carlo Draw Down view for one strategy. Same "
                "shared path as capture_variance_test (portfolio select, grid filter, identity "
                "check, two stable frames, client-area capture, 1568 px cap) with the view "
                "'Monte Carlo Draw Down' and the suffix '-mcdd.png'. There is no button to "
                "press, so the reply carries view_opened_by and no button_clicked. The window "
                "is titled 'Monte Carlo Drawdown - Cumulative results' and does NOT name the "
                "row, so identity rests on the action's own window plus the single-row filtered "
                "grid; grid.row carries the name that was matched. The image block is sent "
                "whenever a file exists."
            )
        )
        def capture_mc_drawdown(
            tag: str = "",
            run_id: str = "",
            name: str = "",
            timeout_sec: int = 150,
            max_image_bytes: int = 1048576,
            include_image: bool = True,
            include_base64: bool = True,
        ) -> list:
            return _capture_view(
                view="mcdd", tag=tag, run_id=run_id, name=name,
                timeout_sec=timeout_sec, max_image_bytes=max_image_bytes,
                include_image=include_image, include_base64=include_base64,
            )

        @_logged_tool(server,
            description=(
                "Screenshot the E-Ratio plot of one strategy. Opens BuildAlpha's Metrics view "
                "(a 5 column by 4 row grid of plots) and saves only its top-left cell, the "
                "E-Ratio panel. Same shared path as capture_variance_test - portfolio select, "
                "grid filter, identity check, two stable frames, client-area capture - with the "
                "view 'Metrics' and the suffix '-eratio.png'; no button is pressed. The reply "
                "carries view_opened_by and a crop object {x, y, width, height, source_width, "
                "source_height} whose figures multiply out to the client area: one fifth of the "
                "width by one quarter of the height, no inset. The image block is sent whenever "
                "a file exists."
            )
        )
        def capture_eratio(
            tag: str = "",
            run_id: str = "",
            name: str = "",
            timeout_sec: int = 150,
            max_image_bytes: int = 1048576,
            include_image: bool = True,
            include_base64: bool = True,
        ) -> list:
            return _capture_view(
                view="eratio", tag=tag, run_id=run_id, name=name,
                timeout_sec=timeout_sec, max_image_bytes=max_image_bytes,
                include_image=include_image, include_base64=include_base64,
            )

        @_logged_tool(server,
            description=(
                "Read a capture PNG in chunks so a caller on another machine can store it. "
                "Use this when a capture reply came back with chunked=true (its file is above "
                "the 65536-byte inline cap). Arguments: path (exactly the path a capture tool "
                "returned), offset (default 0), length (default 65536, capped at 65536). "
                "Returns {ok, path, size, offset, length, base64, eof}: base64 holds exactly the "
                "requested slice and eof is true when the slice reaches the end of the file, so "
                "the caller loops offset += length until eof. A path outside the captures "
                "directory is refused with PATH_REJECTED and nothing is read."
            )
        )
        def buildalpha_read_capture(path: str, offset: int = 0, length: int = 65536) -> dict:
            return read_capture_chunk(path, offset, length)

        # --- HTTP download of a capture -------------------------------------
        # A capture reply names a file on this machine; a caller elsewhere needs a URL. One
        # route, GET only, one directory, no listing. No auth: the exposure limit is the bind
        # address (tailnet), not this handler.
        @server.custom_route("/captures/{filename:path}", methods=["GET"], include_in_schema=False)
        async def download_capture(request):  # noqa: ANN001 - Starlette request
            from starlette.responses import FileResponse, PlainTextResponse

            name = request.path_params.get("filename") or ""
            # any of these is a probe, so answer 403 rather than pretending the file is missing
            if not name or ".." in name or "/" in name or "\\" in name or name.startswith("."):
                return PlainTextResponse("forbidden", status_code=403)
            root = variance_capture.CAPTURES_DIR.resolve()
            try:
                target = (root / "screens" / name).resolve()
            except (OSError, ValueError):
                return PlainTextResponse("forbidden", status_code=403)
            if not target.is_relative_to(root):
                return PlainTextResponse("forbidden", status_code=403)
            if not target.is_file():
                return PlainTextResponse("not found", status_code=404)
            return FileResponse(str(target), media_type="image/png")

    return server


def _local_ipv4() -> str:
    """This machine's outward-facing IPv4, without opening a connection."""
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
        finally:
            sock.close()
    except OSError:
        return "127.0.0.1"


def read_capture_chunk(path: str, offset: int = 0, length: int = 65536) -> dict:
    """One slice of a capture file, and never more than the chunk cap.

    The tool exists because a Windows path means nothing to a caller on another machine. It is
    deliberately narrow: only files under the captures directory, only reads, and the refusal
    names the reason instead of raising.
    """
    def reject(reason: str) -> dict:
        return {"ok": False, "status": "PATH_REJECTED", "detail": reason,
                "path": path, "size": None, "offset": offset, "length": 0,
                "base64": None, "eof": True}

    if not path:
        return reject("path is required")
    root = variance_capture.CAPTURES_DIR.resolve()
    try:
        target = Path(path).resolve()
    except (OSError, ValueError) as exc:
        return reject(f"path is not usable: {exc}")
    if not target.is_relative_to(root):
        return reject(f"path is outside the captures directory ({root})")
    if not target.is_file():
        return reject("no such file under the captures directory")

    offset = max(0, int(offset or 0))
    length = int(length or READ_CHUNK_MAX)
    # the whole point of the tool: no call may return more than one chunk
    length = max(1, min(length, READ_CHUNK_MAX))
    size = target.stat().st_size
    if offset >= size:
        return {"ok": True, "status": "OK", "path": str(target), "size": size,
                "offset": offset, "length": 0, "base64": None, "eof": True}
    with target.open("rb") as fh:
        fh.seek(offset)
        chunk = fh.read(length)
    end = offset + len(chunk)
    return {"ok": True, "status": "OK", "path": str(target), "size": size,
            "offset": offset, "length": len(chunk),
            "base64": base64.b64encode(chunk).decode("ascii"), "eof": end >= size}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m strategy_cache.mcp_server",
        description="Read-only stdio MCP server for the BuildAlpha strategy cache.",
    )
    parser.add_argument(
        "--db",
        help="absolute path to buildalpha_cache.sqlite3 (or set BA_CACHE_DB)",
    )
    parser.add_argument(
        "--sse",
        action="store_true",
        help="serve over SSE (HTTP) instead of stdio",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="SSE bind address (default 0.0.0.0, reachable on the tailnet)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8080,
        help="SSE port (default 8080)",
    )
    parser.add_argument(
        "--status",
        help=(
            "path to the BuildAlpha status snapshot JSON; defaults to "
            "buildalpha_status.json next to the database (or BA_STATUS_FILE). "
            "The buildalpha_status tool writes it on every live capture."
        ),
    )
    parser.add_argument(
        "--status-timeout",
        type=int,
        default=status_snapshot.DEFAULT_TIMEOUT,
        help=f"live status capture timeout in seconds (default {status_snapshot.DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--allow-actions",
        action="store_true",
        help=(
            "also expose prepare/start/cancel continuous-simulation tools (they "
            "drive BuildAlpha's UI through PowerShell; off by default)"
        ),
    )
    parser.add_argument(
        "--continuous-script",
        default=str(actions.DEFAULT_SCRIPT),
        help=f"path to buildalpha_continuous.ps1 (default {actions.DEFAULT_SCRIPT})",
    )
    parser.add_argument(
        "--log-file",
        default=None,
        help="JSONL run log (one line per tool call); default <db dir>/mcp.log. "
             "Pass an empty string to disable journalling.",
    )
    parser.add_argument(
        "--log-retain", type=int, default=14,
        help="how many rotated run-log files to keep (default 14)",
    )
    parser.add_argument(
        "--log-max-mb", type=int, default=32,
        help="rotate early when the current log passes this size in MB (default 32)",
    )
    parser.add_argument(
        "--log-level", default="info",
        choices=["debug", "info", "warn", "error"],
        help=("info (default) records call start/end plus failures; debug also records one line "
              "per capture stage, so a slow call can be broken down. BA_LOG_LEVEL overrides."),
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    path = resolve_db_path(args.db)
    engine = open_cache(path)
    try:
        status_path = status_snapshot.snapshot_path(path, args.status)
    except status_snapshot.StatusError as exc:
        _fail(f"error: {exc}")

    # Run log: append-only JSONL, rotated daily or at --log-max-mb, keeping
    # --log-retain files. This is what makes a failed call diagnosable afterwards.
    if args.log_file is None:
        log_file = path.parent / "mcp.log"
    elif args.log_file == "":
        log_file = None
    else:
        log_file = Path(args.log_file).expanduser()
    runlog.configure(
        log_file,
        backup_count=args.log_retain,
        max_bytes=max(1, args.log_max_mb) * 1024 * 1024,
        level=args.log_level,
    )
    if log_file:
        log.info("run log: %s (retain %s, rotate at %s MB)", log_file, args.log_retain, args.log_max_mb)

    server = build_server(
        engine,
        path,
        status_path,
        args.status_timeout,
        allow_actions=args.allow_actions,
        continuous_script=Path(args.continuous_script).expanduser(),
    )

    if args.sse:
        # MCPServer uses transport_security=None for a non-localhost host.
        # That keeps a tailnet name such as my-box:8080 reachable.
        _uvicorn_logs_to_stderr()
        log.info(
            "serving %s read-only (schema %s) over SSE at http://%s:%d/sse",
            path,
            EXPECTED_REVISION,
            args.host,
            args.port,
        )
        log.info("status snapshot: %s (present: %s)", status_path, status_path.is_file())
        if args.allow_actions:
            log.warning(
                "ACTION TOOLS ENABLED: prepare/start/cancel continuous simulations "
                "via %s (no authentication on this transport)",
                args.continuous_script,
            )

        global CAPTURE_BASE_URL
        if not CAPTURE_BASE_URL:
            host = os.environ.get("BA_PUBLIC_HOST") or args.host
            if host in ("0.0.0.0", "::", ""):
                host = os.environ.get("BA_PUBLIC_HOST") or _local_ipv4()
            CAPTURE_BASE_URL = f"http://{host}:{args.port}"
        server.run(transport="sse", host=args.host, port=args.port, transport_security=None)
        return 0
    log.info("serving %s read-only (schema %s) over stdio", path, EXPECTED_REVISION)
    log.info("status snapshot: %s (present: %s)", status_path, status_path.is_file())
    server.run(transport="stdio")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
