"""Read-only queries over the strategy cache.

Every function takes an open SQLAlchemy ``Connection``; none of them write.
"""
from __future__ import annotations

import json

from sqlalchemy import text
from sqlalchemy.engine import Connection

from .schema import METRIC_COLUMNS

#: fields returned by :func:`list_strategies`
SUMMARY_FIELDS = (
    "tag",
    "symbol",
    "strategy_type",
    "sharpe",
    "trade_count",
    "portfolio",
    "custom_name",
)

#: fields returned by :func:`query_strategies`
QUERY_FIELDS = SUMMARY_FIELDS + ("net_pnl", "profit_factor", "drawdown", "win_rate", "cagr")

#: columns callers may sort on (identity text + every metric)
SORTABLE_FIELDS = (
    "tag", "portfolio", "custom_name", "symbol", "strategy_type",
    "first_seen", "last_seen",
    *METRIC_COLUMNS,
)

#: hard cap on ``limit`` so one call cannot dump the whole portfolio
MAX_LIMIT = 500


#: Membership is read from the newest authoritative scan of a portfolio. A strategy
#: deleted in BuildAlpha is simply absent from that snapshot, so it drops out of
#: "current" answers while its rows (and the scan it was last seen in) remain.
CURRENT_MEMBERSHIP_SQL = (
    "tag IN (SELECT m.tag FROM scan_memberships m "
    "JOIN portfolio_scans s ON s.id = m.scan_id "
    "WHERE s.id = (SELECT MAX(id) FROM portfolio_scans "
    "WHERE portfolio = :portfolio AND ok = 1))"
)

#: Every portfolio the tag was *ever* listed in (the append-only ledger).
EVER_SEEN_SQL = "tag IN (SELECT tag FROM strategy_portfolios WHERE portfolio = :portfolio)"


def list_strategies(conn: Connection, portfolio: str | None = None,
                    include_removed: bool = False) -> list[dict]:
    """Cached strategies, optionally filtered by portfolio membership.

    ``include_removed=True`` uses the ever-seen ledger instead of the newest scan,
    so strategies deleted from the portfolio are included too.
    """
    sql = (
        "SELECT tag, symbol, strategy_type, sharpe, trade_count, portfolio, custom_name "
        "FROM strategies"
    )
    params: dict[str, object] = {}
    if portfolio is not None:
        clause = EVER_SEEN_SQL if include_removed else CURRENT_MEMBERSHIP_SQL
        sql += f" WHERE {clause}"
        params["portfolio"] = portfolio
    sql += " ORDER BY symbol, strategy_type, tag"
    rows = conn.execute(text(sql), params).mappings().all()
    return [dict(row) for row in rows]


def get_strategy(conn: Connection, tag: str) -> dict | None:
    """Full row for one tag, with ``settings_json`` decoded into an object.

    Returns ``None`` when the tag is unknown. If the stored JSON cannot be
    decoded the raw text is returned unchanged and ``settings_json_error`` is
    set, so callers never lose data.
    """
    row = conn.execute(
        text("SELECT * FROM strategies WHERE tag = :tag"), {"tag": tag}
    ).mappings().first()
    if row is None:
        return None

    record = dict(row)
    raw = record.get("settings_json")
    if isinstance(raw, str) and raw:
        try:
            record["settings_json"] = json.loads(raw)
        except ValueError as exc:  # keep the raw text rather than dropping it
            record["settings_json_error"] = str(exc)
    return record


