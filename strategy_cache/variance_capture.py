"""Screenshot the Variance Testing view for one strategy or one re-run.

Wraps ``scripts/buildalpha_capture_view.ps1``, which opens one of BuildAlpha's right-hand
navigation item *Variance Testing*, waits for the dialog, captures the client area and
writes a PNG.

Two things matter for callers:

* **The file is the durable record, the image block is a convenience.** The path and a
  sha256 are always reported, so a caller that dropped the image can still read it, and a
  caller that kept the image can prove it is the same file.
* **The dialog is left open on success and closed on failure.** Opening it costs a
  couple of seconds and the next call closes it anyway; leaving it open after a failure
  would hand the next call a window showing the wrong strategy.
"""
from __future__ import annotations

import base64
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCRIPT = ROOT / "scripts" / "buildalpha_capture_view.ps1"

#: view name -> (nav button name is resolved in the script, file suffix here)
VIEWS = {
    "variance": {"view": "Variance Testing", "button": None, "suffix": "-variance.png"},
    "mc": {"view": "MC Analysis", "button": "Resample", "suffix": "-mc.png"},
    # The draw-down window is titled 'Monte Carlo Drawdown - Cumulative results': no button to
    # press, and no row name in the title to match against.
    "mcdd": {"view": "Monte Carlo Draw Down", "button": None, "suffix": "-mcdd.png"},
    # Metrics is a 5 x 4 grid of plots; the script crops the client area to the top-left cell,
    # which holds E-Ratio, so the saved file is one panel rather than sixteen.
    "eratio": {"view": "Metrics", "button": None, "suffix": "-eratio.png"},
}
CAPTURES_DIR = ROOT / "captures"
SCREENS_DIR = CAPTURES_DIR / "screens"

#: script verdict -> tool status. The script prints one, this maps the exit code as a
#: fallback when the JSON line is missing entirely.
STATUS_BY_EXIT = {
    0: "OK",
    1: "CAPTURE_FAILED",
    2: "TAG_NOT_FOUND",
    5: "PORTFOLIO_SWITCH_FAILED",
    6: "MENU_ITEM_MISSING",
    17: "WINDOW_NOT_FOUND",
    20: "IDENTITY_MISMATCH",
    25: "INPUT_BLOCKED",
    28: "TIMEOUT",
    30: "GRID_NOT_VISIBLE",
    # the UI lock is held by another call: nothing was touched, trying again later is correct
    40: "BUSY",
}

#: width the reply must never exceed (a vision model's comfortable input size)
MAX_WIDTH = 1568


class CaptureError(RuntimeError):
    """A capture could not be attempted at all (bad arguments, missing script)."""


def resolve(conn, tag: str = "", run_id: str = "", portfolio: str = "") -> dict:
    """\`\`tag\`\` or \`\`run_id\`\` -> everything the script needs to find the row.

    A tag is resolved to its exact grid Name plus the cached metrics, which the script
    then re-checks on the row itself: a namesake with different numbers stops the call
    with IDENTITY_MISMATCH instead of screenshotting the wrong strategy.

    A run_id is a journalled re-run: its record already names the tag and the row, and the
    re-run's own numbers are not the portfolio's, so no metric comparison is made.
    """
    from . import rerun_adjust, runlog

    if run_id:
        record = runlog.load_run(run_id)
        if record is None:
            raise CaptureError(f"unknown run_id {run_id!r} (no journal record)")
        args = record.get("args") or {}
        run_tag = (record.get("tag") or args.get("tag") or "").strip()
        result = record.get("result") or {}
        resolved = result.get("resolved") or {}
        symbol = (resolved.get("symbol") or result.get("server_symbol") or "").strip()
        row = (resolved.get("name") or "").strip()
        if not run_tag:
            raise CaptureError(f"run {run_id!r} carries no tag")
        if not row or not symbol:
            # the run never resolved a row (it failed early): fall back to the cache
            try:
                cached = rerun_adjust.resolve(conn, run_tag, portfolio)
            except rerun_adjust.AdjustError as exc:
                raise CaptureError(str(exc)) from exc
            row = row or cached["name"]
            symbol = symbol or cached["symbol"]
        return {
            "tag": run_tag, "run_id": run_id, "row": row, "symbol": symbol,
            "portfolio": portfolio or resolved.get("portfolio") or "",
            "expected": None,          # a re-run's metrics are not the portfolio's
        }

    tag = (tag or "").strip()
    if not tag:
        raise CaptureError("one of tag or run_id is required")
    try:
        cached = rerun_adjust.resolve(conn, tag, portfolio)
    except rerun_adjust.AdjustError as exc:
        raise CaptureError(str(exc)) from exc
    return {
        "tag": tag, "run_id": None, "row": cached["name"], "symbol": cached["symbol"],
        "portfolio": cached["portfolio"], "expected": cached.get("expected") or {},
    }


