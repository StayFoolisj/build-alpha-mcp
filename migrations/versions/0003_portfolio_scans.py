"""portfolio scan snapshots (membership as an immutable fact)

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-22

Before this, membership was an append-only ledger: a strategy deleted from a
portfolio kept its row forever and the cache could not tell that it had gone.

Now a *scan* is the unit of truth. Every capture of a portfolio writes

    portfolio_scans     - one row: when, how many rows were captured vs how many
                          the grid reported, whether the capture was trustworthy
    scan_memberships    - one row per strategy seen in that scan (position = the
                          row order in the grid)

"Currently in portfolio P" is the membership of the latest scan of P with
``ok = 1``; a deletion is simply a strategy that is absent from that snapshot.
Nothing is ever deleted by a scan, so history is preserved and a removal is
recoverable (which scan it disappeared after, and where it went). Old scans are
removed only by an explicit retention call.

``strategy_portfolios`` is kept as the ever-seen ledger (first_seen/last_seen per
tag+portfolio). It answers "was this ever in P" and is what the backfill below
seeds the first snapshot from, so existing databases gain a usable scan 1
without re-sweeping.
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "portfolio_scans",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("portfolio", sa.Text(), nullable=False),
        # ISO-8601 UTC
        sa.Column("started_at", sa.Text(), nullable=False),
        sa.Column("finished_at", sa.Text()),
        # captured = parsed from the capture, grid_rows = what BuildAlpha reported
        # (GridPattern.RowCount); they must agree for ok=1
        sa.Column("captured_rows", sa.Integer()),
        sa.Column("grid_rows", sa.Integer()),
        sa.Column("source", sa.Text()),
        sa.Column("ok", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("note", sa.Text()),
    )
    op.create_index("ix_portfolio_scans_portfolio", "portfolio_scans", ["portfolio", "id"])

    op.create_table(
        "scan_memberships",
        sa.Column("scan_id", sa.Integer(), nullable=False),
        sa.Column("tag", sa.Text(), nullable=False),
        sa.Column("position", sa.Integer()),
        sa.PrimaryKeyConstraint("scan_id", "tag"),
        sa.ForeignKeyConstraint(["scan_id"], ["portfolio_scans.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_scan_memberships_tag", "scan_memberships", ["tag"])

    # Seed snapshot 1 from the ever-seen ledger so an existing cache is usable
    # immediately (a fresh sweep will replace it as the latest ok scan).
    op.execute(
        "INSERT INTO portfolio_scans (portfolio, started_at, finished_at, captured_rows, "
        "grid_rows, source, ok, note) "
        "SELECT portfolio, MIN(first_seen), MAX(last_seen), COUNT(*), NULL, 'backfill', 1, "
        "'seeded from strategy_portfolios (0002)' "
        "FROM strategy_portfolios WHERE portfolio IS NOT NULL AND portfolio <> '' "
        "GROUP BY portfolio"
    )
    op.execute(
        "INSERT INTO scan_memberships (scan_id, tag, position) "
        "SELECT s.id, m.tag, NULL FROM portfolio_scans s "
        "JOIN strategy_portfolios m ON m.portfolio = s.portfolio "
        "WHERE s.source = 'backfill'"
    )


def downgrade() -> None:
    op.drop_index("ix_scan_memberships_tag", table_name="scan_memberships")
    op.drop_table("scan_memberships")
    op.drop_index("ix_portfolio_scans_portfolio", table_name="portfolio_scans")
    op.drop_table("portfolio_scans")
