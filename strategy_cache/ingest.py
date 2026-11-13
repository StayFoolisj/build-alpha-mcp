"""Ingest one BuildAlpha strategy (form-reader settings + optional grid metrics)."""
from __future__ import annotations

import argparse
import json
import logging
import sys

from . import db, parse
from .models import Settings
from .models import ValidationError as SettingsValidationError
from .normalize import compute_tags

log = logging.getLogger("strategy_cache")


def build_record(settings_path: str, grid_path: str | None) -> dict:
    fields, entry_rules, exit_rules = parse.read_form(settings_path)
    parts = parse.variant_parts(fields)

    grid: dict[str, str] = {}
    if grid_path:
        grid = parse.read_grid(grid_path)
        ident = parse.grid_identity(grid)
        if ident["symbol"]:
            parts["symbol"] = ident["symbol"]
        if ident["strategy_type"]:
            parts["strategy_type"] = ident["strategy_type"]
        parts["exit_params"] = ident["exit_params"]

    custom_name = None
    if grid.get("Name"):
        name, inline_rules = parse.split_name_and_rules(grid["Name"])
        custom_name = name
        if not entry_rules and inline_rules:
            entry_rules = [inline_rules]
    if not parts["exit_params"]:
        parts["exit_params"] = parse.exit_params_from_settings(fields, exit_rules)

    payload = dict(fields)
    payload.update(parts)
    payload["entry_rules"] = " ; ".join(entry_rules) if entry_rules else ""
    payload["exit_params"] = parts["exit_params"]

    settings = Settings.model_validate(payload)   # raises ValidationError

    tags = compute_tags(
        symbol=settings.symbol,
        strategy_type=settings.strategy_type,
        entry_rules=settings.entry_rules,
        exit_params=settings.exit_params,
        start_date=settings.start_date,
        stop_date=settings.stop_date,
        costs=settings.costs,
        sizing=settings.sizing,
        fitness=settings.fitness,
        is_oos=settings.is_oos,
    )
    record = {
        "tag": tags["tag"],
        "logical_hash": tags["logical_hash"],
        "variant_hash": tags["variant_hash"],
        "symbol": settings.symbol,
        "strategy_type": settings.strategy_type,
        "entry_rules": settings.entry_rules,
        "exit_params": settings.exit_params,
    }
    metrics = parse.metrics_from_grid(grid) if grid else {}
    return {
        "record": record,
        "tags": tags,
        "settings": settings,
        "custom_name": custom_name,
        "metrics": metrics,
        "grid": grid,
    }


def _identity(settings_path: str, grid_path: str | None) -> str:
    """Best-effort identity for the validation error log (no DB access)."""
    try:
        grid = parse.read_grid(grid_path) if grid_path else {}
        symbol = grid.get("Symbol") or ""
        name = (grid.get("Name") or "")[:60]
        return f"symbol={symbol!r} name={name!r} settings={settings_path}"
    except Exception:  # noqa: BLE001
        return f"settings={settings_path}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--portfolio", required=True)
    ap.add_argument("--settings", required=True, help="form-reader output file")
    ap.add_argument("--grid", help="grid-row capture file (column<TAB>value)")
    ap.add_argument("--db", default=None, help="SQLite URL (default env BA_CACHE_DB)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--as-new",
        action="store_true",
        help="treat this as a separate run artifact: suffix the tag on collision",
    )
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    try:
        built = build_record(args.settings, args.grid)
    except SettingsValidationError as exc:
        identity = _identity(args.settings, args.grid)
        log.error("settings validation failed, nothing written: %s", identity)
        for err in exc.errors():
            log.error("  %s: %s", ".".join(str(p) for p in err["loc"]), err["msg"])
        print(f"REJECTED settings validation: {identity}")
        return 2

    record = built["record"]
    settings = built["settings"]

    if args.dry_run:
        print(json.dumps({
            "tag": record["tag"],
            "logical_hash": record["logical_hash"],
            "symbol": record["symbol"],
            "strategy_type": record["strategy_type"],
            "settings_json": json.loads(settings.model_dump_json()),
            "metrics": built["metrics"],
        }, indent=2, ensure_ascii=False))
        return 0

    engine = db.make_engine(args.db)
    with engine.begin() as conn:
        result = db.upsert_strategy(
            conn,
            record=record,
            portfolio=args.portfolio,
            custom_name=built["custom_name"],
            settings=settings.model_dump_json(),
            metrics=built["metrics"],
            force_new=args.as_new,
        )
    print(f"{result['action']}: {result['tag']} (collisions={result['collisions']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