def build_args(target: dict, out_path: Path, timeout_sec: int = 30,
               view: str = "variance", button: str | None = None,
               plan_path: Path | None = None) -> list[str]:
    """Target + which view -> the shared script's command line."""
    spec = VIEWS[view]
    if button is None:
        button = spec["button"]
    expected = target.get("expected") or {}
    args = [
        "-Tag", target["tag"],
        "-ExpectName", target["row"],
        "-ExpectSymbol", (target["symbol"] or "").split("-")[0],
        "-Out", str(out_path),
        "-TimeoutSec", str(max(5, int(timeout_sec))),
        "-MaxWidth", str(MAX_WIDTH),
        "-View", spec["view"],
        "-Suffix", spec["suffix"],
    ]
    if plan_path:
        # the shared row search: strategy_cache.identify.plan() written to disk
        args += ["-PlanFile", str(plan_path)]
    if button:
        args += ["-Button", button]
    if target.get("run_id"):
        args += ["-RunId", target["run_id"]]
    if target.get("portfolio"):
        args += ["-Portfolio", target["portfolio"]]
    # metrics only matter for the cache identity check; a re-run's row numbers differ
    if expected:
        for flag, key, default in (("-ExpectedTrades", "trades", -1),
                                   ("-ExpectedSharpe", "sharpe", -1),
                                   ("-ExpectedPnl", "net_pnl", -1)):
            value = expected.get(key)
            args += [flag, str(default if value is None else value)]
    return args


class CaptureTimeout(CaptureError):
    """The script was killed at its deadline; carries whatever it had printed by then."""

    def __init__(self, message: str, stages: list[dict] | None = None,
                 last_stage: str | None = None, tail: str = "") -> None:
        super().__init__(message)
        self.stages = stages or []
        self.last_stage = last_stage
        self.tail = tail


def _text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def stages(*outputs) -> list[dict]:
    """Every STAGE line the script wrote, in order. stderr carries them; stdout is the reply."""
    found: list[dict] = []
    for blob in outputs:
        for line in (_text(blob)).splitlines():
            line = line.strip()
            if not line.startswith("STAGE "):
                continue
            try:
                found.append(json.loads(line[len("STAGE "):]))
            except ValueError:
                continue
    return found


def last_stage(*outputs) -> str | None:
    found = stages(*outputs)
    if not found:
        return None
    # the last *started* stage: a 'done' marker closes it, so the hang is the one after it
    for entry in reversed(found):
        if not entry.get("done"):
            return entry.get("stage")
    return found[-1].get("stage")


