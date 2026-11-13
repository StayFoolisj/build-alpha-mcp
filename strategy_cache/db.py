"""SQLite persistence for BuildAlpha strategies: insert-once, update-location."""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone

from sqlalchemy import create_engine, text

from .schema import IDENTITY_COLUMNS, METRIC_COLUMNS

log = logging.getLogger("strategy_cache")

DEFAULT_DB = os.environ.get("BA_CACHE_DB", "buildalpha_cache.sqlite3")


def make_engine(url: str | None = None):
    return create_engine(url or f"sqlite:///{DEFAULT_DB}", future=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _insert_sql() -> str:
    columns = ["tag", *IDENTITY_COLUMNS, *METRIC_COLUMNS]
    placeholders = ", ".join(f":{c}" for c in columns)
    return f"INSERT INTO strategies ({', '.join(columns)}) VALUES ({placeholders})"


def record_location(conn, tag: str, portfolio: str, source: str | None = None) -> None:
    """Record that ``tag`` is listed in ``portfolio`` (many-to-many, idempotent).

    ``strategies.portfolio`` stays the *home* portfolio (the one the strategy was
    first read from); membership is this table, so a strategy that lives in both
    Common Portfolio and Hyperliquid #2 keeps both rows.
    """
    conn.execute(
        text(
            "INSERT INTO strategy_portfolios (tag, portfolio, first_seen, last_seen, source) "
            "VALUES (:tag, :portfolio, :now, :now, :source) "
            "ON CONFLICT(tag, portfolio) DO UPDATE SET "
            "last_seen = :now, source = COALESCE(:source, source)"
        ),
        {"tag": tag, "portfolio": portfolio, "now": now_iso(), "source": source},
    )


def upsert_strategy(
    conn,
    *,
    record: dict,
    portfolio: str,
    custom_name: str | None,
    settings: dict,
    metrics: dict,
    force_new: bool = False,
    refresh_metrics: bool = False,
) -> dict:
    """Insert on first sight; on later sightings update only location fields.

    ``force_new`` treats the input as a *separate run artifact*: if the tag is
    already taken it gets a deterministic ``-2``/``-3`` suffix instead of
    updating the existing row (used for re-run results-window captures).

    ``refresh_metrics`` updates the metric columns too, but only for rows whose
    settings mark them as grid snapshots (``"source":"grid"``); form-captured
    rows stay immutable.

    ``record`` must contain: tag, logical_hash, variant_hash, symbol,
    strategy_type, entry_rules, exit_params.
    """
    base = record["tag"]
    suffix = 1
    collisions = 0
    while True:
        candidate = base if suffix == 1 else f"{base}-{suffix}"
        row = conn.execute(
            text("SELECT variant_hash FROM strategies WHERE tag = :tag"),
            {"tag": candidate},
        ).first()
        if row is None:
            payload = {
                "tag": candidate,
                "logical_hash": record["logical_hash"],
                "variant_hash": record["variant_hash"],
                "portfolio": portfolio,
                "custom_name": custom_name,
                "first_seen": now_iso(),
                "last_seen": now_iso(),
                # settings_json holds the validated Settings model dump, not raw text
                "settings_json": settings if isinstance(settings, str) else json.dumps(settings, sort_keys=True, ensure_ascii=False),
                "symbol": record["symbol"],
                "strategy_type": record["strategy_type"],
                "entry_rules": record["entry_rules"],
                "exit_params": record["exit_params"],
            }
            for key in METRIC_COLUMNS:
                payload[key] = metrics.get(key)
            conn.execute(text(_insert_sql()), payload)
            record_location(conn, candidate, portfolio, source=settings_source(settings))
            return {"tag": candidate, "action": "insert", "collisions": collisions}

        if not force_new and row[0] == record["variant_hash"]:
            if refresh_metrics:
                assignments = ", ".join(f"{name} = :{name}" for name in METRIC_COLUMNS)
                params = {name: metrics.get(name) for name in METRIC_COLUMNS}
                params.update({"n": custom_name, "t": now_iso(), "tag": candidate})
                refreshed = conn.execute(
                    text(
                        f"UPDATE strategies SET custom_name = :n, "
                        f"last_seen = :t, {assignments} "
                        "WHERE tag = :tag AND settings_json LIKE '%\"source\":\"grid\"%'"
                    ),
                    params,
                )
                if refreshed.rowcount:
                    record_location(conn, candidate, portfolio, source=settings_source(settings))
                    return {"tag": candidate, "action": "refresh", "collisions": collisions}
            conn.execute(
                text(
                    "UPDATE strategies SET custom_name = :n, "
                    "last_seen = :t WHERE tag = :tag"
                ),
                {"n": custom_name, "t": now_iso(), "tag": candidate},
            )
            record_location(conn, candidate, portfolio, source=settings_source(settings))
            return {"tag": candidate, "action": "update", "collisions": collisions}

        collisions += 1
        log.warning("tag collision for %s (variant differs) -> trying %s-%d", base, base, suffix + 1)
        suffix += 1


def fetch_all(conn) -> list[dict]:
    rows = conn.execute(text("SELECT * FROM strategies ORDER BY tag")).mappings().all()
    return [dict(r) for r in rows]


def settings_source(settings) -> str | None:
    """``'grid'`` / ``'form'`` / ... from a settings JSON blob, for provenance."""
    try:
        blob = json.loads(settings) if isinstance(settings, str) else settings
    except (TypeError, ValueError):
        return None
    return (blob or {}).get("source")


def set_home_portfolio(conn, tag: str, portfolio: str) -> None:
    """Pin the home portfolio (Common Portfolio is the parent of every strategy)."""
    conn.execute(
        text("UPDATE strategies SET portfolio = :p WHERE tag = :tag"),
        {"p": portfolio, "tag": tag},
    )


# --------------------------------------------------------------------- scans
# A scan is an immutable snapshot of one portfolio. "Currently in P" means "in the
# membership of the latest scan of P with ok=1", so a strategy deleted from the
# portfolio simply is not in the newest snapshot - no flags, no timestamp guesses.

def start_scan(conn, portfolio: str, source: str | None = None) -> int:
    """Open a scan and return its id. Call :func:`finish_scan` when done."""
    result = conn.execute(
        text(
            "INSERT INTO portfolio_scans (portfolio, started_at, source, ok) "
            "VALUES (:p, :t, :src, 0)"
        ),
        {"p": portfolio, "t": now_iso(), "src": source},
    )
    scan_id = int(result.lastrowid)
    log.debug("scan %s opened for %s", scan_id, portfolio)
    return scan_id


#: The portfolio that holds every strategy. Rows read from it are matched against what is already
#: known rather than inserted as new tags.
MASTER_PORTFOLIO = "Common Portfolio"


def find_equivalent_tag(
    conn,
    *,
    symbol: str | None,
    trades: float | None,
    sharpe: float | None,
    net_pnl: float | None,
    trades_tol: float = 0.5,
    sharpe_tol: float = 0.02,
    pnl_tol: float = 0.5,
) -> str | None:
    """A tag whose own numbers are the same as these, or None.

    Identity in this cache is derived from the row text, so the same strategy read twice can produce
    two tags (a re-formatted rule expression moves the hash). For the master list that is wrong: the
    strategy already exists, and a second tag for it is a duplicate that every rescan recreates.
    """
    if not symbol or trades is None or net_pnl is None:
        return None
    sql = (
        "SELECT tag FROM strategies WHERE symbol = :symbol "
        "AND abs(coalesce(trade_count, -1e9) - :trades) <= :tt "
        "AND abs(coalesce(net_pnl, -1e9) - :pnl) <= :pt"
    )
    params = {"symbol": symbol, "trades": float(trades), "tt": trades_tol,
              "pnl": float(net_pnl), "pt": pnl_tol}
    if sharpe is not None:
        sql += " AND abs(coalesce(sharpe, -1e9) - :sharpe) <= :st"
        params["sharpe"] = float(sharpe)
        params["st"] = sharpe_tol
    sql += " ORDER BY first_seen LIMIT 1"
    row = conn.execute(text(sql), params).mappings().first()
    return row["tag"] if row else None


def add_scan_member(conn, scan_id: int, tag: str, position: int | None = None) -> None:
    """Record that ``tag`` was listed in the scan (idempotent within a scan)."""
    conn.execute(
        text(
            "INSERT INTO scan_memberships (scan_id, tag, position) "
            "VALUES (:s, :tag, :pos) "
            "ON CONFLICT(scan_id, tag) DO NOTHING"
        ),
        {"s": scan_id, "tag": tag, "pos": position},
    )


def finish_scan(
    conn,
    scan_id: int,
    *,
    captured_rows: int | None = None,
    grid_rows: int | None = None,
    ok: bool = True,
    note: str | None = None,
) -> dict:
    """Close a scan. ``ok`` is what makes a snapshot authoritative.

    A capture whose parsed row count disagrees with what the grid reported must be
    recorded with ``ok=False``: it stays auditable but never becomes "current",
    so a bad capture can never look like "everything was deleted".
    """
    conn.execute(
        text(
            "UPDATE portfolio_scans SET finished_at = :t, captured_rows = :c, "
            "grid_rows = :g, ok = :ok, note = :note WHERE id = :s"
        ),
        {
            "t": now_iso(),
            "c": captured_rows,
            "g": grid_rows,
            "ok": 1 if ok else 0,
            "note": note,
            "s": scan_id,
        },
    )
    row = conn.execute(
        text("SELECT id, portfolio, captured_rows, grid_rows, ok FROM portfolio_scans WHERE id = :s"),
        {"s": scan_id},
    ).mappings().first()
    return dict(row) if row else {}


def latest_scan(conn, portfolio: str, *, ok_only: bool = True) -> dict | None:
    """Newest scan for a portfolio (``ok_only`` = the authoritative snapshot)."""
    sql = (
        "SELECT id, portfolio, started_at, finished_at, captured_rows, grid_rows, "
        "source, ok, note FROM portfolio_scans WHERE portfolio = :p"
    )
    if ok_only:
        sql += " AND ok = 1"
    sql += " ORDER BY id DESC LIMIT 1"
    row = conn.execute(text(sql), {"p": portfolio}).mappings().first()
    return dict(row) if row else None


def scan_members(conn, scan_id: int) -> list[dict]:
    rows = conn.execute(
        text("SELECT tag, position FROM scan_memberships WHERE scan_id = :s ORDER BY position, tag"),
        {"s": scan_id},
    ).mappings()
    return [dict(r) for r in rows]


def scan_diff(conn, portfolio: str, older: int, newer: int) -> dict:
    """Added / removed / common between two snapshots of the same portfolio."""
    def tags(scan_id: int) -> set[str]:
        return {
            r[0]
            for r in conn.execute(
                text("SELECT tag FROM scan_memberships WHERE scan_id = :s"), {"s": scan_id}
            )
        }

    a, b = tags(older), tags(newer)
    return {
        "portfolio": portfolio,
        "older_scan": older,
        "newer_scan": newer,
        "added": sorted(b - a),
        "removed": sorted(a - b),
        "common": len(a & b),
    }


def prune_scans(conn, portfolio: str, keep: int) -> dict:
    """Keep the newest ``keep`` scans for a portfolio plus the first one.

    The first scan is the diff baseline and is never removed, so "what changed
    since the beginning" stays answerable no matter how aggressive retention is.
    """
    ids = [
        int(r[0])
        for r in conn.execute(
            text("SELECT id FROM portfolio_scans WHERE portfolio = :p ORDER BY id"),
            {"p": portfolio},
        )
    ]
    if len(ids) <= keep:
        return {"portfolio": portfolio, "removed_scans": 0, "kept": ids}
    keepers = set(ids[:1]) | set(ids[-keep:]) if keep > 0 else set(ids[:1])
    drop = [i for i in ids if i not in keepers]
    if drop:
        conn.execute(
            text(f"DELETE FROM scan_memberships WHERE scan_id IN ({', '.join(str(i) for i in drop)})")
        )
        conn.execute(
            text(f"DELETE FROM portfolio_scans WHERE id IN ({', '.join(str(i) for i in drop)})")
        )
    return {"portfolio": portfolio, "removed_scans": len(drop), "kept": sorted(keepers)}


def strategy_history(conn, tag: str) -> list[dict]:
    """Per portfolio: first/last scan the strategy appears in, and whether it is
    in the newest authoritative snapshot (``present``)."""
    out: list[dict] = []
    rows = conn.execute(
        text(
            "SELECT s.portfolio AS portfolio, MIN(s.id) AS first_scan, MAX(s.id) AS last_scan, "
            "COUNT(*) AS scans FROM scan_memberships m "
            "JOIN portfolio_scans s ON s.id = m.scan_id "
            "WHERE m.tag = :tag GROUP BY s.portfolio ORDER BY s.portfolio"
        ),
        {"tag": tag},
    ).mappings()
    for row in rows:
        rec = dict(row)
        latest = latest_scan(conn, rec["portfolio"])
        rec["latest_scan"] = latest["id"] if latest else None
        rec["present"] = bool(latest and rec["last_scan"] == latest["id"])
        out.append(rec)
    return out

