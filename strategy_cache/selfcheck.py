"""Runnable sanity checks: normalisation, tag determinism, insert/update/collision.

    uv run python -m strategy_cache.selfcheck
"""
from __future__ import annotations

import os
import tempfile

from alembic import command
from alembic.config import Config
from sqlalchemy import text

from . import db
from .normalize import compute_tags, normalize_date, normalize_number, normalize_symbol


def check_normalisation() -> None:
    assert normalize_symbol("SOLUSD (15 minutes)") == "SOLUSD|15m"
    assert normalize_symbol("SOLUSD_15m") == "SOLUSD|15m"
    assert normalize_symbol("XXBTZUSD (1 hour)") == "XXBTZUSD|1h"
    assert normalize_date("12/31/2023 5:00:00 PM") == "2023-12-31"
    assert normalize_date("6/30/2026 5:00:00 AM") == "2026-06-30"
    assert normalize_number("0.0015999999595806") == "0.0016"
    assert normalize_number("7.000") == "7"
    assert normalize_number("0") == "0"


def _tags(**over):
    base = dict(
        symbol="SOLUSD_15m",
        strategy_type="Long",
        entry_rules=["High[1] > Low[9]"],
        exit_params="PT 3.00 atr",
        start_date="12/31/2023 5:00:00 PM",
        stop_date="6/30/2026 5:00:00 AM",
        costs="commission=0.0028",
        sizing="mode=Volatility ATR",
        fitness="PNLDD",
        is_oos="oos_pct=0.3",
    )
    base.update(over)
    return compute_tags(**base)


def check_tags() -> None:
    a = _tags()
    b = _tags()
    assert a["tag"] == b["tag"] and a["variant_hash"] == b["variant_hash"]
    assert len(a["tag"]) == 10
    assert _tags(stop_date="6/29/2026 5:00:00 AM")["tag"] != a["tag"]      # different window
    assert _tags(stop_date="6/30/2026 1:30:00 PM")["tag"] == a["tag"]      # same date, time dropped
    assert _tags(entry_rules=["High[1] > Low[8]"])["tag"] != a["tag"]      # different rules
    assert _tags(costs="commission=0.002")["tag"] != a["tag"]              # different costs
    assert _tags(stop_date="6/29/2026 5:00:00 AM")["logical_hash"] == a["logical_hash"]


def _tmp_db() -> str:
    tmp = tempfile.mkdtemp(prefix="ba_cache_")
    path = os.path.join(tmp, "cache.sqlite3")
    os.environ["BA_CACHE_URL"] = f"sqlite:///{path}"
    cfg = Config("alembic.ini")
    cfg.set_main_option("script_location", "migrations")
    command.upgrade(cfg, "head")
    return path


def _record(tag: str, variant_hash: str) -> dict:
    return {
        "tag": tag,
        "logical_hash": "lh-hash",
        "variant_hash": variant_hash,
        "symbol": "SOLUSD|15m",
        "strategy_type": "Long",
        "entry_rules": "High[1] > Low[9]",
        "exit_params": "PT 3.00 atr",
    }


def check_upsert() -> None:
    path = _tmp_db()
    engine = db.make_engine(f"sqlite:///{path}")
    with engine.begin() as conn:
        first = db.upsert_strategy(
            conn, record=_record("abc1234567", "v1"), portfolio="Kraken",
            custom_name=None, settings={"a": 1}, metrics={"sharpe": 1.5, "trade_count": 7},
        )
        assert first["action"] == "insert", first

        again = db.upsert_strategy(
            conn, record=_record("abc1234567", "v1"), portfolio="Robust",
            custom_name="renamed", settings={"a": 999}, metrics={"sharpe": 9.9},
        )
        assert again["action"] == "update" and again["tag"] == "abc1234567", again

        row = conn.execute(text("select * from strategies where tag='abc1234567'")).mappings().one()
        assert row["portfolio"] == "Robust"
        assert row["custom_name"] == "renamed"
        assert row["sharpe"] == 1.5 and row["trade_count"] == 7      # metrics immutable
        assert row["settings_json"] == '{"a": 1}'                    # settings immutable

        collide = db.upsert_strategy(
            conn, record=_record("abc1234567", "v2"), portfolio="Kraken",
            custom_name=None, settings={}, metrics={},
        )
        assert collide["tag"] == "abc1234567-2" and collide["collisions"] == 1, collide

        known = db.upsert_strategy(
            conn, record=_record("abc1234567", "v2"), portfolio="Lab",
            custom_name=None, settings={}, metrics={},
        )
        assert known["tag"] == "abc1234567-2" and known["action"] == "update", known


def main() -> int:
    check_normalisation()
    check_tags()
    check_upsert()
    print("PASS normalisation, tag determinism, insert/update/collision")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