def run(args: list[str], timeout_sec: int = 30, script: Path | None = None) -> subprocess.CompletedProcess:
    """Run the capture script. The subprocess gets a hard deadline of its own budget."""
    script = script or DEFAULT_SCRIPT
    if not script.is_file():
        raise CaptureError(f"script not found: {script}")
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *args]
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=max(20, int(timeout_sec) + 25),   # script budget + resolution slack
        )
    except subprocess.TimeoutExpired as exc:
        # Keep what the child had already said. A timeout used to raise with the command line only,
        # so the log could say "it timed out" and nothing else - the most expensive failure gave
        # the least information. The script names its stage on stderr before each step, so the last
        # STAGE line is the step that hung.
        out = _text(exc.stdout)
        err = _text(exc.stderr)
        raise CaptureTimeout(
            f"capture timed out after {timeout_sec}s"
            + (f" during stage '{last_stage(out, err)}'" if last_stage(out, err) else ""),
            stages=stages(out, err), last_stage=last_stage(out, err), tail=err[-600:],
        ) from exc


def parse(proc: subprocess.CompletedProcess) -> dict | None:
    """The script's CAPTURE line, if it printed one."""
    for line in reversed((proc.stdout or "").splitlines()):
        line = line.strip()
        if line.startswith("CAPTURE "):
            try:
                return json.loads(line[len("CAPTURE "):])
            except ValueError:
                return None
    return None


def summarize(proc: subprocess.CompletedProcess, target: dict | None = None,
              include_view_fields: bool = False) -> dict:
    """Script output -> the tool's reply payload (no image data in here)."""
    payload = parse(proc)
    if payload is None:
        status = STATUS_BY_EXIT.get(proc.returncode, "CAPTURE_FAILED")
        return {
            "status": status,
            "target": _target_view(target),
            "path": None, "bytes": 0, "sha256": None, "width": 0, "height": 0,
            "format": "png", "downscaled_from": 0, "title": None,
            "accelerator_used": None, "image_included": False,
            "image_omitted_reason": ("NOT_FOUND" if status == "TAG_NOT_FOUND" else None),
            "duration_ms": None,
            "detail": (proc.stderr or proc.stdout or "").strip()[-600:] or "no CAPTURE line",
            "stages": stages(proc.stdout, proc.stderr),
            "last_stage": last_stage(proc.stdout, proc.stderr),
        }

    status = payload.get("status") or "CAPTURE_FAILED"
    reply = {
        "status": status,
        "target": {
            "tag": payload.get("tag") or (target or {}).get("tag"),
            "run_id": payload.get("run_id") or (target or {}).get("run_id"),
            "row": payload.get("row") or (target or {}).get("row"),
            "symbol": payload.get("symbol") or (target or {}).get("symbol"),
        },
        "path": payload.get("path") or None,
        "bytes": int(payload.get("bytes") or 0),
        "sha256": payload.get("sha256") or None,
        "width": int(payload.get("width") or 0),
        "height": int(payload.get("height") or 0),
        "format": payload.get("format") or "png",
        "downscaled_from": int(payload.get("downscaled_from") or 0),
        "title": payload.get("title") or None,
        # present only for views that crop to a single cell
        **({"crop": payload["crop"]} if payload.get("crop") else {}),
        "accelerator_used": payload.get("accelerator_used"),
        "dialog_closed": bool(payload.get("dialog_closed")),
        **({"view": payload.get("view"),
            "view_opened_by": payload.get("view_opened_by")}
           # Only when a button was actually clicked: a view with no button (draw down) must
           # not carry an always-null field.
           | ({"button_clicked": payload["button_clicked"]}
              if payload.get("button_clicked") else {})
           if include_view_fields else {}),
        "portfolio": payload.get("loaded_portfolio") or None,
        "portfolio_switched": bool(payload.get("portfolio_switched")),
        # what the grid actually held, so a mismatch shows whether the screen or the name was
        # wrong: the loaded portfolio, how many rows it had, and two sample Name values
        "grid": {
            "portfolio": payload.get("loaded_portfolio") or None,
            "rows": int(payload.get("grid_rows") or 0),
            "filtered_rows": int(payload.get("filtered_rows") or 0),
            "filter": payload.get("filter") or None,
            "sample_names": list(payload.get("sample_names") or []),
        },
        "image_included": False,
        # a lookup failure is not a capture fault, so it gets its own reason; any other
        # failure leaves the field null and lets status carry the meaning
        "image_omitted_reason": "NOT_FOUND" if status == "TAG_NOT_FOUND" else None,
        "duration_ms": payload.get("duration_ms"),
        "detail": payload.get("detail") or "",
        # where the time went: one entry per step, in order. Also the only thing that says which
        # step a killed call had reached.
        "stages": payload.get("stages") or [],
        "last_stage": payload.get("last_stage") or None,
        # What the identity decision was made from. An IDENTITY_MISMATCH is only diagnosable if
        # the inputs are recorded: which text went into the find box, which candidate kind matched,
        # what each attempt saw, and what numbers were expected within which tolerance.
        "decision": {
            "filter": payload.get("filter") or None,
            # the search writes `row_match`; older replies called it `plan_matched_by`
            "matched_by": payload.get("row_match") or payload.get("plan_matched_by") or None,
            "candidates": payload.get("plan_candidates") or [],
            "attempts": (payload.get("attempts") or [])[:8],
            "expect_name": payload.get("expect_name") or None,
            "expect_symbol": payload.get("expect_symbol") or None,
            "expected": payload.get("plan_expected") or {},
            "tolerances": {"trades": 0.5, "sharpe": 0.02, "net_pl": 0.5},
        },
        # What the call quietly did behind the answer: which windows it closed, whether it reused an
        # existing results window, whether it resized the view. Silent behaviour is what made the
        # earlier wrong-capture bugs so hard to see.
        "lifecycle": {
            "closed_preexisting": int(payload.get("closed_preexisting") or 0),
            "dialog_closed": bool(payload.get("dialog_closed")),
            "rerun_reused": bool(payload.get("rerun_reused")),
            "reuse_row": payload.get("reuse_row") or None,
            "view_resized": payload.get("view_resized") or None,
        },
        **({"env": payload["env"]} if payload.get("env") else {}),
    }
    return reply


