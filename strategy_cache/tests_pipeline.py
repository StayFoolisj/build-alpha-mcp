"""Contract tests for the strategy cache (run: uv run python -m strategy_cache.tests_pipeline).

Inputs are existing form-reader outputs and grid/re-run captures; temporary
derived captures are written to a scratch directory. BuildAlpha is not touched
(the status test writes a fake snapshot instead of running UI Automation).
"""
from __future__ import annotations

import pathlib

import os
import shutil
import hashlib
import base64
import json
import tempfile as _tempfile
import subprocess
import tempfile
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import text

from . import actions, db, grid_ingest, metrics, parse, queries, schema, status
from .ingest import build_record
from .models import Settings
from .models import ValidationError as SettingsValidationError
from .normalize import compute_tags, normalize_number

ROOT = Path(__file__).resolve().parent.parent
LONG = ROOT / "captures" / "kraken-SOLUSD-15m-Long.txt"
LONG_GRID = ROOT / "captures" / "grid-SOLUSD-15m-Long.txt"
BTC = ROOT / "captures" / "kraken-XXBTZUSD-1h-Long.txt"
BTC_GRID = ROOT / "captures" / "grid-XXBTZUSD-1h-Long.txt"
SCRATCH = Path(tempfile.mkdtemp(prefix="ba_tests_"))


def fresh_engine():
    path = SCRATCH / f"db_{len(list(SCRATCH.glob('db_*.sqlite3')))}.sqlite3"
    os.environ["BA_CACHE_URL"] = f"sqlite:///{path}"
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "migrations"))
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{path}")
    command.upgrade(cfg, "head")
    return db.make_engine(f"sqlite:///{path}")


def ingest(engine, settings: Path, grid: Path | None, *, force_new: bool = False, portfolio: str = "Kraken"):
    built = build_record(str(settings), str(grid) if grid else None)
    with engine.begin() as conn:
        return db.upsert_strategy(
            conn,
            record=built["record"],
            portfolio=portfolio,
            custom_name=built["custom_name"],
            settings=built["settings"].model_dump_json(),
            metrics=built["metrics"],
            force_new=force_new,
        )


def rewrite_field(src: Path, dst: Path, label: str, value: str) -> Path:
    lines = []
    for line in src.read_text(encoding="utf-8").splitlines():
        if line.startswith(label + "\t"):
            parts = line.split("\t")
            parts[1] = value
            line = "\t".join(parts)
        lines.append(line)
    dst.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dst


def drop_field(src: Path, dst: Path, label: str) -> Path:
    lines = [l for l in src.read_text(encoding="utf-8").splitlines() if not l.startswith(label + "\t")]
    dst.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dst


class SkipTest(RuntimeError):
    """A check that needs a host this machine does not provide."""


def require_powershell() -> None:
    """Skip a PowerShell check on a host without it. Windows CI runs these."""
    if shutil.which("powershell") is None:
        raise SkipTest("powershell is not on PATH")


# --------------------------------------------------------------------------- tests
def test_1_reader_twice_same_tag() -> None:
    engine = fresh_engine()
    a = ingest(engine, LONG, LONG_GRID)
    b = ingest(engine, LONG, LONG_GRID)
    assert a["action"] == "insert", a
    assert b["action"] == "update", b
    assert a["tag"] == b["tag"], (a, b)
    with engine.connect() as conn:
        assert conn.execute(text("select count(*) from strategies")).scalar() == 1


def test_2_stop_date_change() -> None:
    engine = fresh_engine()
    base = ingest(engine, LONG, LONG_GRID)
    changed = rewrite_field(LONG, SCRATCH / "long_stopdate.txt", "Stop Date", "7/1/2026 5:00:00 AM")
    other = ingest(engine, changed, LONG_GRID)
    assert other["action"] == "insert", other
    assert other["tag"] != base["tag"], (base["tag"], other["tag"])
    with engine.connect() as conn:
        lh = dict(conn.execute(text("select tag, logical_hash from strategies")).all())
    assert lh[base["tag"]] == lh[other["tag"]], lh


def test_3_identical_rerun_gets_suffix() -> None:
    engine = fresh_engine()
    first = ingest(engine, LONG, LONG_GRID)
    with engine.connect() as conn:
        before = conn.execute(text("select sharpe, net_pnl, settings_json from strategies where tag=:t"), {"t": first["tag"]}).one()
    rerun = ingest(engine, LONG, LONG_GRID, force_new=True)
    assert rerun["tag"] == f"{first['tag']}-2", rerun
    assert rerun["collisions"] >= 1, rerun
    with engine.connect() as conn:
        rows = conn.execute(text("select tag, sharpe, net_pnl, settings_json from strategies order by tag")).all()
        after = conn.execute(text("select sharpe, net_pnl, settings_json from strategies where tag=:t"), {"t": first["tag"]}).one()
    assert len(rows) == 2, rows
    assert tuple(after) == tuple(before), (before, after)          # original untouched
    assert rows[1].sharpe == rows[0].sharpe


def test_4_no_market2_no_custom_name() -> None:
    fields, _, _ = parse.read_form(BTC)
    grid = parse.read_grid(BTC_GRID)
    assert fields.get("Market 2", "").startswith("(none)"), fields.get("Market 2")
    assert parse.split_name_and_rules(grid["Name"])[0] is None
    engine = fresh_engine()
    a = ingest(engine, BTC, BTC_GRID)
    b = ingest(engine, BTC, BTC_GRID)
    assert a["tag"] == b["tag"], (a, b)
    with engine.connect() as conn:
        assert conn.execute(text("select count(*) from strategies")).scalar() == 1


def test_5_commission_float_noise() -> None:
    assert normalize_number("0.0015999999595806") == normalize_number("0.0016") == "0.0016"
    engine = fresh_engine()
    raw = rewrite_field(LONG, SCRATCH / "long_commission_raw.txt",
                        "Commission (market currency)", "0.0015999999595806")
    clean = rewrite_field(LONG, SCRATCH / "long_commission_clean.txt",
                          "Commission (market currency)", "0.0016")
    a = ingest(engine, raw, LONG_GRID)
    b = ingest(engine, clean, LONG_GRID)
    assert a["tag"] == b["tag"], (a, b)
    assert a["action"] == "insert" and b["action"] == "update", (a, b)


def test_6_validation_rejects_missing_symbol() -> None:
    engine = fresh_engine()
    bad = rewrite_field(LONG, SCRATCH / "long_bad_symbol.txt", "Symbols", "")
    bad_grid = drop_field(LONG_GRID, SCRATCH / "long_bad_symbol_grid.txt", "Symbol")
    try:
        ingest(engine, bad, bad_grid)
    except SettingsValidationError:
        pass
    else:
        raise AssertionError("expected a ValidationError for an empty symbol")
    with engine.connect() as conn:
        assert conn.execute(text("select count(*) from strategies")).scalar() == 0


def test_7_settings_json_is_validated_model_dump() -> None:
    engine = fresh_engine()
    ingest(engine, LONG, LONG_GRID)
    with engine.connect() as conn:
        raw = conn.execute(text("select settings_json from strategies")).scalar()
    stored = Settings.from_json(raw)          # typed access, no re-validation on read
    assert stored.symbol == "SOLUSD|15m"
    assert stored.start_date == "2023-12-31"  # normalised, not raw 12/31/2023 5:00:00 PM
    assert stored.costs.startswith("commission_mode=")
    assert "Target currency" in stored.model_extra   # extra fields preserved


def test_8_cache_stats() -> None:
    engine = fresh_engine()
    ingest(engine, LONG, LONG_GRID)
    with engine.connect() as conn:
        stats = queries.cache_stats(conn)
    assert stats["rows"] == 1, stats
    assert stats["schema_revision"] == "0003", stats
    # dimensions come from the ever-seen ledger ...
    assert stats["portfolios"] == [
        {"portfolio": "Kraken", "count": 1, "last_seen": stats["portfolios"][0]["last_seen"]}
    ], stats
    # ... while a single-strategy form capture creates no portfolio snapshot
    assert stats["portfolios_current"] == [], stats
    assert stats["symbols"] == [{"value": "SOLUSD|15m", "count": 1}], stats
    assert stats["strategy_types"] == [{"value": "Long", "count": 1}], stats
    assert stats["logical_families"] == 1, stats
    assert stats["variant_hashes"] == 1, stats
    assert stats["largest_family"] == 1, stats


def test_9_metric_glossary_matches_schema() -> None:
    described = metrics.describe()
    assert len(described) == 26, len(described)
    assert metrics.names() == tuple(schema.METRIC_COLUMNS), metrics.names()
    for metric in described:
        assert metric["label"], metric
        assert metric["unit"], metric
        assert metric["direction"] in {"higher", "lower", "neutral"}, metric
        assert metric["group"], metric


def test_10_status_snapshot_annotation() -> None:
    target = SCRATCH / "status.json"
    try:
        status.read(target)
    except status.StatusError as exc:
        assert "capture" in str(exc)
    else:  # pragma: no cover - guard against a silent regression
        raise AssertionError("missing snapshot should raise StatusError")

    fresh = (datetime.now(timezone.utc) - timedelta(seconds=5)).isoformat(timespec="seconds")
    target.write_text(json.dumps({"running": True, "captured_at": fresh}), encoding="utf-8")
    got = status.read(target)
    assert got["stale"] is False and got["age_seconds"] is not None, got

    old = (datetime.now(timezone.utc) - timedelta(seconds=status.STALE_AFTER_SECONDS + 60)).isoformat(timespec="seconds")
    target.write_text(json.dumps({"running": False, "captured_at": old}), encoding="utf-8")
    assert status.read(target)["stale"] is True

    # PowerShell noise around the JSON must not break the capture parser
    assert status._parse('WARNING: nothing\n{"running": false}\n') == {"running": False}


