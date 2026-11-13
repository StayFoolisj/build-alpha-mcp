"""Sweep every named BuildAlpha portfolio into the cache.

``Common Portfolio`` holds every strategy, so the bulk ingest is already a
superset of the inventory. What it cannot express is *which* portfolio lists a
strategy: the cache stores one ``portfolios`` row per location, and a strategy
that lives in ``Hyperliquid #2`` but not in ``Kraken`` is invisible until that
portfolio's grid has been read.

For each portfolio this driver:

1. switches the app with ``buildalpha_switch_portfolio.ps1`` and requires the
   switch to be confirmed (the popup is reopened and the selected item checked);
2. reads the top-level rows with ``buildalpha_grid_rows.ps1`` (GridPattern,
   no scrolling, no OCR) into ``grid-rows-<slug>.txt``;
3. ingests that capture with the portfolio name attached to every location,
   reusing the same tag scheme as the bulk ingest (insert-once /
   update-location / refresh metrics of existing grid rows).

The portfolio that was selected when the sweep started is restored at the end.

    uv run python -m strategy_cache.portfolio_sweep --dry-run
    uv run python -m strategy_cache.portfolio_sweep --only "Hyperliquid #2" "Lab"
    uv run python -m strategy_cache.portfolio_sweep            # all but Common

Exit codes: 0 ok, 2 capture/switch failure, 3 nothing selected.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from . import db, grid_ingest

#: Portfolios as named in the selector, in selector order.
ALL_PORTFOLIOS = [
    "Common Portfolio",
    "Robust",
    "2010",
    "Hyperliquid",
    "Thai SET",
    "XGL",
    "Kraken",
    "Training",
    "Hyperliquid #2",
    "Lab",
]

#: Common already holds everything, so it is skipped unless asked for.
DEFAULT_PORTFOLIOS = [p for p in ALL_PORTFOLIOS if p != "Common Portfolio"]


class SweepError(RuntimeError):
    """A switch or a grid capture did not produce a verifiable result."""


def slug(name: str) -> str:
    """Filesystem-safe tag for capture filenames (``Hyperliquid #2`` -> ``hyperliquid-2``)."""
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "portfolio"


def capture_name(name: str) -> str:
    return f"grid-rows-{slug(name)}.txt"


def _run(cmd: list[str], timeout: int) -> str:
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        encoding="utf-8",
        errors="replace",
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        raise SweepError(f"{Path(cmd[-1]).name if cmd else 'command'} failed ({proc.returncode}): {out.strip()[:400]}")
    return out


def list_portfolios(switch_script: Path, timeout: int) -> list[tuple[str, bool]]:
    """[(name, selected)] straight from the app's selector popup."""
    out = _run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(switch_script), "-List"], timeout)
    found: list[tuple[str, bool]] = []
    for line in out.splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 3 and parts[0] == "PORTS":
            found.append((parts[1], parts[2].strip().lower() == "true"))
    if not found:
        raise SweepError(f"could not read the portfolio selector: {out.strip()[:400]}")
    return found


def current_portfolio(switch_script: Path, timeout: int) -> str:
    selected = [name for name, on in list_portfolios(switch_script, timeout) if on]
    if not selected:
        raise SweepError("no portfolio reports IsSelected=true")
    return selected[0]


def switch_to(switch_script: Path, name: str, timeout: int, *, keep_topmost: bool = False) -> None:
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", str(switch_script), "-Name", name, "-TimeoutSec", "30"]
    if keep_topmost:
        cmd.append("-KeepTopmost")
    out = _run(cmd, timeout)
    if "SWITCHED" not in out:
        raise SweepError(f"switch to {name!r} not confirmed: {out.strip()[:400]}")


def capture(grid_script: Path, name: str, out_dir: Path, timeout: int, attempts: int = 3,
            previous_sig: str | None = None) -> tuple[Path, dict]:
    """Read one portfolio's grid and refuse anything that cannot be trusted.

    The capture must come from the main window (the reader enforces that itself
    and records `window=`), and its `sig` (SHA1 over Symbol|Type|Name) must
    differ from the previous portfolio's: switching portfolios reloads the grid
    asynchronously, and a capture taken too early reads the previous portfolio.
    That is how 67 Common Portfolio rows once landed in Hyperliquid #2.
    """
    target = out_dir / capture_name(name)
    last = ""
    for attempt in range(1, attempts + 1):
        out = _run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(grid_script), "-OutFile", str(target), "-Portfolio", slug(name)],
                   timeout)
        if "GRID_OK" not in out:
            last = out.strip()[:300]
            time.sleep(5)
            continue
        rows, meta = grid_ingest.read_grid(target)
        window = meta.get("window", "").replace("_", " ")
        if not window.startswith("Build Alpha"):
            raise SweepError(f"captured from the wrong window: {window!r}")
        sig = meta.get("sig", "")
        if previous_sig is not None and sig and sig == previous_sig:
            last = f"grid did not change after switching to {name!r} (sig={sig})"
            time.sleep(3)
            continue
        return target, {"rows": rows, "meta": meta, "attempt": attempt, "sig": sig}
    raise SweepError(f"grid capture for {name!r} failed: {last}")