def _target_view(target: dict | None) -> dict:
    target = target or {}
    return {"tag": target.get("tag"), "run_id": target.get("run_id"),
            "row": target.get("row"), "symbol": target.get("symbol")}


def read_image(reply: dict) -> tuple[str, int] | None:
    """(base64 payload, byte size) for the reply's file, or None when there is no file.

    The sha256 is recomputed here and compared with the one the script reported: a file
    that changed between capture and encode would make the reply's own claim false.
    """
    path = reply.get("path")
    if not path:
        return None
    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if reply.get("sha256") and digest != reply["sha256"]:
        raise CaptureError(f"file changed after capture (sha256 {digest[:12]} != {reply['sha256'][:12]})")
    if reply.get("bytes") and len(data) != reply["bytes"]:
        raise CaptureError(f"file size changed after capture ({len(data)} != {reply['bytes']})")
    return base64.b64encode(data).decode(), len(data)


def apply_size_cap(reply: dict, encoded_len: int, max_image_bytes: int) -> bool:
    """Mark the reply SIZE_CAP and drop the image when it is too large. Returns include."""
    if encoded_len <= max_image_bytes:
        return True
    reply["image_included"] = False
    reply["image_omitted_reason"] = "SIZE_CAP"
    reply["status"] = "SIZE_CAP"
    reply["detail"] = (f"encoded image is {encoded_len} bytes, over the cap of "
                       f"{max_image_bytes}; the file is untouched at {reply.get('path')}")
    return False

def record_tool_error(run_id: str, tool: str, args: dict, tag: str, exc: Exception) -> None:
    """Journal a failure that happened before any capture output existed.

    Without this, a tool that raises while starting the script leaves a start line and no
    finish line, which recent_runs cannot tell apart from a call still running.
    """
    from . import runlog

    runlog.record_finish(
        run_id, tool, args, tag=tag or None, status="FAILED",
        duration_ms=0.0, result={"ok": False, "status": "FAILED", "error": str(exc)},
        stderr=f"{type(exc).__name__}: {exc}",
    )