def test_11_live_status_and_fallback() -> None:
    target = SCRATCH / "live_status.json"
    stamp = (datetime.now(timezone.utc) - timedelta(seconds=3)).isoformat(timespec="seconds")
    target.write_text(json.dumps({"running": True, "captured_at": stamp}), encoding="utf-8")

    def fake_capture(path, timeout=0):
        return {"running": True, "active_job": True, "captured_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}

    live = status.latest(target, live=True, capture_fn=fake_capture)
    assert live["mode"] == "live", live
    assert live["stale"] is False and live["age_seconds"] == 0, live

    def broken_capture(path, timeout=0):
        raise status.StatusError("powershell missing")

    fallback = status.latest(target, live=True, capture_fn=broken_capture)
    assert fallback["mode"] == "cached", fallback
    assert fallback["capture_error"] == "powershell missing", fallback
    assert fallback["running"] is True, fallback

    cached = status.latest(target, live=False, capture_fn=broken_capture)
    assert cached["mode"] == "cached" and "capture_error" not in cached, cached


def test_12_job_lifecycle_summary() -> None:
    now = datetime.now(timezone.utc)
    local = lambda seconds_ago: (now - timedelta(seconds=seconds_ago)).astimezone().strftime("%Y-%m-%d %H:%M:%S")  # noqa: E731
    iso = lambda seconds_ago: (now - timedelta(seconds=seconds_ago)).isoformat(timespec="seconds")  # noqa: E731
    path = SCRATCH / "lifecycle.json"

    # running: "running for 1h 00m"
    running = status._annotate(
        {"state": "running", "job_started": local(3600), "captured_at": iso(0)}, path, "live", []
    )["job"]
    assert running["state"] == "running", running
    assert running["summary"].startswith("running for 1h"), running
    assert 3580 <= running["duration_seconds"] <= 3620, running

    # stopped via STOP -> exact end from the app.log marker
    stopped = status._annotate(
        {"state": "results-open", "job_started": local(7200),
         "job_stop_marker": local(1800), "captured_at": iso(0)},
        path, "live", [],
    )["job"]
    assert stopped["ended_source"] == "log", stopped
    assert stopped["summary"].startswith("completed 30m ago"), stopped

    # finished on its own: end observed between two captures
    started = local(3600)
    history = [
        {"captured_at": iso(1200), "active_job": True, "state": "running", "job_started": started},
        {"captured_at": iso(900), "active_job": False, "state": "results-open", "job_started": started},
    ]
    observed = status._annotate(
        {"state": "results-open", "job_started": started, "captured_at": iso(0)}, path, "cached", history
    )["job"]
    assert observed["ended_source"] == "observed", observed
    assert observed["summary"].startswith("completed 15m ago"), observed
    assert observed["seen_between"] and len(observed["seen_between"]) == 2, observed

    # first ever sighting after the fact: honest, no fake timestamp
    single = status._annotate(
        {"state": "results-open", "job_started": started, "captured_at": iso(0)},
        path, "cached",
        [{"captured_at": iso(0), "active_job": False, "state": "results-open", "job_started": started}],
    )["job"]
    assert single["ended_source"] == "single", single
    assert "not running at" in single["summary"], single


def test_13_grid_ingest_snapshot() -> None:
    engine = fresh_engine()
    grid = SCRATCH / "grid_sample.tsv"
    lines = [
        "# top_level=3 grid_rows=3",
        "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe",
        "1\trsi(close,14)[0] > 50\t@ES_1h\tLong\tPT 2.00 atr\t100\t1.50",
        "2\tMy favourite\tBSK_1h\tShort\tSL 3.00 atr\t7\t0.10",
        "3\t\t@ES_1h\tLong\t\t1\t0.00",
    ]
    grid.write_text("\n".join(lines) + "\n", encoding="utf-8")

    rows, meta = grid_ingest.read_grid(grid)
    assert len(rows) == 3 and meta["top_level"] == "3", meta
    stats = grid_ingest.ingest(engine, rows, "Common Portfolio")
    assert stats["insert"] == 2 and stats["skipped"] == 1, stats

    with engine.connect() as conn:
        stored = conn.execute(
            text("SELECT symbol, strategy_type, entry_rules, custom_name, sharpe FROM strategies ORDER BY symbol")
        ).mappings().all()
    assert [r["symbol"] for r in stored] == ["@ES|1h", "BSK|1h"], stored
    assert stored[0]["entry_rules"].startswith("rsi(") and stored[0]["custom_name"] is None
    assert stored[1]["custom_name"] == "My favourite" and stored[1]["entry_rules"] == ""

    # a re-scan refreshes metrics of grid-sourced rows (snapshot semantics)
    rescanned = [dict(row) for row in rows]
    rescanned[0]["Sharpe"] = "9.99"
    stats2 = grid_ingest.ingest(engine, rescanned, "Common Portfolio")
    assert stats2["refresh"] == 2 and stats2["insert"] == 0, stats2
    with engine.connect() as conn:
        assert conn.execute(text("SELECT sharpe FROM strategies WHERE symbol = '@ES|1h'")).scalar() == 9.99


def test_14_query_strategies() -> None:
    engine = fresh_engine()
    grid = SCRATCH / "grid_query.tsv"
    lines = [
        "# top_level=3 grid_rows=3",
        "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe\tNet P&L\tDrawdown",
        "1\trsi(close,14)[0] > 50\t@ES_1h\tLong\tPT 2.00 atr\t100\t2.50\t5000\t100",
        "2\trsi(close,14)[0] > 70\t@ES_1h\tShort\tPT 2.00 atr\t80\t1.20\t3000\t200",
        "3\tMy label\tBSK_1h\tLong\tSL 3.00 atr\t40\t0.40\t100\t900",
    ]
    grid.write_text("\n".join(lines) + "\n", encoding="utf-8")
    rows, _ = grid_ingest.read_grid(grid)
    grid_ingest.ingest(engine, rows, "Common Portfolio")

    with engine.connect() as conn:
        page = queries.query_strategies(conn, min_metrics={"sharpe": 1.0}, limit=1, offset=0)
        assert page["total"] == 2 and len(page["rows"]) == 1, page
        assert page["rows"][0]["sharpe"] == 2.5, page

        second = queries.query_strategies(conn, min_metrics={"sharpe": 1.0}, limit=1, offset=1)
        assert second["rows"][0]["sharpe"] == 1.2 and second["total"] == 2, second

        by_symbol = queries.query_strategies(conn, symbol="@ES")
        assert by_symbol["total"] == 2, by_symbol
        exact = queries.query_strategies(conn, symbol="BSK|1h")
        assert exact["total"] == 1 and exact["rows"][0]["custom_name"] == "My label"

        named = queries.query_strategies(conn, name_contains="rsi(close,14)")
        assert named["total"] == 2, named
        both = queries.query_strategies(conn, name_contains="rsi", strategy_type="short")
        assert both["total"] == 1 and both["rows"][0]["strategy_type"] == "Short"

        capped = queries.query_strategies(conn, max_metrics={"drawdown": 500}, sort="drawdown", order="asc")
        assert capped["total"] == 2 and capped["rows"][0]["drawdown"] == 100, capped

        clamped = queries.query_strategies(conn, limit=99999)
        assert clamped["limit"] == queries.MAX_LIMIT, clamped

        for kwargs in ({"sort": "evil; drop table strategies"}, {"min_metrics": {"nope": 1}}):
            try:
                queries.query_strategies(conn, **kwargs)
            except ValueError:
                pass
            else:  # pragma: no cover
                raise AssertionError(f"expected ValueError for {kwargs}")


def test_15_action_summary() -> None:
    import subprocess

    def proc(stdout: str, code: int = 0, stderr: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(args=[], returncode=code, stdout=stdout, stderr=stderr)

    ok = actions.summarize(
        "prepare",
        proc(
            "PREPARED symbol=BTC-USDT timeframe=1 hour start=10/18/2024 stop=10/18/2026\n"
            "--- settings read back ---\n"
            "  Symbols = BTC-USDT (1 hour)\n"
            "  Start Date = 10/18/2024 12:00:00 AM\n"
            "pending: C:\\tmp\\continuous-pending.json\n"
        ),
    )
    assert ok["ok"] is True and ok["status"] == "PREPARED", ok
    assert ok["settings"]["Symbols"] == "BTC-USDT (1 hour)", ok
    assert ok["settings"]["Start Date"] == "10/18/2024 12:00:00 AM", ok

    refused = actions.summarize(
        "start",
        proc(
            "prepare wanted: BTC-USDT 1 hour 10/18/2024 -> 10/18/2026\n"
            "form now     : BTC-USDT (1 hour) | 10/18/2025 12:00:00 AM -> 10/18/2026\n"
            "REFUSING start: start date drifted (use -Force to override)\n",
            code=10,
        ),
    )
    assert refused["ok"] is False and refused["status"] == "REFUSING", refused
    assert refused["message"].startswith("REFUSING start"), refused

    failed = actions.summarize("prepare", proc("SYMBOL_FAILED symbol 'X' not found\n", code=6))
    assert failed["ok"] is False and failed["status"] == "SYMBOL_FAILED", failed

    dry = actions.summarize("start", proc("DRY_RUN verified, not clicking Continuous simulation\n"))
    assert dry["ok"] is True and dry["status"] == "DRY_RUN", dry

    filtered = actions.summarize("prepare", proc("FILTER_FAILED filter 'Nope' not found; available: Basic, Noise\n", code=14))
    assert filtered["ok"] is False and filtered["status"] == "FILTER_FAILED", filtered


def test_16_list_filters_parsing(temp_pending=None) -> None:
    import subprocess

    fake = "FILTERS count=3\nFILTER\tBasic\tselected\nFILTER\tNoise\t\nFILTER\tVariance\t\n"
    proc = subprocess.CompletedProcess(args=[], returncode=0, stdout=fake, stderr="")
    result = actions.summarize("filters", proc)
    # the verdict must be 'FILTERS', not the 'FILTER<TAB>...' rows
    assert result["ok"] is True and result["status"] == "FILTERS", result

    # PowerShell writes the pending file with a BOM
    pending = SCRATCH / "pending_bom.json"
    pending.write_bytes("\ufeff".encode("utf-8") + b'{"filter": "Noise", "symbol": "ETH-USDT"}')
    pref = actions.summarize("prepare", proc, pending)
    assert pref["pending"]["filter"] == "Noise", pref
    assert "pending_error" not in pref, pref


def test_17_stop_summary() -> None:
    import subprocess

    proc = subprocess.CompletedProcess(
        args=[], returncode=0,
        stdout="STOPPED total=1234 title='Continuous Simulation results - ETH-USDT_1h (Long)'\n",
        stderr="",
    )
    result = actions.summarize("stop", proc)
    match = __import__("re").search(r"\btotal=(-?\d+)", proc.stdout)
    assert result["ok"] is True and result["status"] == "STOPPED", result
    assert match and int(match.group(1)) == 1234

    idle = actions.summarize("stop", subprocess.CompletedProcess(args=[], returncode=16, stdout="NOT_RUNNING\n", stderr=""))
    assert idle["ok"] is False and idle["status"] == "NOT_RUNNING", idle


def test_18_filter_summary() -> None:
    import subprocess

    proc = subprocess.CompletedProcess(
        args=[], returncode=0,
        stdout="FILTERED filter='RobustAll' before=34 after=1 expression='[P&L / DD] > 1.5 And [Trades] >= 40'\n",
        stderr="",
    )
    r = actions._summarize_filter("apply", proc)
    assert r["ok"] is True and r["status"] == "FILTERED", r
    assert (r["before"], r["after"], r["changed"]) == (34, 1, True), r
    assert r["filter"] == "RobustAll" and "[Trades] >= 40" in r["expression"], r

    show = subprocess.CompletedProcess(args=[], returncode=0, stdout="RESULTS total=1 expression='[Trades] >= 40'\n", stderr="")
    s = actions._summarize_filter("show", show)
    assert s["ok"] is True and s["results_total"] == 1, s

    bad = subprocess.CompletedProcess(args=[], returncode=5, stdout="FILTER_NOT_FOUND 'Nope'\n", stderr="")
    b = actions._summarize_filter("apply", bad)
    assert b["ok"] is False and b["status"] == "FILTER_NOT_FOUND", b


def test_19_portfolio_membership() -> None:
    """A strategy listed in two portfolios keeps both locations (many-to-many)."""
    engine = fresh_engine()
    grid = SCRATCH / "grid_membership.tsv"
    lines = [
        "# top_level=2 grid_rows=2",
        "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe",
        "1\trsi(close,14)[0] > 50\t@ES_1h\tLong\tPT 2.00 atr\t100\t1.50",
        "2\tema(close,20)[0] > 0\tBSK_1h\tShort\tSL 3.00 atr\t7\t0.10",
    ]
    grid.write_text("\n".join(lines) + "\n", encoding="utf-8")
    rows, _ = grid_ingest.read_grid(grid)

    grid_ingest.ingest(engine, rows, "Common Portfolio", home=True)
    grid_ingest.ingest(engine, rows[:1], "Hyperliquid #2")   # one shared strategy

    with engine.connect() as conn:
        ports = {r["portfolio"]: r["count"] for r in queries.list_portfolios(conn)}
        assert ports == {"Common Portfolio": 2, "Hyperliquid #2": 1}, ports

        subset = queries.query_strategies(conn, portfolio="Hyperliquid #2")
        assert subset["total"] == 1, subset
        assert subset["rows"][0]["portfolios"] == ["Common Portfolio", "Hyperliquid #2"], subset

        # the home column is not stolen by the smaller portfolio
        homes = set(conn.execute(text("SELECT DISTINCT portfolio FROM strategies")).scalars())
        assert homes == {"Common Portfolio"}, homes

        # re-scanning the same portfolio is idempotent
        grid_ingest.ingest(engine, rows, "Common Portfolio")
        assert conn.execute(text("SELECT COUNT(*) FROM strategy_portfolios")).scalar() == 3


def test_20_portfolio_sweep_names() -> None:
    from . import portfolio_sweep

    assert portfolio_sweep.slug("Hyperliquid #2") == "hyperliquid-2"
    assert portfolio_sweep.slug("Thai SET") == "thai-set"
    assert portfolio_sweep.capture_name("2010") == "grid-rows-2010.txt"
    assert "Common Portfolio" not in portfolio_sweep.DEFAULT_PORTFOLIOS
    assert len(portfolio_sweep.ALL_PORTFOLIOS) == 10


def test_22_rerun_resolution() -> None:
    """resolve() turns a tag into the exact row identity; no caller search text."""
    from . import rerun_adjust

    engine = fresh_engine()
    grid = SCRATCH / "grid_hype.tsv"
    lines = [
        "# top_level=2 grid_rows=2",
        "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe\tNet P&L",
        "1\tlow[0] > EMA(close,12)[0], DownRange(1,0) = 1\tHYPE-USDT_1h\tLong\tPT 8.00 atr\t258\t2.39\t133606.25",
        "2\thype-mr-short vsShift: med\tHYPE-USDT_1h\tShort\tPT 6.00 atr\t123\t2.75\t71143.52",
    ]
    grid.write_text("\n".join(lines) + "\n", encoding="utf-8")
    rows, _ = grid_ingest.read_grid(grid)
    stats = grid_ingest.ingest(engine, rows, "Hyperliquid #2")
    assert stats["insert"] == 2, stats

    with engine.connect() as conn:
        tags = [r["tag"] for r in queries.list_strategies(conn, portfolio="Hyperliquid #2")]
        unnamed = next(t for t in tags if queries.get_strategy(conn, t)["custom_name"] is None)
        resolved = rerun_adjust.resolve(conn, unnamed, "Hyperliquid #2")
        assert resolved["name"].startswith("low[0]"), resolved
        assert resolved["symbol"] == "HYPE-USDT", resolved
        assert resolved["expected"]["trades"] == 258, resolved
        assert resolved["expected"]["sharpe"] == 2.39, resolved

        named_tag = next(t for t in tags if queries.get_strategy(conn, t)["custom_name"])
        named = rerun_adjust.resolve(conn, named_tag)
        assert named["name"] == "hype-mr-short vsShift: med", named
        assert named["portfolio"] == "Hyperliquid #2", named  # defaulted from membership

        try:
            rerun_adjust.resolve(conn, "nosuchtag")
        except rerun_adjust.AdjustError:
            pass
        else:
            raise AssertionError("unknown tag accepted")

        try:
            rerun_adjust.resolve(conn, unnamed, "Kraken")
        except rerun_adjust.AdjustError as exc:
            assert "not in" in str(exc), exc
        else:
            raise AssertionError("portfolio without membership accepted")

    # identity guard: the script's own exit code maps to a status
    mismatch = subprocess.CompletedProcess(
        args=[], returncode=20, stderr="",
        stdout="IDENTITY_MISMATCH trades expected=258 actual=135\n",
    )
    s = rerun_adjust.summarize(mismatch)
    assert s["ok"] is False and s["status"] == "IDENTITY_MISMATCH", s


def test_23_settings_script() -> None:
    """The Settings window helper exposes the documented actions and markers."""
    path = ROOT / "scripts" / "buildalpha_settings.ps1"
    text = path.read_text(encoding="utf-8")
    assert "ValidateSet('open', 'close', 'status')" in text
    for marker in ("STATE_OPEN", "STATE_CLOSED", "OPENED hwnd=", "CLOSED ms=",
                   "ALREADY_OPEN", "ALREADY_CLOSED", "F8_NOT_REGISTERED",
                   "PROMPT title=", "via=f8", "f8-after-click", "click-then-f8"):
        assert marker in text, marker
    # F8 must be the first attempt, with the row click only as a fallback
    f8 = text.index("Send-F8")
    click = text.index("Focus-PortfolioGrid $main $proc", text.index("'open' {") if "'open' {" in text else f8)
    assert f8 < click, "F8 must be tried before clicking the grid"
    # the symbol grid is the reason this window matters: 18 columns incl. Filename
    assert "GridPattern" in text and "symbol_grid rows=" in text


def test_24_symbol_lookup_script() -> None:
    """Symbol lookup: the verdict vocabulary, exit codes and the debounce wait."""
    text = (ROOT / "scripts" / "buildalpha_symbol_lookup.ps1").read_text(encoding="utf-8")
    for marker in ("FOUND_EXACT", "AMBIGUOUS", "NAME_MISMATCH", "NOT_FOUND",
                   "Wait-FilterChange", "ValuePattern", "search_restored",
                   "candidate:", "SEARCH_NOT_APPLIED"):
        assert marker in text, marker
    # exit codes are the contract callers rely on
    for pair in (("FOUND_EXACT", 0), ("NOT_FOUND", 3), ("AMBIGUOUS", 4), ("NAME_MISMATCH", 5)):
        assert f"$status = '{pair[0]}'; $code = {pair[1]}" in text, pair
    # the find panel debounces (~1.2 s); waiting for a change is what makes it work
    assert "changedAt" in text and "settle" in text.lower()
    # a query must never be trusted from the echo alone
    assert "echo -ne $Symbol" in text


def test_25_symbol_cell_script() -> None:
    """The Symbols cell writer: guards, editor detection and outcome vocabulary."""
    text = (ROOT / "scripts" / "buildalpha_symbol_cell.ps1").read_text(encoding="utf-8")
    for marker in ("CELL_READ", "CELL_WRITE", "SEARCH_RESTORED", "DRY_RUN",
                   "SYMBOL_NOT_FOUND", "AMBIGUOUS", "NO_SUCH_COLUMN",
                   "COLUMN_NOT_VISIBLE", "WRONG_CELL", "VERIFY_MISMATCH",
                   "Leave-CellEditor", "Get-SearchValue"):
        assert marker in text, marker
    # an editor must be confirmed open before any key is sent, for BOTH editor kinds
    assert "'^(TextEdit|ButtonEdit)'" in text
    assert "^a" in text and "{DELETE}" in text
    # the wrong write must be impossible: identity is verified before touching a cell
    assert "Read-Row1Name" in text and "$rowName -ne $Symbol" in text
    # a failed write must never report success
    assert "if ($after -ne $Value) { exit 5 }" in text
    # -Clear exists because an empty -Value cannot survive -File argument parsing
    assert "[switch]$Clear" in text and "if ($Clear) { $Value = '' }" in text


def test_26_rerun_date_window() -> None:
    """Date-window overrides are plumbed to the script and mapped to a status."""
    from . import rerun_adjust

    args = rerun_adjust.build_args(
        filter="BTC-USDT", expect_symbol="BTC",
        symbol={"kind": "builtin", "name": "BTC", "timeframe": "1h"},
        dry_run=True, start_date="1/1/2024", stop_date="10/22/2026",
    )
    assert "-StartDate" in args and "1/1/2024" in args, args
    assert "-StopDate" in args and "10/22/2026" in args, args
    # omitted dates must not appear at all
    plain = rerun_adjust.build_args(
        filter="BTC-USDT", expect_symbol="BTC", symbol=None, dry_run=True,
    )
    assert "-StartDate" not in plain and "-StopDate" not in plain, plain
    assert rerun_adjust.STATUS_BY_EXIT[21] == "DATE_NOT_APPLIED"

    script = (ROOT / "scripts" / "buildalpha_rerun_adjust.ps1").read_text(encoding="utf-8")
    # the date must be verified against what the form reads back, and must abort if not
    assert "Set-FormDate" in script
    assert "DATE_NOT_APPLIED" in script
    assert "Stop-With \"DATE_NOT_APPLIED" in script and "21 }" in script
    assert "$StartDate" in script and "$StopDate" in script
    assert "'Start Date'" in script and "'Stop Date'" in script
    # focus change commits a DateEdit; Enter would risk the form's default button
    assert "Send-Keys '{TAB}'" in script
    # and the key must go through the guarded wrapper, never straight to SendWait
    assert "[System.Windows.Forms.SendKeys]::SendWait" not in script
    assert "function Test-InjectionAllowed" in (ROOT / "scripts" / "buildalpha_uia.ps1").read_text(encoding="utf-8")
    assert rerun_adjust.STATUS_BY_EXIT[25] == "INPUT_BLOCKED"


def test_27_deleted_strategy_is_not_current() -> None:
    """A strategy deleted from a portfolio leaves the newest snapshot, not the cache."""
    from . import db, grid_ingest

    engine = fresh_engine()
    grid = SCRATCH / "grid_snapshots.tsv"
    header = ("# top_level=3 grid_rows={n}\n"
              "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe\tNet P&L\n")

    def write(rows: list[str], grid_rows: int) -> Path:
        grid.write_text(header.format(n=grid_rows) + "\n".join(rows) + "\n", encoding="utf-8")
        return grid

    a = "1\tlow[0] > EMA(close,12)[0]\tAAA_1h\tLong\tPT 2.00 atr\t100\t1.50\t1000.00"
    b = "2\thigh[0] < EMA(close,12)[0]\tBBB_1h\tShort\tPT 2.00 atr\t80\t1.10\t800.00"
    c = "3\tclose[0] > open[0]\tCCC_1h\tLong\tPT 3.00 atr\t60\t0.90\t600.00"

    # scan 1: three strategies listed in the portfolio
    rows, meta = grid_ingest.read_grid(write([a, b, c], 3))
    s1 = grid_ingest.ingest(engine, rows, "Test Port", grid_rows=meta.get("grid_rows", 3))
    with engine.connect() as conn:
        assert s1["scan"]["ok"] == 1, s1
        assert len(queries.list_strategies(conn, "Test Port")) == 3
        tags = {r["symbol"]: r["tag"] for r in queries.list_strategies(conn, "Test Port")}
        gone = tags["BBB|1h"]

    # scan 2: BBB was deleted in BuildAlpha, so it is simply absent
    rows2, meta2 = grid_ingest.read_grid(write([a, c], 2))
    s2 = grid_ingest.ingest(engine, rows2, "Test Port", grid_rows=meta2.get("grid_rows", 2))
    assert s2["scan"]["id"] != s1["scan"]["id"], (s1, s2)

    with engine.connect() as conn:
        current = queries.list_strategies(conn, "Test Port")
        assert {r["symbol"] for r in current} == {"AAA|1h", "CCC|1h"}, current

        # ... but nothing is lost: the ledger still knows it, and history is intact
        ever = queries.list_strategies(conn, "Test Port", include_removed=True)
        assert {r["symbol"] for r in ever} == {"AAA|1h", "BBB|1h", "CCC|1h"}, ever

        diff = db.scan_diff(conn, "Test Port", s1["scan"]["id"], s2["scan"]["id"])
        assert diff["removed"] == [gone], diff
        assert diff["added"] == [], diff
        assert diff["common"] == 2, diff

        hist = {h["portfolio"]: h for h in db.strategy_history(conn, gone)}
        assert hist["Test Port"]["present"] is False, hist
        assert hist["Test Port"]["last_scan"] == s1["scan"]["id"], hist

        # the row itself (metrics, identity) survives the deletion
        rec = queries.get_strategy(conn, gone)
        assert rec is not None and rec["symbol"] == "BBB|1h", rec

        # a truncated capture must NOT look like a deletion
        bad_grid = SCRATCH / "grid_bad.tsv"
        bad_grid.write_text(header.format(n=2) + a + "\n", encoding="utf-8")
        rows3, _ = grid_ingest.read_grid(bad_grid)
        s3 = grid_ingest.ingest(engine, rows3, "Test Port", grid_rows=2)
        assert s3["scan"]["ok"] == 0, s3
    with engine.connect() as conn:
        still = queries.list_strategies(conn, "Test Port")
        assert {r["symbol"] for r in still} == {"AAA|1h", "CCC|1h"}, still   # unchanged

        # retention keeps the first scan (diff baseline) plus the newest N
        kept = db.prune_scans(conn, "Test Port", keep=2)
        assert kept["removed_scans"] == 0, kept


def test_28_runlog() -> None:
    """The JSONL run log: capping, compaction, recovery and retention."""
    import json as _json

    from . import runlog

    log = SCRATCH / "mcp_runlog_test.log"
    # clear rotated backups too: they survive between suite runs and a 4 KB rotation
    # would otherwise leak records from an earlier run into this one
    for stale in SCRATCH.glob(log.name + "*"):
        stale.unlink()
    runlog.configure(log, backup_count=2, max_bytes=4096)

    # a mutating call: full payload, capped stdout
    big = "x" * (runlog.FIELD_CAP + 50)
    runlog.record_start("rerun_with_adjustments", {"tag": "t1"}, tag="t1")
    runlog.attach(stdout=big)
    rec = runlog.record_finish(
        runlog.record_start("rerun_with_adjustments", {"tag": "t1"}, tag="t1"),
        "rerun_with_adjustments", {"tag": "t1"}, tag="t1", status="COMPLETED",
        exit_code=0, duration_ms=1234.5, result={"baseline": {"Trades": "347"}, "results": {}},
    )
    assert rec["stdout_truncated"] is True and rec["stdout_bytes"] == len(big), rec
    assert len(rec["stdout"]) == runlog.FIELD_CAP, len(rec["stdout"])
    assert rec["result"]["baseline"]["Trades"] == "347", rec  # full for actions

    # a read-only success is compacted
    rows = [{"tag": f"r{i}", "sharpe": i} for i in range(50)]
    runlog.record_finish(
        runlog.record_start("query_strategies", {}, tag=None),
        "query_strategies", {}, tag=None, status="OK", result={"total": 50, "rows": rows},
    )
    # a failure keeps its payload even for a read-only tool
    runlog.record_finish(
        runlog.record_start("get_strategy", {"tag": "missing"}, tag="missing"),
        "get_strategy", {"tag": "missing"}, tag="missing", status="TOOL_ERROR",
        error="strategy 'missing' not found",
    )

    # read via the explicit path: the module-level path is process state and other tests
    # may have pointed it elsewhere, which is not what this assertion is about
    mem = runlog.last_result("t1", path=log)["record"]
    assert mem and mem["status"] == "COMPLETED", mem

    # file-based recovery (fresh process would have no memory)
    from_file = runlog.last_result("t1", path=log)["record"]
    assert from_file and from_file["result"]["baseline"]["Trades"] == "347", from_file

    # filtering
    errors = runlog.recent(limit=5, path=log, status="TOOL_ERROR")
    assert errors and errors[0]["tag"] == "missing", errors
    queried = runlog.recent(limit=5, path=log, tool="query_strategies")
    assert queried and queried[0]["result"].get("compacted") is True, queried

    # the file is JSONL: every line parses
    for line in log.read_text(encoding="utf-8").splitlines():
        _json.loads(line)

    # size rotation keeps the retained backups bounded (max_bytes=4096, backup_count=2)
    for _ in range(40):
        runlog.record_finish(
            runlog.record_start("cache_stats", {}, tag=None), "cache_stats", {},
            tag=None, status="OK", result={"rows": 431},
        )
    files = sorted(p.name for p in log.parent.glob(log.name + "*"))
    assert 1 < len(files) <= 3, files  # rotated, and retention applied


def test_29_windows_and_form_failed() -> None:
    """windows_cleaned follows the observed list; a thrown form read is its own status."""
    import subprocess

    from . import rerun_adjust

    ok = 'WINDOWS ["Build Alpha"]\nCLEANED_UP\nDRY_RUN {"a": 1}\n'
    s = rerun_adjust.summarize(subprocess.CompletedProcess(args=[], returncode=0, stderr="", stdout=ok))
    assert s["windows"] == ["Build Alpha"] and s["windows_cleaned"] is True, s

    leftover = 'ROW_NOT_FOUND x\nWINDOWS ["Build Alpha", "Re-Run"]\n'
    s2 = rerun_adjust.summarize(subprocess.CompletedProcess(args=[], returncode=6, stderr="", stdout=leftover))
    assert s2["windows_cleaned"] is False, s2

    failed = 'FORM_READ_FAILED picker scan: Cannot convert value\nWINDOWS ["Build Alpha"]\nCLEANED_UP\n'
    s3 = rerun_adjust.summarize(subprocess.CompletedProcess(args=[], returncode=22, stderr="boom", stdout=failed))
    assert s3["status"] == "FORM_READ_FAILED" and s3["windows_cleaned"] is True, s3

    # exit 1 is an unhandled PowerShell exception, never a missing-symbol report
    assert rerun_adjust.STATUS_BY_EXIT[1] == "SCRIPT_FAILED"
    assert rerun_adjust.STATUS_BY_EXIT[23] == "NEW_SYMBOL_REQUIRED"

    script = (ROOT / "scripts" / "buildalpha_rerun_adjust.ps1").read_text(encoding="utf-8")
    assert "function Get-ElementTop" in script
    assert "FORM_READ_FAILED picker scan" in script
    assert "exit 23" in script


def test_30_journal_semantics_and_jobs() -> None:
    """A lookup never shadows the run it looks up, a dry run never outranks a real
    one, and a slow call can be handed off instead of blocking."""
    import time as _time

    from . import jobs, runlog

    assert {"get_last_result", "recent_runs", "rerun_with_adjustments"} <= runlog.NO_JOURNAL

    log = SCRATCH / "mcp_journal_semantics.log"
    for stale in SCRATCH.glob(log.name + "*"):
        stale.unlink()
    runlog.configure(log, backup_count=2, max_bytes=1 << 20)
    args_real = {"tag": "tg", "dry_run": False}
    args_dry = {"tag": "tg", "dry_run": True}

    # a dry run, then a real run still in flight (start only)
    runlog.record_finish(runlog.record_start("rerun_with_adjustments", args_dry, tag="tg"),
                         "rerun_with_adjustments", args_dry, tag="tg", status="DRY_RUN")
    runlog.record_start("rerun_with_adjustments", args_real, tag="tg")

    found = runlog.last_result("tg", path=log)
    assert found["record"] is None, found            # the dry run is not served as the run
    assert found["in_flight"] is not None, found      # ... but the caller learns it is running
    assert found["dry_run_record"]["status"] == "DRY_RUN", found
    assert runlog.last_result("tg", path=log, include_dry_run=True)["record"]["status"] == "DRY_RUN"

    # once the real run finishes it wins, and the dry run is still available
    runlog.record_finish(({"event": "x"} and "rid-real"),
                         "rerun_with_adjustments", args_real, tag="tg", status="COMPLETED")
    found = runlog.last_result("tg", path=log)
    assert found["record"]["status"] == "COMPLETED", found
    assert found["dry_run_record"]["status"] == "DRY_RUN", found

    # every run for a tag is recoverable (a later run must not hide the earlier one)
    all_runs = runlog.recent(limit=10, tag="tg", path=log)
    assert {r["status"] for r in all_runs} == {"DRY_RUN", "COMPLETED"}, all_runs

    # jobs: hand off a slow call, then collect it
    started = _time.perf_counter()
    job = jobs.start("slow", lambda: (_time.sleep(0.4), {"ok": True})[1])
    assert job.wait(0.05) is False, "wait returned early"
    assert (_time.perf_counter() - started) < 0.35, "wait() blocked for the full run"
    try:
        jobs.start("second", lambda: None)
    except jobs.Busy as busy:
        assert busy.job.id == job.id, busy
    else:
        raise AssertionError("a second concurrent BuildAlpha job was allowed")
    assert job.wait(5) is True and job.result == {"ok": True}, job.state()
    assert jobs.get(job.id) is job
    assert not jobs.active(), jobs.active()


def test_21_rerun_adjust_parsing() -> None:
    import subprocess

    from . import rerun_adjust

    args = rerun_adjust.build_args(
        "btc-trend-short", "BTC", {"kind": "builtin", "name": "BTC", "timeframe": "1h"}, True
    )
    assert args[:4] == ["-Filter", "btc-trend-short", "-ExpectSymbol", "BTC"], args
    assert "-DryRun" in args and args[args.index("-SymbolKind") + 1] == "builtin", args

    args2 = rerun_adjust.build_args("x", "BTC", {"kind": "server", "name": "ETH-USDT"}, False)
    assert "-DryRun" not in args2 and "server" in args2, args2
    try:
        rerun_adjust.build_args("x", "BTC", {"kind": "carrier-pigeon", "name": "y"}, False)
    except rerun_adjust.AdjustError:
        pass
    else:
        raise AssertionError("unknown symbol kind accepted")

    ok = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout="\n".join([
            "filter 'btc-trend-short' -> 1 row(s)",
            "row symbol: 'BTC-USDT_1h'",
            'BASELINE {"Trades":"347","Sharpe":"0.61","Net P&L":"129368.53","Symbol":"BTC-USDT_1h"}',
            "",
            "ADJUST field=symbol server=BTC-USDT_1h -> builtin:BTC",
            "VERIFY symbols_line='(none)' selector_count='(1)'",
            'RESULT {"filter":"btc-trend-short","server_symbol":"BTC-USDT_1h",'
            '"applied":"builtin:BTC","trades":"85","sharpe":"2.21",'
            '"delta":{"Trades":-262,"Sharpe":1.6}}',
            "CLEANED_UP",
        ]),
    )
    summary = rerun_adjust.summarize(ok)
    assert summary["ok"] and summary["status"] == "COMPLETED", summary
    assert summary["results"]["trades"] == "85", summary
    assert summary["baseline"]["Trades"] == "347", summary
    assert summary["results"]["delta"]["Sharpe"] == 1.6, summary
    assert "baseline" not in summary["results"], "baseline must not be duplicated inside results"
    assert summary["windows_cleaned"] is True, summary
    assert "builtin:BTC" in summary["adjustment"], summary
    assert summary["verification"], summary

    dry = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout='DRY_RUN {"applied":"server:ETH-USDT","verified":true}\n',
    )
    s2 = rerun_adjust.summarize(dry)
    assert s2["status"] == "DRY_RUN" and s2["dry_run"], s2
    assert s2["windows_cleaned"] is False, s2

    dry_clean = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout='CLEANED_UP\nDRY_RUN {"applied":"builtin:BTC","verified":true}\n',
    )
    s2b = rerun_adjust.summarize(dry_clean)
    assert s2b["status"] == "DRY_RUN" and s2b["windows_cleaned"] is True, s2b

    wrong = subprocess.CompletedProcess(args=[], returncode=6, stdout="ROW_NOT_FOUND symbol=HYPE name=Keltner rows=13\n", stderr="")
    s3b = rerun_adjust.summarize(wrong)
    assert s3b["status"] == "ROW_NOT_FOUND", s3b

    named_args = rerun_adjust.build_args(
        "HYPE-USDT", "HYPE", None, True, expect_name="DownRange"
    )
    assert named_args[named_args.index("-ExpectName") + 1] == "DownRange", named_args

    wrong = subprocess.CompletedProcess(args=[], returncode=6, stdout="WRONG_ROW symbol=HYPE-USDT_1h\n", stderr="")
    s3 = rerun_adjust.summarize(wrong)
    assert s3["ok"] is False and s3["status"] == "WRONG_ROW", s3

    # symbols_line is OCR of the drawn selector, so a stray glyph can be glued onto the
    # name ('XRP' read back as 'IXRP'). That must not become a claim about symbol codes:
    # a name that appears inside the OCR text is accepted, and anything else is reported
    # as an OCR disagreement rather than a failure.
    aliased = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout=(
            'CLEANED_UP\nDRY_RUN {"applied":"builtin:XRP","verified":true,'
            '"symbols_line":"IXRP","symbols_line_source":"ocr",'
            '"form_label_ocr_differs":false,"symbol_evidence":"picker_row"}\n'
        ),
    )
    s4 = rerun_adjust.summarize(aliased)
    assert s4["ok"] is True and s4["status"] == "DRY_RUN", s4
    assert s4["form_label_ocr_differs"] is False, s4
    assert s4["results"]["symbols_line_source"] == "ocr", s4
    assert s4["results"]["symbol_evidence"] == "picker_row", s4

    # When OCR cannot even find the name, that is reported (not a pass dressed as doubt)
    # and still not fatal: the results grid is the authority.
    noisy = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout=(
            "FORM_LABEL_OCR_MISMATCH requested='XRP' ocr='Q#P' row='XRP'\n"
            'CLEANED_UP\nDRY_RUN {"applied":"builtin:XRP","verified":true,'
            '"form_label_ocr_differs":true,"symbol_evidence":"picker_row"}\n'
        ),
    )
    s4b = rerun_adjust.summarize(noisy)
    assert s4b["ok"] is True and s4b["form_label_ocr_differs"] is True, s4b
    assert "ocr='Q#P'" in s4b["form_label_ocr_mismatch"], s4b

    # ... but a run whose results grid shows another series must fail before metrics.
    mismatched = subprocess.CompletedProcess(
        args=[], returncode=24, stderr="",
        stdout="SYMBOL_MISMATCH requested='XRP' results='IXRP_1h'\n",
    )
    s5 = rerun_adjust.summarize(mismatched)
    assert s5["ok"] is False and s5["status"] == "SYMBOL_MISMATCH", s5

    # A foreign window holding the foreground stops the run before any input is injected
    # (this is what used to leave the desktop locked: a keystroke aimed at an unexpected
    # dialog could confirm it).
    blocked = subprocess.CompletedProcess(
        args=[], returncode=25, stderr="",
        stdout="INPUT_BLOCKED FOREGROUND_HELD_BY_DIALOG keys fg_pid=1234 fg='Confirm'\n",
    )
    s6 = rerun_adjust.summarize(blocked)
    assert s6["ok"] is False and s6["status"] == "INPUT_BLOCKED", s6

    # A run that takes no trades renders no row: that is a completed outcome, reported as
    # NO_TRADES with trades 0, not as a blank success or an unreadable grid.
    no_trades = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout=(
            "NO_TRADES window='Re-Run results - xyz_CL_1h (Long)' columns=40\n"
            'WINDOWS ["Build Alpha"]\n'
            'NO_TRADES {"applied":"builtin:xyz_CL","trades":"0","no_trades":true,'
            '"symbol_evidence":"no_results"}\n'
        ),
    )
    s7 = rerun_adjust.summarize(no_trades)
    assert s7["ok"] is True and s7["status"] == "NO_TRADES", s7
    assert s7["results"]["trades"] == "0" and s7["results"]["no_trades"] is True, s7
    assert s7["results"]["symbol_evidence"] == "no_results", s7
    assert s7["windows_cleaned"] is True, s7

    # ---- trades: opt-in capture, stored server-side, paged out by run id --------------
    args_trades = rerun_adjust.build_args(
        "BTC-USDT", "BTC", {"kind": "builtin", "name": "BTC", "timeframe": "1h"},
        False, include_trades=True, trades_path=r"C:\tmp\t.tsv",
    )
    assert "-IncludeTrades" in args_trades, args_trades
    assert args_trades[args_trades.index("-TradesOut") + 1] == r"C:\tmp\t.tsv", args_trades
    assert "-IncludeTrades" not in rerun_adjust.build_args("BTC-USDT", "BTC", None, False)
    # a dry run simulates nothing, so there is nothing to capture
    try:
        rerun_adjust.build_args("BTC-USDT", "BTC", None, True, include_trades=True)
        raise AssertionError("dry run + include_trades should be rejected")
    except rerun_adjust.AdjustError:
        pass

    # paging reads the pointer from the journal record, not a caller-supplied path
    log = SCRATCH / "trades_journal.jsonl"
    tsv = SCRATCH / "trades.tsv"
    tsv.write_text(
        "Trade\tSymbol\tEntry on\tExit on\tEntry Value\tExit Value\tAccount value\t"
        "Position size\tPosition exposure\tResult\n"
        "1  EX\tBTC-USDT\t1/9/2023 1:00:00 PM\t1/9/2023 9:00:00 PM\t17225.5\t17248.9\t"
        "100000\t20.6\t355.2%\t198.41\n"
        "2  EX\tBTC-USDT\t1/12/2023 9:00:00 AM\t1/12/2023 9:00:00 PM\t18191.8\t18264.1\t"
        "100000\t11.0\t200.1%\t635.12\n",
        encoding="utf-8",
    )
    record = {
        "ts": "2026-10-27T00:00:00Z", "event": "tool_call_finish",
        "run_id": "r1", "tool": "rerun_with_adjustments", "tag": "tg",
        "status": "COMPLETED",
        "result": {"results": {"trades_detail": {
            "path": str(tsv), "rows": 2, "grid_rows": 2, "header_ok": True,
            "pnl_ok": True, "result_sum": 833.53, "status": "TRADES_OK"}}},
    }
    log.write_text(json.dumps(record) + "\n", encoding="utf-8")
    page = rerun_adjust.read_trades("r1", offset=0, limit=1, runlog_path=log)
    assert page["status"] == "OK" and page["rows"] == 2 and page["returned"] == 1, page
    assert page["columns"][0] == "Trade" and page["trades"][0][0].startswith("1"), page
    assert page["verification"]["pnl_ok"] is True, page
    page2 = rerun_adjust.read_trades("r1", offset=1, limit=10, runlog_path=log)
    assert page2["returned"] == 1 and page2["trades"][0][0].startswith("2"), page2
    assert rerun_adjust.read_trades("nope", runlog_path=log)["status"] == "RUN_NOT_FOUND"
    # the host's zone must be stated: BuildAlpha writes no offset into the times
    assert page["trade_times"]["utc_offset"], page

    # "no file" has three meanings and must not be collapsed into one
    def with_record(run_id: str, args: dict, results: dict) -> None:
        rec = {"ts": "2026-10-27T00:00:00Z", "event": "tool_call_finish",
               "run_id": run_id, "tool": "rerun_with_adjustments", "tag": "tg",
               "status": "COMPLETED", "args": args, "result": {"results": results}}
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(rec) + "\n")

    with_record("failed-export", {"include_trades": True},
                {"trades": "6", "trades_detail": {"status": "CONTEXT_MENU_MISSING",
                                                  "rows": 0, "grid_rows": -1}})
    bad = rerun_adjust.read_trades("failed-export", runlog_path=log)
    assert bad["status"] == "TRADES_EXPORT_FAILED", bad
    assert bad["export_status"] == "CONTEXT_MENU_MISSING", bad

    with_record("asked-but-nothing", {"include_trades": True}, {"trades": "6"})
    assert rerun_adjust.read_trades("asked-but-nothing", runlog_path=log)["status"] == "TRADES_NOT_CAPTURED"

    with_record("zero-trades", {"include_trades": True}, {"trades": "0", "no_trades": True})
    assert rerun_adjust.read_trades("zero-trades", runlog_path=log)["status"] == "NO_TRADES"

    with_record("not-asked", {}, {"trades": "6"})
    assert rerun_adjust.read_trades("not-asked", runlog_path=log)["status"] == "NO_TRADES_RECORDED"

    # an older build leaked log strings into the return value; that record must not crash
    with_record("list-shape", {"include_trades": True},
                {"trades": "6", "trades_detail": [
                    "context menu attempt 1 missed; retrying",
                    {"status": "TRADES_OK", "rows": 2, "grid_rows": 2, "header_ok": True,
                     "pnl_ok": True, "path": str(tsv)}]})
    legacy = rerun_adjust.read_trades("list-shape", runlog_path=log)
    assert legacy["status"] == "OK" and legacy["rows"] == 2, legacy


