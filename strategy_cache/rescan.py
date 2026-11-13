"""Rescan a portfolio into the cache without ever inserting or deleting a strategy row.

Why this exists
---------------
`grid_ingest.ingest` upserts by tag, and the tag is content-addressed. For a row that
carries a custom label the label is part of the hash (`"[name] <label>"`), so *renaming* a
strategy in BuildAlpha changes its tag - and a plain ingest would insert a new row and
leave the old one orphaned. A rescan is meant to refresh names and metrics, not to grow the
ledger, so this walks the rows with an explicit policy:

  matched by tag           -> refresh custom_name + metrics in place
  unknown tag, but exactly one cached member of this portfolio has the same
  (symbol, trades, net_pnl)  -> treat as a RENAME: update that row's name/metrics, keep tag
  anything else            -> skipped and reported (never inserted, never deleted)

Membership is still recorded as a normal scan snapshot (migration 0003), with `ok=1` only
when the parsed row count equals the grid's own row count.
"""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

from sqlalchemy import text

from . import db, grid_ingest, portfolio_sweep

METRIC_SQL = (
    "trade_count = :tc, sharpe = :sh, net_pnl = :pn, drawdown = :dd, "
    "drawdown_mtm = :ddm, win_rate = :wr, profit_factor = :pf, custom_name = :nm, "
    "last_seen = :t"
)


def _members_with_metrics(conn, portfolio: str) -> dict[str, dict]:
    scan = db.latest_scan(conn, portfolio)
    out: dict[str, dict] = {}
    if not scan:
        return out
    for m in db.scan_members(conn, scan["id"]):
        tag = m["tag"]
        r = conn.execute(
            text(
                "SELECT custom_name, entry_rules, variant_hash, trade_count, sharpe, "
                "net_pnl, drawdown, drawdown_mtm, win_rate, profit_factor, symbol "
                "FROM strategies WHERE tag = :t"
            ),
            {"t": tag},
        ).first()
        if r:
            out[tag] = {
                "name": r[0] or (r[1] or "")[:80],
                "variant_hash": r[2], "trades": r[3], "sharpe": r[4],
                "pnl": r[5], "drawdown": r[6], "drawdown_mtm": r[7],
                "win_rate": r[8], "profit_factor": r[9], "symbol": r[10],
            }
    return out


def rescan(portfolios: list[str], *, engine=None, rows_dir: Path | None = None,
           dry_run: bool = False, switch_timeout: int = 180,
           grid_timeout: int = 900) -> dict:
    engine = engine or db.make_engine()
    rows_dir = rows_dir or Path(tempfile.mkdtemp(prefix="rescan_"))
    report: dict = {"dry_run": dry_run, "portfolios": [], "rows_dir": str(rows_dir)}

    for portfolio in portfolios:
        entry: dict = {"portfolio": portfolio}
        with engine.connect() as conn:
            before = _members_with_metrics(conn, portfolio)
        entry["cached_members_before"] = len(before)

        sweep = portfolio_sweep.sweep([portfolio], rows_dir=rows_dir,
                                      dry_run=True, restore=True)
        captured = (sweep.get("portfolios") or [{}])[0]
        entry["capture"] = captured.get("capture")
        if not captured.get("capture"):
            entry["error"] = captured.get("error") or "no capture"
            report["portfolios"].append(entry)
            continue

        rows, meta = grid_ingest.read_grid(rows_dir / cached_name(rows_dir, captured))
        entry["grid_rows"] = len(rows)

        matched, renamed, skipped, ambiguous = [], [], [], []
        plan: list[tuple[str, dict, dict]] = []   # (tag, built, target)
        used: set[str] = set()
        for row in rows:
            built = grid_ingest.build_record(row, portfolio, "rescan")
            if not built:
                skipped.append({"name": (row.get("Name") or "")[:80], "why": "unusable row"})
                continue
            tag = built["record"]["tag"]
            name = built["custom_name"] or (row.get("Name") or "")[:80]
            if tag in before:
                matched.append({"tag": tag, "name": name, "old_name": before[tag]["name"]})
                plan.append((tag, built, before[tag]))
                used.add(tag)
                continue
            key = (built["metrics"].get("trade_count"),
                   round(built["metrics"].get("net_pnl") or 0.0, 2))
            cands = [t for t, info in before.items()
                     if t not in used
                     and (info["trades"], round(info["pnl"] or 0.0, 2)) == key]
            if len(cands) == 1:
                old = before[cands[0]]
                renamed.append({
                    "old_tag": cands[0], "old_name": old["name"], "new_name": name,
                    "computed_tag": tag, "trades": built["metrics"].get("trade_count"),
                    "sharpe": built["metrics"].get("sharpe"),
                    "pnl": built["metrics"].get("net_pnl"),
                    # did anything except the visible name move?
                    "tag_unchanged": True,
                    "variant_hash_unchanged": old["variant_hash"] == built["record"]["variant_hash"],
                    "trades_unchanged": old["trades"] == built["metrics"].get("trade_count"),
                    "sharpe_unchanged": old["sharpe"] == built["metrics"].get("sharpe"),
                    "pnl_unchanged": old["pnl"] == built["metrics"].get("net_pnl"),
                    "old_trades": old["trades"], "old_sharpe": old["sharpe"],
                    "old_pnl": old["pnl"],
                })
                plan.append((cands[0], built, old))
                used.add(cands[0])
            elif len(cands) > 1:
                ambiguous.append({"name": name, "candidates": cands,
                                  "candidate_names": [before[c]["name"] for c in cands]})
            else:
                skipped.append({"name": name, "why": "no cached row matches (not inserted)"})

        entry["matched_by_tag"] = len(matched)
        entry["renamed"] = len(renamed)
        entry["ambiguous"] = len(ambiguous)
        entry["skipped"] = len(skipped)
        entry["removed"] = len([t for t in before if t not in used])
        entry["details"] = {
            "renamed": renamed, "ambiguous": ambiguous,
            "skipped": skipped[:20],
            "removed_tags": [t for t in before if t not in used],
        }

        if not dry_run:
            # ok=1 only when what we parsed equals the count the grid itself declared;
            # the capture exposes that as top_level, and the header values arrive as
            # strings, so cast before comparing (102 == "102" is False).
            grid_rows = int(meta.get("grid_rows") or meta.get("top_level") or len(rows))
            with engine.begin() as conn:
                scan_id = db.start_scan(conn, portfolio, source="rescan")
                now = db.now_iso()
                for position, (tag, built, _old) in enumerate(plan):
                    m = built["metrics"]
                    conn.execute(
                        text(f"UPDATE strategies SET {METRIC_SQL} WHERE tag = :tag"),
                        {
                            "tc": m.get("trade_count"), "sh": m.get("sharpe"),
                            "pn": m.get("net_pnl"), "dd": m.get("drawdown"),
                            "ddm": m.get("drawdown_mtm"), "wr": m.get("win_rate"),
                            "pf": m.get("profit_factor"), "nm": built["custom_name"],
                            "t": now, "tag": tag,
                        },
                    )
                    db.add_scan_member(conn, scan_id, tag, position)
                db.finish_scan(conn, scan_id, captured_rows=len(rows),
                               grid_rows=grid_rows, ok=(len(rows) == grid_rows),
                               note=f"rescan matched={len(matched)} renamed={len(renamed)} "
                                    f"skipped={len(skipped)}")
            entry["scan_id"] = scan_id

        report["portfolios"].append(entry)
    return report


