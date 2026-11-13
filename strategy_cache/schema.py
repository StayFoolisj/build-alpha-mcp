"""Single source of truth for the strategies table shape (used by Alembic + db)."""

IDENTITY_COLUMNS: dict[str, str] = {
    "logical_hash": "TEXT",
    "variant_hash": "TEXT",
    "portfolio": "TEXT",
    "custom_name": "TEXT",
    "first_seen": "TEXT",
    "last_seen": "TEXT",
    "settings_json": "TEXT",
    "symbol": "TEXT",
    "strategy_type": "TEXT",
    "entry_rules": "TEXT",
    "exit_params": "TEXT",
}

METRIC_COLUMNS: dict[str, str] = {
    "sharpe": "REAL",
    "trade_count": "INTEGER",
    "net_pnl": "REAL",
    "drawdown": "REAL",
    "win_rate": "REAL",
    "drawdown_mtm": "REAL",
    "pnl_dd": "REAL",
    "profit_factor": "REAL",
    "ratio_wl": "REAL",
    "cagr": "REAL",
    "sqm": "REAL",
    "sqn": "REAL",
    "t_test": "REAL",
    "e_ratio": "REAL",
    "k_ratio": "REAL",
    "expectancy_score": "REAL",
    "avg_trade": "REAL",
    "mean_w_trades": "REAL",
    "mean_l_trades": "REAL",
    "std_w_trades": "REAL",
    "std_l_trades": "REAL",
    "corr_coef": "REAL",
    "cpc_ratio": "REAL",
    "perfect_profit_pct": "REAL",
    "perfect_profit_corr": "REAL",
    "custom_fitness": "REAL",
}

#: Many-to-many: which portfolios list a strategy. ``strategies.portfolio`` is the
#: home (first-seen) portfolio; Common Portfolio holds every strategy, so a single
#: column cannot express membership.
LOCATION_TABLE = "strategy_portfolios"
LOCATION_COLUMNS: dict[str, str] = {
    "tag": "TEXT",
    "portfolio": "TEXT",
    "first_seen": "TEXT",
    "last_seen": "TEXT",
    "source": "TEXT",
}
#: Current schema revision (alembic).
#: 0003 = portfolio scan snapshots: membership of a portfolio is the newest ``ok``
#: scan, so a strategy deleted from the portfolio drops out of "current" answers.
SCHEMA_REVISION = "0003"