def test_31_oos_split() -> None:
    """In/out-of-sample settings: read from the form, split date derived from the dates.

    The numbers are pinned from a live dry run of tag ph37u4ux2f (BTC-USDT 1h, Short,
    2021-07-31 -> 2026-09-23) whose form read carries 'Out of Sample End' and
    'Out of Sample percent 0.3'. BuildAlpha's own serialized config agrees that the
    percent field holds a fraction: <OosLocation>1</OosLocation>
    <OutOfSamplePercent>0.3</OutOfSamplePercent>.
    """
    require_powershell()
    script = Path("scripts/buildalpha_uia.ps1")
    assert script.exists(), script
    harness = r'''
. .\scripts\buildalpha_uia.ps1
$base = @{ 'Start Date' = '7/31/2021 12:00:00 AM'; 'Stop Date' = '9/23/2026 11:59:59 PM';
           'Out of Sample' = 'End'; 'Out of Sample percent' = '0.3' }
$live = Get-OosSplit $base
$off = Get-OosSplit @{ 'Start Date' = $base['Start Date']; 'Stop Date' = $base['Stop Date'];
                       'Out of Sample' = 'End'; 'Out of Sample percent' = '0' }
$begin = Get-OosSplit @{ 'Start Date' = $base['Start Date']; 'Stop Date' = $base['Stop Date'];
                         'Out of Sample' = 'Begin'; 'Out of Sample percent' = '0.3' }
@{
  live_mode = $live.mode; live_raw = $live.percent_raw; live_pct = $live.percentage
  live_split = $live.split_date; live_basis = $live.basis
  off_mode = $off.mode; off_pct = $off.percentage; off_split = $off.split_date
  begin_split = $begin.split_date
} | ConvertTo-Json -Compress
'''
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", harness],
        capture_output=True, text=True, timeout=180,
    )
    assert proc.returncode == 0, proc.stderr[-600:]
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    assert got["live_mode"] == "End", got
    assert got["live_raw"] == "0.3", got
    assert got["live_pct"] == 30, got                      # fraction 0.3 -> 30 %
    assert got["live_split"] == "2025-03-08", got           # 30 % off the end of 1880 days
    assert got["live_basis"] == "computed", got
    # disabled: the mode says off and there is no percentage to report
    assert got["off_mode"] == "off", got
    assert got["off_pct"] is None, got
    assert got["off_split"] == "", got
    assert got["begin_split"] == "2023-02-15", got           # the same 30 % off the start