def cached_name(rows_dir: Path, captured: dict) -> str:
    return captured["capture"]


def duplicate_metrics(engine, portfolios: list[str], *, trades: float = 233,
                      sharpe: float = 1.22, tol_trades: float = 0.5,
                      tol_sharpe: float = 0.02) -> list[dict]:
    """Rows in these portfolios whose trades/Sharpe are indistinguishable from each other."""
    out = []
    with engine.connect() as conn:
        for portfolio in portfolios:
            scan = db.latest_scan(conn, portfolio)
            if not scan:
                continue
            for m in db.scan_members(conn, scan["id"]):
                r = conn.execute(
                    text("SELECT tag, custom_name, entry_rules, symbol, trade_count, sharpe, "
                         "net_pnl, drawdown FROM strategies WHERE tag = :t"),
                    {"t": m["tag"]},
                ).first()
                if not r or r[4] is None or r[5] is None:
                    continue
                if abs(float(r[4]) - trades) <= tol_trades and abs(float(r[5]) - sharpe) <= tol_sharpe:
                    out.append({"portfolio": portfolio, "tag": r[0], "name": r[1],
                                "entry_rules": (r[2] or "")[:70], "symbol": r[3],
                                "trades": r[4], "sharpe": r[5], "pnl": r[6],
                                "drawdown": r[7]})
    return out


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m strategy_cache.rescan",
                                     description="Refresh names/metrics without inserting rows")
    parser.add_argument("--only", nargs="+", required=True, metavar="NAME")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    report = rescan(args.only, dry_run=args.dry_run)
    report["duplicates_233_1_22"] = duplicate_metrics(db.make_engine(), args.only)
    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        for e in report["portfolios"]:
            print(f"{e['portfolio']}: rows={e.get('grid_rows')} cached={e['cached_members_before']} "
                  f"matched={e.get('matched_by_tag')} renamed={e.get('renamed')} "
                  f"ambiguous={e.get('ambiguous')} skipped={e.get('skipped')} "
                  f"removed={e.get('removed')} scan={e.get('scan_id')} err={e.get('error')}")
            for r in e["details"]["renamed"]:
                print(f"   RENAMED {r['old_tag']}: '{r['old_name']}' -> '{r['new_name']}'")
                print(f"      tag_unchanged={r['tag_unchanged']} variant_hash_unchanged={r['variant_hash_unchanged']} "
                      f"trades {r['old_trades']}->{r['trades']} ({r['trades_unchanged']}) "
                      f"sharpe {r['old_sharpe']}->{r['sharpe']} ({r['sharpe_unchanged']}) "
                      f"pnl {r['old_pnl']}->{r['pnl']} ({r['pnl_unchanged']})")
            for a in e["details"]["ambiguous"]:
                print(f"   AMBIGUOUS '{a['name']}' candidates={a['candidates']}")
        print("\nidentical-metric rows (233 trades / 1.22 sharpe):")
        for d in report["duplicates_233_1_22"]:
            print("  ", json.dumps(d, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
