"""Bulk ingest of portfolio-grid rows (metrics snapshot, no Re-Run forms).

The grid gives 35 columns per top-level strategy: Name (rules, or a custom
label), Symbol, Type, Exit Params and the 26 metrics. It does **not** give the
date window, costs, sizing or fitness function, so a grid row gets a *logical*
identity:

    logical = symbol|type|entry_rules|exit_params

and ``variant_hash == logical_hash``. Re-scanning a portfolio refreshes the
metrics of existing grid rows (they are snapshots), while form-based rows stay
immutable - ``db.upsert_strategy`` only refreshes rows whose settings say
``"source":"grid"``.

    uv run python -m strategy_cache.grid_ingest --portfolio "Common Portfolio" \\
        --rows grid-rows.txt [--dry-run] [--no-refresh]
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sys
from pathlib import Path

from sqlalchemy import text
from . import db
from .normalize import compute_tags, normalize_symbol, normalize_text
from .schema import METRIC_COLUMNS

#: BuildAlpha grid column -> cache metric column
COLUMN_TO_METRIC = {
    "Trades": "trade_count",
    "Sharpe": "sharpe",
    "Net P&L": "net_pnl",
    "Drawdown": "drawdown",
    "Win Percentage": "win_rate",
    "Drawdown MTM": "drawdown_mtm",
    "P&L / DD": "pnl_dd",
    "Profit Factor": "profit_factor",
    "Ratio WL": "ratio_wl",
    "CAGR": "cagr",
    "SQM": "sqm",
    "SQN": "sqn",
    "T-Test": "t_test",
    "E-Ratio": "e_ratio",
    "K-Ratio": "k_ratio",
    "Expectancy Score": "expectancy_score",
    "Avg Trade": "avg_trade",
    "Mean W trades": "mean_w_trades",
    "Mean L trades": "mean_l_trades",
    "Std W trades": "std_w_trades",
    "Std L trades": "std_l_trades",
    "Corr Coef": "corr_coef",
    "CPC Ratio": "cpc_ratio",
    "Perfect Profit Percentage": "perfect_profit_pct",
    "Perfect Profit Correlation": "perfect_profit_corr",
    "Custom Fitness": "custom_fitness",
}


class GridError(RuntimeError):
    """Unreadable grid capture."""


def _number(value) -> float | None:
    text = (value or "").strip().replace(",", "")
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def read_grid(path: Path) -> tuple[list[dict], dict]:
    """Parse a ``buildalpha_grid_rows.ps1`` capture: (rows, header metadata)."""
    path = Path(path)
    if not path.is_file():
        raise GridError(f"grid capture not found: {path}")
    meta: dict[str, str] = {}
    body: list[str] = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            for part in line.lstrip("# ").split():
                if "=" in part:
                    key, value = part.split("=", 1)
                    meta[key] = value
            continue
        body.append(line)
    if not body:
        raise GridError(f"grid capture has no table: {path}")
    reader = csv.reader(io.StringIO("\n".join(body)), delimiter="\t")
    rows = list(reader)
    columns = rows[0]
    return [dict(zip(columns, values)) for values in rows[1:]], meta


def build_record(row: dict, portfolio: str, source: str) -> dict | None:
    """One grid row -> upsert arguments, or None when unusable."""
    name = normalize_text(row.get("Name", ""))
    symbol = normalize_symbol(row.get("Symbol", ""))
    strategy_type = normalize_text(row.get("Type", ""))
    exit_params = normalize_text(row.get("Exit Params", ""))
    if not name or not symbol or not strategy_type:
        return None

    # 392/444 rows carry the rule expression in Name; the rest are custom labels.
    rule_like = "[" in name
    entry_rules = name if rule_like else ""
    custom_name = None if rule_like else name
    hash_entry = name if rule_like else f"[name] {name}"

    tags = compute_tags(
        symbol=symbol,
        strategy_type=strategy_type,
        entry_rules=hash_entry,
        exit_params=exit_params,
        start_date="",
        stop_date="",
        costs="",
        sizing="",
        fitness="",
        is_oos="",
    )
    settings = {
        "source": "grid",
        "portfolio": portfolio,
        "capture": source,
        "captured_at": db.now_iso(),
        "rule_like": rule_like,
        "tree_row": row.get("row"),
        "index": row.get("Index"),
        "state": row.get("State"),
        "live_position": row.get("Live Position"),
    }
    metrics = {target: _number(row.get(column)) for column, target in COLUMN_TO_METRIC.items()}
    return {
        "record": {
            **tags,
            "symbol": symbol,
            "strategy_type": strategy_type,
            "entry_rules": entry_rules,
            "exit_params": exit_params,
        },
        "custom_name": custom_name,
        "settings": json.dumps(settings, separators=(",", ":"), sort_keys=True),
        "metrics": metrics,
    }


def ingest(
    engine,
    rows: list[dict],
    portfolio: str,
    source: str = "grid-rows.txt",
    *,
    refresh: bool = True,
    dry_run: bool = False,
    home: bool = False,
    scan_id: int | None = None,
    grid_rows: int | None = None,
    position_base: int = 0,
) -> dict:
    """Upsert grid rows and record ``portfolio`` as one of their locations.

    ``home=True`` additionally makes this portfolio the *home* of every row:
    Common Portfolio holds every strategy, so it is the canonical home even when
    a strategy was first read from a smaller portfolio.

    Membership is recorded as a *scan snapshot*: when ``scan_id`` is given the rows
    are added to that scan (the caller finishes it), otherwise a scan is opened and
    finished here. ``grid_rows`` is what BuildAlpha reported for the grid; when it
    disagrees with the parsed row count the scan is stored with ``ok=0`` so a short
    or garbled capture can never look like "these strategies were deleted".
    """
    stats: dict[str, object] = {"insert": 0, "refresh": 0, "update": 0, "skipped": 0,
                                "merged": 0, "tags": []}
    owns_scan = scan_id is None
    with engine.begin() as conn:
        if scan_id is None:
            scan_id = db.start_scan(conn, portfolio, source)
        for idx, row in enumerate(rows):
            merged_tag = None
            built = build_record(row, portfolio, source)
            if built is None:
                stats["skipped"] = int(stats["skipped"]) + 1
                continue
            record_tag = built["record"]["tag"]  # type: ignore[index]
            if portfolio == db.MASTER_PORTFOLIO and not dry_run:
                # Master-list row: if this exact tag is unknown but an equivalent strategy is
                # already in the cache, adopt that tag instead of inserting a duplicate. Without
                # this, a strategy that lives in a named portfolio reappears in Common under a new
                # tag on every scan (measured: XMR|1h and ZEC|1h, identical metrics, two tags).
                known = conn.execute(
                    text("SELECT 1 FROM strategies WHERE tag = :t"), {"t": record_tag}
                ).first()
                if not known:
                    twin = db.find_equivalent_tag(
                        conn,
                        symbol=built["record"].get("symbol"),  # type: ignore[union-attr]
                        trades=(built["metrics"] or {}).get("trade_count"),
                        sharpe=(built["metrics"] or {}).get("sharpe"),
                        net_pnl=(built["metrics"] or {}).get("net_pnl"),
                    )
                    if twin:
                        built["record"]["tag"] = twin  # type: ignore[index]
                        stats["merged"] = int(stats.get("merged", 0)) + 1
                        merged_tag = twin
            if dry_run:
                stats["tags"].append(built["record"]["tag"])  # type: ignore[union-attr]
                continue
            if merged_tag:
                # The strategy already exists under this tag: record that this scan listed it and
                # leave the row alone. Upserting here would append a '-2' suffix and recreate the
                # duplicate under a new name.
                db.record_location(conn, merged_tag, portfolio, source)
                db.add_scan_member(conn, scan_id, merged_tag, position_base + idx)
                if home:
                    db.set_home_portfolio(conn, merged_tag, portfolio)
                continue
            outcome = db.upsert_strategy(
                conn,
                record=built["record"],
                portfolio=portfolio,
                custom_name=built["custom_name"],
                settings=built["settings"],
                metrics=built["metrics"],
                refresh_metrics=refresh,
            )
            key = outcome["action"]
            stats[key] = int(stats.get(key, 0)) + 1
            if home:
                db.set_home_portfolio(conn, outcome["tag"], portfolio)
            db.add_scan_member(conn, scan_id, outcome["tag"], position_base + idx)
        if owns_scan:
            parsed = len([t for t in stats["tags"]]) if dry_run else None
            # merged rows are counted by their upsert action too - adding them here made the
            # capture look larger than the grid and marked a good scan ok=0
            captured = parsed if dry_run else (
                int(stats["insert"]) + int(stats["refresh"]) + int(stats["update"]))
            ok = True if grid_rows is None else (captured == int(grid_rows))
            stats["scan"] = db.finish_scan(
                conn,
                scan_id,
                captured_rows=captured,
                grid_rows=grid_rows,
                ok=ok,
                note=None if ok else f"captured {captured} rows, grid reported {grid_rows}",
            )
    stats["scan_id"] = scan_id
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m strategy_cache.grid_ingest",
        description="Ingest a portfolio grid capture (top-level rows only).",
    )
    parser.add_argument("--rows", required=True, help="capture made by buildalpha_grid_rows.ps1")
    parser.add_argument("--portfolio", required=True, help="portfolio name the grid belongs to")
    parser.add_argument("--dry-run", action="store_true", help="print tags, write nothing")
    parser.add_argument("--no-refresh", action="store_true", help="keep metrics of known grid rows")
    parser.add_argument(
        "--home",
        action="store_true",
        help="make this portfolio the home of every row (use for Common Portfolio)",
    )
    args = parser.parse_args(argv)

    try:
        rows, meta = read_grid(Path(args.rows))
    except GridError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    stats = ingest(
        db.make_engine(),
        rows,
        args.portfolio,
        Path(args.rows).name,
        refresh=not args.no_refresh,
        dry_run=args.dry_run,
        home=args.home,
    )
    print(
        json.dumps(
            {
                "grid_rows": len(rows),
                "declared_top_level": meta.get("top_level"),
                "dry_run": args.dry_run,
                **{k: v for k, v in stats.items() if k != "tags"},
                "sample_tags": stats["tags"][:5],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