def test_32_variance_capture_summary() -> None:
    """capture_variance_test: reply shape, size cap, and the file/sha256 agreement.

    The image never enters the journal and the encoded image is dropped (not truncated)
    when it would pass the cap - so a caller either gets a complete image or none.
    """
    from . import variance_capture as vc

    proc = subprocess.CompletedProcess(
        args=[], returncode=0, stderr="",
        stdout="noise line\n" + 'CAPTURE ' + json.dumps({
            "status": "OK", "tag": "u3z4vkztlz", "run_id": "", "row": "hype-mr-long",
            "symbol": "HYPE-USDT_1h", "path": "X", "bytes": 11, "sha256": "abc",
            "width": 770, "height": 668, "format": "png", "downscaled_from": 770,
            "title": "Variance Testing", "accelerator_used": "invoke",
            "capture_area": "client", "dialog_open": True, "duration_ms": 7610,
            "detail": "",
        }) + "\n",
    )
    summary = vc.summarize(proc, {"tag": "u3z4vkztlz", "run_id": None,
                                  "row": "hype-mr-long", "symbol": "HYPE-USDT_1h"})
    assert summary["status"] == "OK", summary
    assert summary["target"]["tag"] == "u3z4vkztlz", summary
    assert summary["width"] == 770 and summary["height"] == 668, summary
    assert summary["image_included"] is False, summary  # set later, never by the script
    assert "data" not in json.dumps(summary), summary   # no pixels in the payload
    # the OCR was removed from the reply: no summary, no summary_status, nothing that smells of it
    assert not [k for k in summary if "summary" in k], sorted(summary)
    # the grid context travels with every reply, so a failure can be judged
    assert "grid" in summary and set(summary["grid"]) == {
        "portfolio", "rows", "filtered_rows", "filter", "sample_names"}, summary["grid"]
    for key in ("portfolio", "portfolio_switched"):
        assert key in summary, (key, sorted(summary))
    # freshness is a scan concern, not a capture one: none of it may appear in the reply
    for gone in ("cache_age_seconds", "scan_age_seconds", "cached_scan_rows",
                 "stale_cache", "cache_warning"):
        assert gone not in summary, (gone, sorted(summary))

    # a missing line is a failure with a detail, never a silent empty reply
    broken = vc.summarize(subprocess.CompletedProcess(args=[], returncode=6, stdout="", stderr="boom"))
    assert broken["status"] == "MENU_ITEM_MISSING" and "boom" in broken["detail"], broken
    # a lookup failure must not be reported as a capture fault
    notfound = vc.summarize(subprocess.CompletedProcess(args=[], returncode=2, stdout="", stderr="unknown tag"))
    assert notfound["status"] == "TAG_NOT_FOUND", notfound
    assert notfound["image_omitted_reason"] == "NOT_FOUND", notfound
    # a locked desktop is not a missing strategy, and it is its own status
    blocked = vc.summarize(subprocess.CompletedProcess(args=[], returncode=25, stdout="", stderr="no input"))
    assert blocked["status"] == "INPUT_BLOCKED", blocked
    # a grid that is not materialised is not a name mismatch either
    novisible = vc.summarize(subprocess.CompletedProcess(args=[], returncode=30, stdout="", stderr="no grid"))
    assert novisible["status"] == "GRID_NOT_VISIBLE", novisible
    # a stale-cache verdict no longer exists: freshness belongs to a scan tool
    assert 29 not in vc.STATUS_BY_EXIT, vc.STATUS_BY_EXIT

    # SIZE_CAP keeps the file and the text: the capture itself worked
    reply = dict(summary)
    assert vc.apply_size_cap(reply, 1000, 1048576) is True
    assert reply["status"] == "OK", reply
    assert vc.apply_size_cap(reply, 2000000, 1048576) is False
    assert reply["status"] == "SIZE_CAP" and reply["image_omitted_reason"] == "SIZE_CAP", reply
    assert reply["path"] and reply["sha256"] == "abc", reply

    # read_image recomputes the digest: a file that changed after capture is an error
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "shot.png"
        path.write_bytes(b"0123456789a")
        reply2 = dict(summary, path=str(path), bytes=11,
                      sha256=hashlib.sha256(b"0123456789a").hexdigest())
        data, size = vc.read_image(reply2)
        assert size == 11 and data, (data, size)
        reply2["bytes"] = 99
        try:
            vc.read_image(reply2)
        except vc.CaptureError as exc:
            assert "size changed" in str(exc), exc
        else:  # pragma: no cover
            raise AssertionError("a changed file must not be returned as the capture")