def sweep(
    names: list[str],
    *,
    rows_dir: Path = Path("captures"),
    switch_script: Path | None = None,
    grid_script: Path | None = None,
    switch_timeout: int = 180,
    grid_timeout: int = 900,
    restore: bool = True,
    dry_run: bool = False,
    engine=None,
) -> dict:
    here = Path(__file__).resolve().parent.parent
    # The in-process wrapper (UI guard + Set-PortfolioVerified). The old switch script resized the
    # window and could leave it pinned when it exited early - measured: a sweep left Build Alpha
    # smaller and topmost over the operator's desktop.
    switch_script = Path(switch_script or here / "scripts" / "buildalpha_set_portfolio.ps1")
    grid_script = Path(grid_script or here / "scripts" / "buildalpha_grid_rows.ps1")
    rows_dir = Path(rows_dir)

    available = list_portfolios(switch_script, switch_timeout)
    start = [name for name, on in available if on]
    start = start[0] if start else None
    print(f"selected: {start}", file=sys.stderr)

    report: dict = {"selected_before": start, "portfolios": [], "totals": {}}
    totals = {"insert": 0, "refresh": 0, "update": 0, "skipped": 0, "rows": 0}
    engine = engine or (None if dry_run else db.make_engine())

    try:
        previous_sig: str | None = None
        for name in names:
            entry: dict = {"portfolio": name}
            try:
                # Switch in dry runs too: a dry run means "write nothing to the cache", not
                # "capture the portfolio that happens to be selected". Skipping the switch
                # here captured the already-selected grid under every name, which reported
                # the same rows as a different portfolio and zero matching tags.
                if name != start:
                    switch_to(switch_script, name, switch_timeout, keep_topmost=True)
                    entry["switched"] = True
                captured = capture(grid_script, name, rows_dir, grid_timeout, previous_sig=previous_sig)
                path, payload = captured
                rows, meta = payload["rows"], payload["meta"]
                previous_sig = payload.get("sig") or None
                entry.update(
                    capture=path.name,
                    grid_rows=len(rows),
                    declared_top_level=meta.get("top_level"),
                    unread=meta.get("unread"),
                    sig=meta.get("sig"),
                    window=meta.get("window"),
                )
                if dry_run:
                    entry["dry_run"] = True
                else:
                    stats = grid_ingest.ingest(
                        engine, rows, name, path.name, refresh=True,
                        grid_rows=meta.get("grid_rows"),
                    )
                    stats.pop("tags", None)
                    entry["ingest"] = stats
                    for key in ("insert", "refresh", "update", "skipped"):
                        totals[key] += int(stats.get(key, 0))
                    totals["rows"] += len(rows)
            except (SweepError, subprocess.TimeoutExpired, grid_ingest.GridError) as exc:
                entry["error"] = str(exc)
            report["portfolios"].append(entry)
            state = entry.get("error") or entry.get("ingest") or "captured"
            print(f"{name}: {state}", file=sys.stderr)
    finally:
        if restore and start:
            try:
                still = current_portfolio(switch_script, switch_timeout)
                if still != start:
                    switch_to(switch_script, start, switch_timeout)
            except SweepError as exc:  # restore is best-effort; report, do not mask
                report["restore_error"] = str(exc)

    report["totals"] = totals
    return report


def _require_ui_ready(guard_script: Path, timeout: int = 30) -> str:
    """Ask the PowerShell guard before the sweep touches the desktop.

    The children are guarded individually too (grid_rows refuses without the foreground), but
    failing here means nothing is switched, resized or clicked at all.
    """
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(guard_script),
         "-Name", "__probe__", "-List"],
        capture_output=True, text=True, timeout=timeout,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if "PORTS" in out or "NO_DROPDOWN" in out:
        return "OK"
    if "UI_BUSY" in out:
        return "UI_BUSY"
    if "BUILDALPHA_NOT_RUNNING" in out:
        return "NOT_RUNNING"
    return "UNKNOWN: " + out.strip()[-200:]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m strategy_cache.portfolio_sweep",
        description="Switch through BuildAlpha's portfolios and ingest each grid.",
    )
    parser.add_argument("--only", nargs="+", metavar="NAME", help="portfolios to sweep")
    parser.add_argument("--include-common", action="store_true", help="also sweep Common Portfolio")
    parser.add_argument(
        "--retain", type=int, default=0, metavar="N",
        help="keep only the newest N scans per portfolio (the first scan is always kept as "
             "the diff baseline); 0 keeps every scan",
    )
    parser.add_argument("--rows-dir", default="captures", help="where per-portfolio captures are written")
    parser.add_argument("--switch-script", default=None)
    parser.add_argument("--grid-script", default=None)
    parser.add_argument("--switch-timeout", type=int, default=180)
    parser.add_argument("--grid-timeout", type=int, default=900)
    parser.add_argument("--no-restore", action="store_true", help="leave the last portfolio selected")
    parser.add_argument("--dry-run", action="store_true", help="capture only, write nothing")
    args = parser.parse_args(argv)

    names = args.only or (DEFAULT_PORTFOLIOS if not args.include_common else ALL_PORTFOLIOS)

    try:
        report = sweep(
            names,
            rows_dir=Path(args.rows_dir),
            switch_script=Path(args.switch_script) if args.switch_script else None,
            grid_script=Path(args.grid_script) if args.grid_script else None,
            switch_timeout=args.switch_timeout,
            grid_timeout=args.grid_timeout,
            restore=not args.no_restore,
            dry_run=args.dry_run,
        )
    except (SweepError, subprocess.TimeoutExpired) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.retain and not args.dry_run:
        kept = {}
        with db.make_engine().begin() as conn:
            for name in names:
                kept[name] = db.prune_scans(conn, name, args.retain)
        report["retention"] = kept

    print(json.dumps(report, indent=2))
    failed = [p for p in report["portfolios"] if p.get("error")]
    return 2 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
