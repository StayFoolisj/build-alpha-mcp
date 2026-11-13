"""Parse BuildAlpha captures (form-reader text, portfolio-grid rows) into records."""
from __future__ import annotations

import re
from pathlib import Path

# grid column name -> strategies column
GRID_METRICS = {
    "Sharpe": ("sharpe", "real"),
    "Trades": ("trade_count", "int"),
    "Net P&L": ("net_pnl", "real"),
    "Drawdown": ("drawdown", "real"),
    "Drawdown MTM": ("drawdown_mtm", "real"),
    "Win Percentage": ("win_rate", "real"),
    "P&L / DD": ("pnl_dd", "real"),
    "Profit Factor": ("profit_factor", "real"),
    "Ratio WL": ("ratio_wl", "real"),
    "CAGR": ("cagr", "real"),
    "SQM": ("sqm", "real"),
    "SQN": ("sqn", "real"),
    "T-Test": ("t_test", "real"),
    "E-Ratio": ("e_ratio", "real"),
    "K-Ratio": ("k_ratio", "real"),
    "Expectancy Score": ("expectancy_score", "real"),
    "Avg Trade": ("avg_trade", "real"),
    "Mean W trades": ("mean_w_trades", "real"),
    "Mean L trades": ("mean_l_trades", "real"),
    "Std W trades": ("std_w_trades", "real"),
    "Std L trades": ("std_l_trades", "real"),
    "Corr Coef": ("corr_coef", "real"),
    "CPC Ratio": ("cpc_ratio", "real"),
    "Perfect Profit Percentage": ("perfect_profit_pct", "real"),
    "Perfect Profit Correlation": ("perfect_profit_corr", "real"),
    "Custom Fitness": ("custom_fitness", "real"),
}


def _to_float(value):
    if value is None:
        return None
    s = str(value).strip().replace(",", "").replace("$", "").replace("%", "")
    if s in ("", "-", "n/a", "N/A"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def read_form(path: str | Path) -> tuple[dict[str, str], list[str], list[str]]:
    """Return (label -> value, entry rules, exit rules) from a form-reader record."""
    fields: dict[str, str] = {}
    entry: list[str] = []
    exits: list[str] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or line.startswith("=="):
            continue
        if line.startswith("RULE\t"):
            parts = line.split("\t")
            if len(parts) >= 3:
                flags, text = parts[1], parts[2]
                if "Entry=On" in flags:
                    entry.append(text)
                if "Exit=On" in flags:
                    exits.append(text)
            continue
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] not in fields:
            fields[parts[0]] = parts[1]
    return fields, entry, exits


def read_grid(path: str | Path) -> dict[str, str]:
    """Return column -> value from a grid-row capture ('Column<TAB>Value')."""
    row: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            row[parts[0]] = "\t".join(parts[1:])
    return row


def variant_parts(fields: dict[str, str]) -> dict[str, str]:
    from .normalize import normalize_number

    def get(key: str) -> str:
        return fields.get(key, "")

    def num(key: str) -> str:
        """Numeric settings are hashed after 6-dp rounding (float noise removed)."""
        return normalize_number(fields.get(key, ""))

    costs = ";".join([
        f"commission_mode={get('Commission Mode')}",
        f"commission={num('Commission (market currency)')}",
        f"slippage_mode={get('Slippage Mode')}",
        f"slippage={num('Slippage (market currency)')}",
    ])
    sizing = ";".join([
        f"mode={get('Position sizing')}",
        f"sizing_mode={get('Position Sizing Mode')}",
        f"concurrent={get('Concurrent sizing')}",
        f"max_positions={num('Max positions')}",
        f"max_exposure={num('Max exposure')}",
        f"min_position={num('Min position size')}",
        f"risk={num('Risk per trade:')}",
    ])
    is_oos = ";".join([
        f"is_min={num('In Sample minimum trades')}",
        f"oos_min={num('Out of Sample minimum trades')}",
        f"oos_pct={num('Out of Sample percent')}",
    ])
    return {
        "symbol": get("Symbols"),
        "strategy_type": get("Strategy Type"),
        "start_date": get("Start Date"),
        "stop_date": get("Stop Date"),
        "costs": costs,
        "sizing": sizing,
        "fitness": get("Fitness function"),
        "is_oos": is_oos,
    }


def metrics_from_grid(grid: dict[str, str]) -> dict[str, object]:
    out: dict[str, object] = {}
    for column, (key, kind) in GRID_METRICS.items():
        value = _to_float(grid.get(column))
        if value is None:
            continue
        out[key] = int(round(value)) if kind == "int" else value
    return out


def grid_identity(grid: dict[str, str]) -> dict[str, str]:
    return {
        "symbol": grid.get("Symbol", ""),
        "strategy_type": grid.get("Type", ""),
        "name": grid.get("Name", ""),
        "exit_params": grid.get("Exit Params", ""),
    }


def exit_params_from_settings(fields: dict[str, str], exit_rules: list[str]) -> str:
    """Compose exit params when the grid's Exit Params column is unavailable."""
    from .normalize import normalize_number

    parts = [
        f"PT {fields.get('Profit Target Mode', '')} {normalize_number(fields.get('Profit Target Base'))}".strip(),
        f"SL {fields.get('Stop Loss Mode', '')} {normalize_number(fields.get('Stop Loss Base'))}".strip(),
        f"TL {fields.get('Trailing Stop Loss Mode', '')} {normalize_number(fields.get('Trailing Stop Loss Base'))}".strip(),
    ]
    rules = [r for r in exit_rules if r]
    if rules:
        parts.append("exits: " + " ; ".join(rules))
    return "; ".join(p for p in parts if p)


def split_name_and_rules(name: str) -> tuple[str | None, str]:
    """Grid Name is either a custom label or the rule expression.

    A rule expression contains operators/keywords; a custom label is plain text.
    """
    text = (name or "").strip()
    looks_like_rules = bool(re.search(r"[\[\]()<>=]|\b(high|low|close|open|volume|Time)\b", text))
    if not text:
        return None, ""
    if looks_like_rules:
        return None, text
    return text, ""