def test_35_identify_plan_order() -> None:
    """Which search the row lookup will try, and in what order.

    The sequence is the whole point: a name if there is one, then the metrics. Rule text must
    never be used as a filter - a find box returns nothing for '>' and '(' and the grid then
    looks empty, which is how a present strategy was reported as a missing grid.
    """
    from strategy_cache import grid_ingest, identify

    engine = fresh_engine()
    grid = SCRATCH / "grid_identify.tsv"
    grid.write_text("\n".join([
        "# top_level=2 grid_rows=2",
        "row\tName\tSymbol\tType\tExit Params\tTrades\tSharpe\tNet P&L",
        "1\thype-mr-short vsShift: med\tHYPE-USDT_1h\tShort\tPT 2.00 atr\t123\t2.75\t71143.52",
        "2\tlow[0] > EMA(close,12)[0], DownRange(1,0) = 1\tHYPE-USDT_1h\tLong\tPT 7.00 atr\t258\t2.39\t133606.25",
    ]) + "\n", encoding="utf-8")
    rows, _ = grid_ingest.read_grid(grid)
    grid_ingest.ingest(engine, rows, "Common Portfolio", home=True)

    with engine.connect() as conn:
        named_tag = [r["tag"] for r in queries.query_strategies(conn)["rows"]
                     if r["custom_name"] == "hype-mr-short vsShift: med"][0]
        unnamed_tag = [r["tag"] for r in queries.query_strategies(conn)["rows"]
                       if not r["custom_name"]][0]

        # Net P&L first: one typed number filters 427 rows to ~1 (416 distinct values measured),
        # so the usual search is one filter application instead of a scan.
        named = identify.plan(conn, tag=named_tag)
        assert [c["kind"] for c in named["candidates"]] == ["metrics", "name", "symbol"], named
        assert named["candidates"][0]["search"] == "71143.52", named["candidates"][0]
        assert named["candidates"][1]["search"] == "hype-mr-short vsShift: med"

        unnamed = identify.plan(conn, tag=unnamed_tag)
        assert [c["kind"] for c in unnamed["candidates"]] == ["metrics", "symbol"], unnamed
        assert unnamed["candidates"][0]["search"] == "133606.25", unnamed["candidates"][0]
        assert unnamed["reason_name_absent"] == "no custom_name", unnamed
        assert unnamed["symbol"] == "HYPE-USDT", unnamed
        assert unnamed["expected"]["trades"] == 258, unnamed["expected"]

        dicted = identify.plan(conn, tag=unnamed_tag, name="my own label")
        assert dicted["candidates"][1] == {"kind": "name", "value": "my own label",
                                           "source": "caller", "search": "my own label"}, dicted

        try:
            identify.plan(conn, tag=named_tag, portfolio="Kraken")
        except identify.IdentifyError as exc:
            assert exc.status == "PORTFOLIO_MISMATCH", exc.status
        else:
            raise AssertionError("wrong-portfolio tag was accepted")

        try:
            identify.plan(conn, tag="no-such-tag-xyz")
        except identify.IdentifyError as exc:
            assert exc.status == "TAG_NOT_FOUND", exc.status
        else:
            raise AssertionError("unknown tag was accepted")

    assert identify.is_searchable_name("hype-mr-short vsShift: med") is True
    assert identify.is_searchable_name("low[0] > EMA(close,12)[0], DownRange(1,0) = 1") is False
    assert identify.is_searchable_name("") is False


