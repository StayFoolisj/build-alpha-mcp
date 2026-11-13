"""add strategy_portfolios (portfolio membership)

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-19

``strategies.portfolio`` is a single column, but a strategy can be listed in
several portfolios at once: Common Portfolio holds every strategy, while
Hyperliquid #2 / Kraken / ... hold subsets. Membership therefore moves to
``strategy_portfolios``; ``strategies.portfolio`` is kept as the *home*
portfolio (the one the strategy was first read from).

The backfill seeds one membership row per existing strategy from its current
``portfolio`` value, so nothing is lost before the next sweep.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "strategy_portfolios",
        sa.Column("tag", sa.Text(), nullable=False),
        sa.Column("portfolio", sa.Text(), nullable=False),
        sa.Column("first_seen", sa.Text()),
        sa.Column("last_seen", sa.Text()),
        sa.Column("source", sa.Text()),
        sa.PrimaryKeyConstraint("tag", "portfolio"),
    )
    op.create_index(
        "ix_strategy_portfolios_portfolio", "strategy_portfolios", ["portfolio"]
    )
    op.execute(
        "INSERT INTO strategy_portfolios (tag, portfolio, first_seen, last_seen, source) "
        "SELECT tag, portfolio, first_seen, last_seen, 'backfill' "
        "FROM strategies WHERE portfolio IS NOT NULL AND portfolio <> ''"
    )


def downgrade() -> None:
    op.drop_index("ix_strategy_portfolios_portfolio", table_name="strategy_portfolios")
    op.drop_table("strategy_portfolios")
