"""create strategies

Revision ID: 0001
Revises:
Create Date: 2026-10-18
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

from strategy_cache.schema import IDENTITY_COLUMNS, METRIC_COLUMNS

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

_TYPES = {
    "TEXT": sa.Text,
    "REAL": sa.Float,
    "INTEGER": sa.Integer,
}


def upgrade() -> None:
    columns = [sa.Column("tag", sa.Text(), primary_key=True)]
    for name, kind in IDENTITY_COLUMNS.items():
        columns.append(
            sa.Column(name, _TYPES.get(kind, sa.Text)(), nullable=name != "logical_hash")
        )
    for name, kind in METRIC_COLUMNS.items():
        columns.append(sa.Column(name, _TYPES[kind](), nullable=True))

    op.create_table("strategies", *columns)
    op.create_index("ix_strategies_logical_hash", "strategies", ["logical_hash"])
    op.create_index("ix_strategies_portfolio", "strategies", ["portfolio"])


def downgrade() -> None:
    op.drop_index("ix_strategies_portfolio", table_name="strategies")
    op.drop_index("ix_strategies_logical_hash", table_name="strategies")
    op.drop_table("strategies")