def test_34_read_capture_chunks() -> None:
    """The chunked reader: exact reassembly, a hard 65536 cap, and a refusal outside captures.

    This exists because the reply can no longer be trusted to carry the picture: above the
    inline cap the caller pulls it slice by slice, so a wrong offset or a missing cap silently
    corrupts the file.
    """
    from strategy_cache import variance_capture as vc
    from strategy_cache.mcp_server import read_capture_chunk, READ_CHUNK_MAX, INLINE_MAX_BYTES

    assert READ_CHUNK_MAX == 65536 and INLINE_MAX_BYTES == 65536
    scratch = vc.SCREENS_DIR / "_test_reader.png"
    payload = bytes(range(256)) * 600  # 153600 bytes: more than one chunk
    scratch.write_bytes(payload)
    try:
        chunks, offset, eof = [], 0, False
        while not eof:
            r = read_capture_chunk(str(scratch), offset, 10 ** 9)  # ask past the cap on purpose
            assert r["ok"], r
            assert r["length"] <= READ_CHUNK_MAX, r["length"]
            chunks.append(base64.b64decode(r["base64"]))
            offset += r["length"]
            eof = r["eof"]
        assert b"".join(chunks) == payload
        assert len(chunks) == 3, len(chunks)
        assert read_capture_chunk(str(scratch), 0, 10).__len__() and             read_capture_chunk(str(scratch), 0, 10)["length"] == 10

        outside = read_capture_chunk("C:/Windows/win.ini")
        assert outside["ok"] is False and outside["status"] == "PATH_REJECTED", outside
        assert outside["base64"] is None
        missing = read_capture_chunk(str(vc.SCREENS_DIR / "_no_such_capture.png"))
        assert missing["status"] == "PATH_REJECTED", missing
        past = read_capture_chunk(str(scratch), 10 ** 9)
        assert past["ok"] and past["eof"] and past["length"] == 0
    finally:
        scratch.unlink(missing_ok=True)