def query_strategies(
    conn: Connection,
    *,
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
    """Filtered, sorted, paginated strategies plus the unpaginated ``total``.

    ``symbol`` may be exact (``"@ES|1h"``) or a bare symbol (``"@ES"``) which
    matches every timeframe. ``min_metrics``/``max_metrics`` are keyed by metric
    column name (see ``metrics.describe()``), e.g. ``{"sharpe": 1.5}``.

    Column names are validated against whitelists; values are always bound
    parameters, never interpolated.
    """
    if sort not in SORTABLE_FIELDS:
        raise ValueError(f"cannot sort by {sort!r}; use one of: {', '.join(SORTABLE_FIELDS)}")
    direction = order.strip().lower()
    if direction not in ("asc", "desc"):
        raise ValueError("order must be 'asc' or 'desc'")

    clauses: list[str] = []
    params: dict[str, object] = {}

    if portfolio:
        clauses.append(EVER_SEEN_SQL if include_removed else CURRENT_MEMBERSHIP_SQL)
        params["portfolio"] = portfolio
    if strategy_type:
        clauses.append("lower(strategy_type) = lower(:strategy_type)")
        params["strategy_type"] = strategy_type
    if symbol:
        if "|" in symbol:
            clauses.append("symbol = :symbol")
            params["symbol"] = symbol
        else:
            clauses.append("symbol LIKE :symbol_prefix")
            params["symbol_prefix"] = f"{symbol}|%"
    if name_contains:
        clauses.append("(lower(entry_rules) LIKE :name OR lower(custom_name) LIKE :name)")
        params["name"] = f"%{name_contains.lower()}%"

    for filters, operator in ((min_metrics, ">="), (max_metrics, "<=")):
        for position, (metric, value) in enumerate((filters or {}).items()):
            if metric not in METRIC_COLUMNS:
                raise ValueError(
                    f"unknown metric {metric!r}; use one of: {', '.join(METRIC_COLUMNS)}"
                )
            key = f"m{position}"
            clauses.append(f"{metric} {operator} :{key}")
            params[key] = value

    where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
    total = conn.execute(text(f"SELECT COUNT(*) FROM strategies{where}"), params).scalar() or 0

    rows = conn.execute(
        text(
            f"SELECT {', '.join(QUERY_FIELDS)} FROM strategies{where} "
            f"ORDER BY {sort} {direction.upper()}, tag LIMIT :limit OFFSET :offset"
        ),
        {**params, "limit": max(1, min(int(limit), MAX_LIMIT)), "offset": max(0, int(offset))},
    ).mappings().all()

    return {
        "total": total,
        "limit": max(1, min(int(limit), MAX_LIMIT)),
        "offset": max(0, int(offset)),
        "sort": sort,
        "order": direction,
        "filters": {
            key: value
            for key, value in {
                "portfolio": portfolio,
                "symbol": symbol,
                "strategy_type": strategy_type,
                "name_contains": name_contains,
                "min_metrics": min_metrics or None,
                "max_metrics": max_metrics or None,
            }.items()
            if value
        },
        "rows": _with_portfolios(conn, [dict(row) for row in rows]),
    }


def _with_portfolios(conn: Connection, rows: list[dict]) -> list[dict]:
    """Attach each row's *current* portfolios and its ever-seen portfolios.

    ``portfolios`` = portfolios whose newest ok scan still lists the tag;
    ``portfolios_ever`` = the append-only ledger (includes portfolios the strategy
    has since been deleted from).
    """
    tags = [row["tag"] for row in rows]
    if not tags:
        return rows
    keys = {f"t{i}": tag for i, tag in enumerate(tags)}
    placeholders = ", ".join(f":{k}" for k in keys)

    current: dict[str, list[str]] = {tag: [] for tag in tags}
    for rec in conn.execute(
        text(
            "SELECT m.tag AS tag, s.portfolio AS portfolio "
            "FROM scan_memberships m JOIN portfolio_scans s ON s.id = m.scan_id "
            "JOIN (SELECT portfolio, MAX(id) AS id FROM portfolio_scans "
            "      WHERE ok = 1 GROUP BY portfolio) latest "
            "  ON latest.id = m.scan_id "
            f"WHERE m.tag IN ({placeholders}) ORDER BY s.portfolio"
        ),
        keys,
    ).mappings():
        current.setdefault(rec["tag"], []).append(rec["portfolio"])

    ever: dict[str, list[str]] = {tag: [] for tag in tags}
    for rec in conn.execute(
        text(
            f"SELECT tag, portfolio FROM strategy_portfolios "
            f"WHERE tag IN ({placeholders}) ORDER BY portfolio"
        ),
        keys,
    ).mappings():
        ever.setdefault(rec["tag"], []).append(rec["portfolio"])

    for row in rows:
        row["portfolios"] = current.get(row["tag"], [])
        row["portfolios_ever"] = ever.get(row["tag"], [])
    return rows


def list_portfolios(conn: Connection, include_removed: bool = False) -> list[dict]:
    """Portfolios with their membership count, taken from the newest ok scan.

    Each entry carries ``as_of`` (when that scan finished) and ``ok`` so a caller
    can tell how fresh the count is. ``removed`` is how many strategies the ledger
    knows about that the newest snapshot no longer lists. With
    ``include_removed=True`` the counts come from the append-only ledger instead
    (i.e. the old behaviour).
    """
    if include_removed:
        rows = conn.execute(
            text(
                "SELECT portfolio, COUNT(*) AS count, MAX(last_seen) AS last_seen "
                "FROM strategy_portfolios "
                "WHERE portfolio IS NOT NULL AND portfolio <> '' "
                "GROUP BY portfolio ORDER BY portfolio"
            )
        ).mappings().all()
        return [dict(row) for row in rows]

    rows = conn.execute(
        text(
            "SELECT s.portfolio AS portfolio, COUNT(m.tag) AS count, "
            "       COALESCE(s.finished_at, s.started_at) AS as_of, s.id AS scan_id, "
            "       s.ok AS ok "
            "FROM portfolio_scans s "
            "LEFT JOIN scan_memberships m ON m.scan_id = s.id "
            "JOIN (SELECT portfolio, MAX(id) AS id FROM portfolio_scans "
            "      WHERE ok = 1 GROUP BY portfolio) latest ON latest.id = s.id "
            "GROUP BY s.portfolio, s.id ORDER BY s.portfolio"
        )
    ).mappings().all()
    out = [dict(row) for row in rows]
    ever = {
        rec["portfolio"]: rec["count"]
        for rec in conn.execute(
            text(
                "SELECT portfolio, COUNT(*) AS count FROM strategy_portfolios "
                "WHERE portfolio IS NOT NULL AND portfolio <> '' GROUP BY portfolio"
            )
        ).mappings()
    }
    for rec in out:
        rec["removed"] = int(ever.get(rec["portfolio"], 0)) - int(rec["count"])
    return out


def _grouped(conn: Connection, column: str) -> list[dict]:
    rows = conn.execute(
        text(
            f"SELECT {column} AS value, COUNT(*) AS count FROM strategies "
            f"WHERE {column} IS NOT NULL GROUP BY {column} ORDER BY count DESC, value"
        )
    ).mappings().all()
    return [dict(row) for row in rows]


def cache_stats(conn: Connection) -> dict:
    """Shape of the cache: row counts, dimensions, coverage, schema revision.

    ``column`` names are literals from this module, never caller input.
    """
    scalar = lambda sql: conn.execute(text(sql)).scalar()  # noqa: E731 - one-liner
    rows = scalar("SELECT COUNT(*) FROM strategies") or 0
    return {
        "rows": rows,
        "schema_revision": scalar("SELECT version_num FROM alembic_version"),
        # dimensions use the ever-seen ledger: a single-strategy form capture is not a
        # portfolio snapshot, so it must not create or shrink a "current" membership
        "portfolios": list_portfolios(conn, include_removed=True),
        "portfolios_current": list_portfolios(conn),
        "symbols": _grouped(conn, "symbol"),
        "strategy_types": _grouped(conn, "strategy_type"),
        "first_seen": scalar("SELECT MIN(first_seen) FROM strategies"),
        "last_seen": scalar("SELECT MAX(last_seen) FROM strategies"),
        "logical_families": scalar(
            "SELECT COUNT(DISTINCT logical_hash) FROM strategies"
        ) or 0,
        "variant_hashes": scalar(
            "SELECT COUNT(DISTINCT variant_hash) FROM strategies"
        ) or 0,
        "largest_family": scalar(
            "SELECT MAX(n) FROM (SELECT COUNT(*) AS n FROM strategies "
            "GROUP BY logical_hash)"
        ) or 0,
    }
