"""Deterministic normalisation + tag computation for BuildAlpha strategies."""
from __future__ import annotations

import base64
import hashlib
import re
from datetime import datetime

_TF = {
    "minute": "m", "minutes": "m", "min": "m", "mins": "m", "m": "m",
    "hour": "h", "hours": "h", "hr": "h", "hrs": "h", "h": "h",
    "day": "d", "days": "d", "d": "d",
    "week": "w", "weeks": "w", "w": "w",
    "month": "mo", "months": "mo",
}

_DATE_FORMATS = (
    "%m/%d/%Y %I:%M:%S %p",
    "%m/%d/%Y %H:%M:%S",
    "%m/%d/%Y",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d",
)


def normalize_symbol(value: str) -> str:
    """'SOLUSD (15 minutes)' / 'SOLUSD_15m' -> 'SOLUSD|15m'."""
    s = (value or "").strip()
    m = re.match(r"^(?P<sym>[^(]+?)\s*\((?P<tf>[^)]+)\)\s*$", s)
    if not m:
        m = re.match(r"^(?P<sym>.+?)_(?P<tf>\d+\s*[a-zA-Z]+)$", s)
    if not m:
        return re.sub(r"\s+", " ", s)
    sym = re.sub(r"\s+", "", m.group("sym"))
    tf = m.group("tf").strip().lower()
    mm = re.match(r"^(\d+)\s*([a-z]+)$", tf)
    if mm:
        return f"{sym}|{mm.group(1)}{_TF.get(mm.group(2), mm.group(2))}"
    return f"{sym}|{tf}"


def normalize_date(value: str) -> str:
    """Drop the time component; return ISO date (or the raw text if unparsable)."""
    s = (value or "").strip()
    if not s:
        return ""
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(s).date().isoformat()
    except ValueError:
        return s


def normalize_number(value) -> str:
    """Round to 6 dp and strip trailing zeros: 0.0015999999595806 -> '0.0016'."""
    if value is None:
        return ""
    s = str(value).strip()
    if not s:
        return ""
    try:
        d = float(s.replace(",", ""))
    except ValueError:
        return s
    out = f"{round(d, 6):.6f}".rstrip("0").rstrip(".")
    return "0" if out in ("", "-0") else out


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", (value or "")).strip()


def normalize_rules(rules) -> str:
    """Join rules in the given (form-reader walk) order with ' ; '."""
    out = [normalize_text(r) for r in rules]
    return " ; ".join(r for r in out if r)


def _sha1(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def _b32(hexdigest: str) -> str:
    raw = bytes.fromhex(hexdigest)
    return base64.b32encode(raw).decode("ascii").lower().rstrip("=")


def compute_tags(
    *,
    symbol: str,
    strategy_type: str,
    entry_rules,
    exit_params,
    start_date: str,
    stop_date: str,
    costs: str,
    sizing: str,
    fitness: str,
    is_oos: str,
) -> dict:
    """Return logical/hash/variant/tag for one strategy configuration."""
    sym = normalize_symbol(symbol)
    typ = normalize_text(strategy_type)
    entry = normalize_rules(entry_rules) if not isinstance(entry_rules, str) else normalize_text(entry_rules)
    exitp = normalize_text(exit_params)

    logical = "|".join([sym, typ, entry, exitp])
    logical_hash = _sha1(logical)

    variant = "|".join([
        logical,
        normalize_date(start_date),
        normalize_date(stop_date),
        normalize_text(costs),
        normalize_text(sizing),
        normalize_text(fitness),
        normalize_text(is_oos),
    ])
    variant_hash = _sha1(variant)
    return {
        "logical": logical,
        "logical_hash": logical_hash,
        "variant": variant,
        "variant_hash": variant_hash,
        "tag": _b32(variant_hash)[:10],
    }