def test_33_variance_summary_ocr_parse() -> None:
    """The OCR line parser, pinned against text recorded from a live capture.

    BuildAlpha draws this panel white-on-black with slashed zeros, which the engine reads
    as 'ø'/'Ø'/'l'. The recorded lines below are exactly what came back for tag
    u3z4vkztlz (2026-10-29); the expected values are the ones visible in the saved PNG.
    """
    require_powershell()
    ocr_lines_file = Path(_tempfile.mkdtemp()) / "ocr-lines.txt"
    lines = [
        "0",
        "20 40 60 80 100 120 140 160 180",
        "Ruin",
        "Results of make money Count: løøø Count : 43",
        "Simulation : make money: løø.øø x Ruin Odds: 4.30 X",
        "Average PNLDD: 7.40",
        "Average Profit: USD 79912.95",
        "Average Drawdown: USD 1ø792.42",
        "95% Confident Profit: USD 30832.39 128993.51",
        "-",
        "Confident",
        "95% Drawdown: USD 3373.09 - 18211.74",
    ]
    harness = (
        ". .\\scripts\\buildalpha_uia.ps1\n"
        "$lines = @(Get-Content -Encoding utf8 '" + str(ocr_lines_file) + "')\n"
        "$r = ConvertFrom-VarianceText $lines\n"
        "@{ status = $r.Status; fields = $r.Fields } | ConvertTo-Json -Compress -Depth 4\n"
    )
    ocr_lines_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", harness],
        capture_output=True, text=True, timeout=180,
    )
    assert proc.returncode == 0, proc.stderr[-600:]
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    f = got["fields"]
    # every figure a reader can see in the image, read back as a float
    assert f["make_money_count"] == 1000, f
    assert f["make_money_pct"] == 100, f
    assert f["ruin_count"] == 43, f
    assert f["ruin_odds_pct"] == 4.3, f
    assert f["avg_pnl_dd"] == 7.4, f
    assert f["avg_profit"] == 79912.95, f
    assert f["avg_drawdown"] == 10792.42, f          # '1ø792.42' -> slashed zero
    assert f["conf95_profit_low"] == 30832.39 and f["conf95_profit_high"] == 128993.51, f
    assert f["conf95_drawdown_low"] == 3373.09 and f["conf95_drawdown_high"] == 18211.74, f
    # the panel prints 'Results of Simulation:' and no total, so the field stays null
    assert f["simulation"] is None, f
    assert got["status"] == "PARTIAL", got

    # nothing readable at all is OCR_FAILED, not a summary full of zeros
    empty = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
         ". .\\scripts\\buildalpha_uia.ps1; $r = ConvertFrom-VarianceText @(); "
         "@{ status = $r.Status; n = @($r.Fields.Values | Where-Object { $null -ne $_ }).Count } | ConvertTo-Json -Compress"],
        capture_output=True, text=True, timeout=180,
    )
    empty_got = json.loads(empty.stdout.strip().splitlines()[-1])
    assert empty_got["status"] == "OCR_FAILED" and empty_got["n"] == 0, empty_got

