"""Metric glossary for the cache (no DB access, no BuildAlpha access).

The 26 metric columns are: what the portfolio grid stores per strategy. Units and
directions here are conventional hints for readers/clients - BuildAlpha's own
documentation is the authority on how each number is computed.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Metric:
    name: str          # column name in the strategies table
    label: str         # human label as shown in the grid
    unit: str          # currency | percent | ratio | score | count | fraction
    direction: str     # higher | lower | neutral
    group: str         # performance | risk | trade stats | quality | fitness
    note: str = ""


METRICS: tuple[Metric, ...] = (
    Metric("sharpe", "Sharpe ratio", "ratio", "higher", "performance",
           "Return per unit of volatility over the test window."),
    Metric("trade_count", "Trades", "count", "neutral", "activity",
           "Closed trades; filters usually require [Trades] >= 1."),
    Metric("net_pnl", "Net P&L", "currency", "higher", "performance",
           "After commission and slippage, in the portfolio's target currency."),
    Metric("drawdown", "Drawdown", "currency", "lower", "risk",
           "Peak-to-trough on closed trades."),
    Metric("win_rate", "Win rate", "fraction 0-1", "higher", "trade stats",
           "Winning trades / total trades."),
    Metric("drawdown_mtm", "Drawdown (MTM)", "currency", "lower", "risk",
           "Mark-to-market drawdown, including open positions."),
    Metric("pnl_dd", "P&L / DD", "ratio", "higher", "performance",
           "Net P&L divided by drawdown."),
    Metric("profit_factor", "Profit factor", "ratio", "higher", "profit quality",
           "Gross profit / gross loss."),
    Metric("ratio_wl", "Win/Loss ratio", "ratio", "higher", "profit quality",
           "Mean winning trade / mean losing trade."),
    Metric("cagr", "CAGR", "percent", "higher", "performance",
           "Compound annual growth rate implied by the window."),
    Metric("sqm", "SQM", "score", "higher", "quality",
           "System Quality Number family, as reported by BuildAlpha."),
    Metric("sqn", "SQN", "score", "higher", "quality",
           "System Quality Number variant, as reported by BuildAlpha."),
    Metric("t_test", "T-Test", "score", "higher", "quality",
           "Significance of the mean trade P&L."),
    Metric("e_ratio", "E-Ratio", "ratio", "higher", "quality",
           "Edge ratio (favorable excursion vs adverse excursion)."),
    Metric("k_ratio", "K-Ratio", "ratio", "higher", "quality",
           "Linearity of the equity curve."),
    Metric("expectancy_score", "Expectancy score", "score", "higher", "quality",
           "BuildAlpha composite expectancy metric."),
    Metric("avg_trade", "Avg trade", "currency", "higher", "trade stats",
           "Mean P&L per trade."),
    Metric("mean_w_trades", "Mean winning trade", "currency", "higher", "trade stats", ""),
    Metric("mean_l_trades", "Mean losing trade", "currency", "neutral", "trade stats",
           "Usually negative."),
    Metric("std_w_trades", "Std dev winning trades", "currency", "lower", "trade stats",
           "Dispersion of winning trades."),
    Metric("std_l_trades", "Std dev losing trades", "currency", "lower", "trade stats",
           "Dispersion of losing trades."),
    Metric("corr_coef", "Correlation coef.", "ratio", "neutral", "quality",
           "Correlation of trade P&L to the perfect-profit curve."),
    Metric("cpc_ratio", "CPC ratio", "ratio", "higher", "profit quality",
           "Perfect-profit capture ratio."),
    Metric("perfect_profit_pct", "Perfect profit %", "percent", "higher", "profit quality",
           "Share of available perfect profit captured."),
    Metric("perfect_profit_corr", "Perfect profit corr.", "ratio", "higher", "profit quality",
           "Correlation to the perfect-profit curve."),
    Metric("custom_fitness", "Custom fitness", "score", "higher", "fitness",
           "Fitness value produced by the run's fitness function."),
)


def describe() -> list[dict]:
    """The glossary as plain dicts, in column order."""
    return [asdict(metric) for metric in METRICS]


def names() -> tuple[str, ...]:
    return tuple(metric.name for metric in METRICS)
