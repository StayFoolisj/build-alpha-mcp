"""Decide how to find one strategy's row in BuildAlpha's live grid.

One place for the answer to "which string do we search with, and what happens when that
finds nothing". Every tool that has to point at a row uses this, so a fix here is a fix for
all of them.

The strategy is deliberately short:

    name  = custom_name (or the caller's name)
    if name:  filter by name; if it lands on one row and the numbers agree -> done
    filter by symbol; disambiguate by trades, then Sharpe, then P&L

Nothing is fatal along the way: a name that matches nothing is one recorded attempt, not an
error, and the caller still gets the symbol route.
"""

from __future__ import annotations

import re

__all__ = ["IdentifyError", "plan", "is_searchable_name", "RULE_MARKERS"]


class IdentifyError(Exception):
    """No row can be searched for at all (unknown tag, no symbol, not in that portfolio)."""

    def __init__(self, status: str, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


# Text that a grid find box cannot be used with. A rule expression carries brackets, commas
# and comparisons; DevExpress leaves the grid untouched rather than returning nothing, which
# looks like "filter did nothing" and used to be reported as a missing grid.
RULE_MARKERS = re.compile(r"[\[\]()<>=,]|\bAND\b|\bOR\b|\bclose\b|\bopen\b|\bhigh\b|\blow\b|\bTime\b")


def is_searchable_name(text: str | None) -> bool:
    """True when the text is a name a find box can actually filter on."""
    text = (text or "").strip()
    if not text:
        return False
    if RULE_MARKERS.search(text):
        return False
    return len(text) >= 3


def plan(conn, tag: str = "", run_id: str = "", name: str = "", portfolio: str = "") -> dict:
    """Cache -> an ordered list of ways to find the row, with the numbers to verify it by."""
    from sqlalchemy import text

    from . import queries, runlog

    if not tag and not run_id:
        raise IdentifyError("TAG_NOT_FOUND", "one of tag or run_id is required")

    record = None
    if run_id:
        record = runlog.load_run(run_id)
        if record is None:
            raise IdentifyError("TAG_NOT_FOUND", f"unknown run_id {run_id!r} (no journal record)")
        args = record.get("args") or {}
        tag = (record.get("tag") or args.get("tag") or "").strip()
        if not tag:
            raise IdentifyError("TAG_NOT_FOUND", f"run {run_id!r} carries no tag")

    row = queries.get_strategy(conn, tag)
    if row is None:
        raise IdentifyError("TAG_NOT_FOUND", f"unknown tag {tag!r}")

    symbol_full = (row.get("symbol") or "").strip()
    if not symbol_full:
        raise IdentifyError(
            "IDENTITY_MISMATCH",
            f"{tag} has no symbol in the cache; nothing to match a grid row against",
        )
    symbol = symbol_full.split("|")[0]

    portfolios = [
        r[0]
        for r in conn.execute(
            text("SELECT portfolio FROM strategy_portfolios WHERE tag = :t ORDER BY portfolio"),
            {"t": tag},
        )
    ]
    target_portfolio = portfolio or (portfolios[0] if portfolios else (row.get("portfolio") or ""))
    if portfolio and portfolios and portfolio not in portfolios:
        raise IdentifyError(
            "PORTFOLIO_MISMATCH",
            f"{tag} is not in {portfolio!r} (it is in: {', '.join(portfolios)})",
        )

    # A re-run's own numbers are not the portfolio's, so its metrics may not be compared. They
    # are only usable as a search key when the run never resolved a row and fell back to the cache.
    expected = {"trades": row.get("trade_count"),
                "sharpe": row.get("sharpe"),
                "net_pnl": row.get("net_pnl")}
    if run_id and (record.get("result") or {}).get("resolved"):
        expected = {"trades": None, "sharpe": None, "net_pnl": None}

    candidates: list[dict] = []
    seen: set[str] = set()

    def add(kind: str, value, source: str, search: str) -> None:
        """One way to reach the row, with the exact text to type into the find box.

        `search` is separate from `value` on purpose: the metrics candidate carries the numbers
        to verify against, but the text typed is the single most selective one - the Net P&L.
        """
        key = f"{kind}:{search}"
        if key in seen:
            return
        seen.add(key)
        candidates.append({"kind": kind, "value": value, "source": source, "search": search})

    # Order: most selective single field first, cheapest-to-recover last.
    # 1. Net P&L. Measured over the 427 rows of Common Portfolio: 416 distinct values, so one
    #    typed number usually leaves a single row - one filter application, no scanning.
    if expected.get("net_pnl") is not None:
        add("metrics", {"symbol": symbol, **expected}, "cache", f"{float(expected['net_pnl']):.2f}")
    # 2. what the caller dictated, e.g. a human label that is not in the cache
    if (name or "").strip():
        add("name", name.strip(), "caller", name.strip())
    # 3. the name the cache holds, if it is a name and not a rule expression
    cached_name = (row.get("custom_name") or "").strip()
    if is_searchable_name(cached_name):
        add("name", cached_name, "cache", cached_name)
    # 4. the symbol: never empty, but leaves every strategy of that symbol - the scan is short
    #    and the metrics still decide. This is the fallback when the cached numbers are stale.
    add("symbol", symbol, "cache", symbol)

    return {
        "tag": tag,
        "run_id": run_id or None,
        "portfolio": target_portfolio,
        "portfolios": portfolios,
        "symbol": symbol,
        "symbol_full": symbol_full,
        "expected": expected,
        "candidates": candidates,
        # Whether a *cached* name could be used is a fact about the cache, not about the order:
        # the first candidate is the Net P&L now, so keying this off candidates[0] reported
        # "not searchable" for names that were perfectly usable.
        "reason_name_absent": (
            None if is_searchable_name(cached_name)
            else ("no custom_name" if not cached_name else "custom_name is not searchable")
        ),
    }