def test_36_runlog_schema() -> None:
    """The log contract in docs/logging.md: bounded fields, levels, scrub, no nesting."""
    import json as _json

    from . import runlog

    log = SCRATCH / "mcp_runlog_schema.log"
    for stale in SCRATCH.glob(log.name + "*"):
        stale.unlink()
    runlog.configure(log, backup_count=2, max_bytes=1024 * 1024, level="debug")

    # debug: stages are their own lines; the finish line stays small and flat
    run_id = runlog.record_start("capture_eratio", {"tag": "abc", "password": "hunter2",
                                                    "blob": "x" * 9000}, tag="abc")
    runlog.record_finish(run_id, "capture_eratio", {"tag": "abc"}, tag="abc", status="OK",
                         duration_ms=43749.6,
                         result={"status": "OK", "last_stage": "save",
                                 "stages": [{"stage": "search", "ms": 12000}],
                                 "big": "y" * 20000})
    lines = [_json.loads(l) for l in log.read_text(encoding="utf-8").splitlines() if l.strip()]
    events = [l["event"] for l in lines]
    assert events == ["log_open", "tool_call_start", "stage", "tool_call_finish"], events

    start = lines[1]
    assert start["args"]["password"] == "***", start["args"]        # credentials never land
    assert isinstance(start["args"], dict), start["args"]           # shape kept, not a JSON string
    assert start["blob_truncated"] is True and start["blob_bytes"] == 9000
    assert len(start["args"]["blob"]) == runlog.FIELD_CAP

    finish = lines[3]
    assert "stages" not in finish, "the timeline belongs in its own lines"
    assert finish["last_stage"] == "save"
    assert isinstance(finish["duration_ms"], int) and finish["duration_ms"] == 43749
    assert finish["ok"] is True and finish["lvl"] == "info"
    assert finish["big_truncated"] is True
    assert len(_json.dumps(finish)) < runlog.KEY_CAP, "one line must stay small"
    assert set(finish) >= {"ts", "lvl", "event", "run_id", "tool", "status", "ok",
                           "duration_ms", "result", "stdout", "stderr"}

    # info: no stage lines; a failure is logged at warn
    runlog.configure(log, backup_count=2, max_bytes=1024 * 1024, level="info")
    rid2 = runlog.record_start("capture_eratio", {"tag": "abc"}, tag="abc")
    runlog.record_finish(rid2, "capture_eratio", {"tag": "abc"}, tag="abc", status="TIMEOUT",
                         result={"status": "TIMEOUT", "last_stage": "wait-results-window",
                                 "stages": [{"stage": "search", "ms": 5}]})
    tail = [_json.loads(l) for l in log.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert [l["event"] for l in tail[-2:]] == ["tool_call_start", "tool_call_finish"]
    assert tail[-1]["lvl"] == "warn" and tail[-1]["ok"] is False
    assert tail[-1]["last_stage"] == "wait-results-window"
    runlog.configure("", level="info")


def test_37_stdout_is_reply_only() -> None:
    """stdout carries the reply and nothing else.

    The capture script's stdout is parsed line by line for a CAPTURE/FIND verdict, and the same
    server can run over stdio transport where stdout *is* the protocol. One stray Write-Output -
    a diagnostic added while debugging - breaks both, silently. So: exactly one reply line,
    diagnostics only via [Console]::Error.
    """
    root = pathlib.Path(__file__).resolve().parents[1]
    scripts = {
        "buildalpha_capture_view.ps1": "CAPTURE",
        "buildalpha_find_strategy.ps1": "FIND",
    }
    for name, marker in scripts.items():
        text = (root / "scripts" / name).read_text(encoding="utf-8")
        emits = [line.strip() for line in text.splitlines()
                 if line.lstrip().startswith("Write-Output")]
        assert len(emits) == 1, f"{name}: {len(emits)} Write-Output call(s): {emits}"
        assert marker in emits[0], f"{name}: the one Write-Output is not the reply: {emits[0]}"
        assert "Write-Host" not in text, f"{name}: Write-Host has no place in a tool script"
    # the capture script narrates, so its narration must be on stderr
    capture = (root / "scripts" / "buildalpha_capture_view.ps1").read_text(encoding="utf-8")
    assert capture.count("[Console]::Error.WriteLine(") >= 5, "capture diagnostics left stdout"


def test_38_ui_lock_is_exclusive() -> None:
    """One GUI driver at a time: a held lock must refuse a second process, and a child must pass.

    Two tool calls driving the same grid interleave clicks and filters - the wrong-row class of bug.
    The lock is an OS file handle (FileShare.None), so it is released when a process dies; this test
    pins the two properties the scripts rely on.
    """
    require_powershell()
    import time

    root = pathlib.Path(__file__).resolve().parents[1]
    helper = root / "scripts" / "buildalpha_uia.ps1"
    holder = root / "scripts" / "_lock_holder.ps1"
    holder.write_text(
        ". \"$PSScriptRoot\\buildalpha_uia.ps1\"\n"
        "Remove-Item Env:BA_UI_LOCK_HELD -ErrorAction SilentlyContinue\n"
        "if (-not (Enter-UiLock)) { 'BUSY'; exit 1 }\n"
        "'HELD'\n"
        "Start-Sleep -Seconds 3\n",
        encoding="utf-8",
    )
    try:
        first = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                  "-File", str(holder)],
                                 stdout=subprocess.PIPE, text=True)
        # give the first process time to take the lock
        for _ in range(40):
            if first.poll() is not None:
                break
            pathlib.Path(root / "logs" / "ui.lock").exists()
            try:
                with open(root / "logs" / "ui.lock", "r+b"):
                    pass          # still free? keep waiting
            except OSError:
                break         # held
            time.sleep(0.05)
        second = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
             f". '{helper}'; Remove-Item Env:BA_UI_LOCK_HELD -ErrorAction SilentlyContinue; "
             "if (Enter-UiLock) { 'GOT_IT' } else { 'REFUSED' }"],
            capture_output=True, text=True, timeout=60)
        assert "REFUSED" in second.stdout, second.stdout + second.stderr
        first.wait(timeout=60)

        # a child of a holder inherits the flag and is allowed through
        third = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
             f"$env:BA_UI_LOCK_HELD='1'; . '{helper}'; if (Enter-UiLock) {{ 'REENTRANT' }} else {{ 'REFUSED' }}"],
            capture_output=True, text=True, timeout=60)
        assert "REENTRANT" in third.stdout, third.stdout + third.stderr
    finally:
        holder.unlink(missing_ok=True)



TESTS = [
    ("1 reader twice -> same tag", test_1_reader_twice_same_tag),
    ("2 stop date changed -> new tag, same logical_hash", test_2_stop_date_change),
    ("3 identical re-run -> collision suffix, no overwrite", test_3_identical_rerun_gets_suffix),
    ("4 no Market 2 / no custom name -> same tag", test_4_no_market2_no_custom_name),
    ("5 raw vs rounded commission -> same tag", test_5_commission_float_noise),
    ("6 empty symbol -> rejected, nothing written", test_6_validation_rejects_missing_symbol),
    ("7 settings_json is the validated model dump", test_7_settings_json_is_validated_model_dump),
    ("8 cache_stats counts and dimensions", test_8_cache_stats),
    ("9 metric glossary matches the table", test_9_metric_glossary_matches_schema),
    ("10 status snapshot age/stale + parsing", test_10_status_snapshot_annotation),
    ("11 live status capture + snapshot fallback", test_11_live_status_and_fallback),
    ("12 job lifecycle summary (running/completed/observed)", test_12_job_lifecycle_summary),
    ("13 grid ingest snapshot + refresh", test_13_grid_ingest_snapshot),
    ("14 query_strategies filters/sort/paging", test_14_query_strategies),
    ("15 action-tool result summarising", test_15_action_summary),
    ("16 filter list parsing", test_16_list_filters_parsing),
    ("17 stop result parsing", test_17_stop_summary),
    ("18 filter summary parsing", test_18_filter_summary),
    ("19 portfolio membership is many-to-many", test_19_portfolio_membership),
    ("20 portfolio sweep naming", test_20_portfolio_sweep_names),
    ("21 rerun-with-adjustments parsing", test_21_rerun_adjust_parsing),
    ("22 rerun resolution by tag", test_22_rerun_resolution),
    ("23 settings window helper", test_23_settings_script),
    ("24 symbol lookup script", test_24_symbol_lookup_script),
    ("25 symbol cell writer", test_25_symbol_cell_script),
    ("26 rerun date window", test_26_rerun_date_window),
    ("27 deleted strategy is not current", test_27_deleted_strategy_is_not_current),
    ("28 run log", test_28_runlog),
    ("29 windows + FORM_READ_FAILED", test_29_windows_and_form_failed),
    ("30 journal semantics + jobs", test_30_journal_semantics_and_jobs),
    ("31 OOS split from the form read", test_31_oos_split),
    ("32 variance capture summary/cap", test_32_variance_capture_summary),
    ("33 variance panel OCR parse", test_33_variance_summary_ocr_parse),
    ("34 chunked capture reader", test_34_read_capture_chunks),
    ("35 row-search plan order", test_35_identify_plan_order),
    ("36 run log schema", test_36_runlog_schema),
    ("37 stdout is reply only", test_37_stdout_is_reply_only),
    ("38 UI lock is exclusive", test_38_ui_lock_is_exclusive),
]


def main() -> int:
    failures = 0
    skipped = 0
    for name, fn in TESTS:
        try:
            fn()
            print(f"PASS  {name}")
        except SkipTest as exc:
            skipped += 1
            print(f"SKIP  {name}: {exc}")
        except Exception as exc:  # noqa: BLE001 - report and continue
            failures += 1
            print(f"FAIL  {name}: {exc}")
            traceback.print_exc(limit=2)
    print(f"\n{len(TESTS) - failures - skipped}/{len(TESTS)} passed, {skipped} skipped")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
