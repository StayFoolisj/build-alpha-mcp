# Build Alpha MCP

Windows UI Automation for the Build Alpha desktop app, a SQLite cache of every strategy it shows, and an MCP server over that cache.

The app has no API. Everything here reads the real controls: no hand-typed screen coordinates, and no OCR for table data.

## Three layers

| Layer | What it does | Where |
|---|---|---|
| UI Automation | Start and stop the app, read the portfolio grid, switch portfolios, read `Re-Run` and `Strategy Builder` forms, re-run a strategy and diff the new window, capture variance and Monte Carlo panels | `scripts/` (21 PowerShell files) |
| Strategy cache | Tag identity, capture parsing, SQLite with Alembic migrations, queries, a JSONL run log | `strategy_cache/` |
| MCP server | 25 tools over the cache, plus opt-in tools that drive a new simulation | `strategy_cache/mcp_server.py` |

## Capabilities

| Capability | How it is done |
|---|---|
| Read the grid, find the highest Sharpe | sort by Sharpe, then verify in pure Python |
| Find a strategy by name | DevExpress search panel, one attempt order in one file |
| Switch portfolio | `ComboBoxEdit` dropdown, a real click |
| Capture a full 35-column record | `FromPoint` to the `DataGrid` walk, or the grid clipboard copy |
| Bulk-load a portfolio | grid `Ctrl+A` / `Ctrl+C` over top-level rows |
| Re-run and compare | right-click, OCR the menu item, diff window handles |
| Seasonality, variance, Monte Carlo | open the view, capture the window, read the summary |
| Continuous simulation | two-phase: prepare and audit, then confirm and start |

The full table, with commands and outputs, sits in [`docs/manual.md`](docs/manual.md).

## Requirements

- Windows 10 or newer, with Build Alpha installed. The scripts resolve the install directory from the uninstall registry entry.
- Windows PowerShell 5.1 or newer. The scripts avoid PS7-only syntax.
- An OCR language pack for `Windows.Media.Ocr`. The grid context menu and the test-filter dialog are custom-drawn and expose no items.
- Python 3.10 or newer, and `uv`.

## Quick start

```sh
uv sync

# check the cache, the parsers, and the scripts' contracts
uv run python -m strategy_cache.tests_pipeline

# app status, then a grid read
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_status.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_grid_rows.ps1 -OutFile captures\grid-rows.txt

# load the capture into the cache
uv run python -m strategy_cache.grid_ingest --rows captures/grid-rows.txt --portfolio "Common Portfolio"

# serve the cache
uv run python -m strategy_cache.mcp_server --db C:\path\to\buildalpha_cache.sqlite3
```

For a remote client, add `--sse --host 0.0.0.0 --port 8080`. The action tools stay off until you pass `--allow-actions`.

## The tool surface

| Group | Tools |
|---|---|
| Read the cache | `list_strategies`, `get_strategy`, `query_strategies`, `list_portfolios`, `portfolio_changes`, `cache_stats`, `describe_metrics` |
| Read the record | `get_last_result`, `recent_runs`, `trades`, `buildalpha_status` |
| Capture a view | `capture_variance_test`, `capture_mc_analysis`, `capture_mc_drawdown`, `capture_eratio`, `buildalpha_read_capture` |
| Drive a run (opt-in) | `prepare_continuous_sim`, `start_continuous_sim`, `stop_continuous_sim`, `cancel_continuous_sim`, `current_test_filter`, `apply_test_filter`, `list_filters`, `rerun_with_adjustments` |

Read `list_tools` on the running server for the current list. The cache tools never write.

## Tests

```sh
uv run python -m strategy_cache.tests_pipeline
```

The suite is 38 checks and needs no running app. It uses recorded captures under `captures/`, writes its databases to a scratch directory, and touches Build Alpha only in the checks that skip without PowerShell.

On macOS and Linux the run prints `35/38 passed, 3 skipped`. The three PowerShell checks run on Windows, and the CI matrix covers both.

## Layout

```text
scripts/          21 PowerShell files: app lifecycle, grid, forms, runs, captures
strategy_cache/   Python package: parse, identify, db, queries, runlog, mcp_server
migrations/       Alembic revisions
docs/             manual.md (long form), logging.md (the run-log contract)
captures/         Two synthetic fixtures for the tests, plus the format notes
```

`captures/` in this repository holds fixtures only. The scripts write live captures there at run time.

## Design rules

- **One attempt order for a row search.** `strategy_cache/identify.py` holds it. Do not add another filter block, and never search with a rule expression. See [`docs/manual.md`](docs/manual.md#finding-a-strategy-row-read-this-before-writing-a-tool).
- **One GUI driver at a time.** A file lock with `FileShare.None` serialises the scripts, because two calls that click at once pick the wrong row.
- **The log is a contract.** One line per event, bounded fields, credential redaction, and a digest instead of a payload. See [`docs/logging.md`](docs/logging.md).
- **Read-only by default.** The cache server opens the database read-only. Action tools need `--allow-actions`.
- **Never trust a short copy.** A grid capture that returns fewer cells than the header says joins the existing row as a partial update, and never becomes a second strategy.

## Limits

- Windows only. The UI layer calls `System.Windows.Automation`.
- The app must pass its own licence and update check at startup, or it exits.
- One process drives the UI at a time, by design.
- The cache holds what the app exposes. A row that the grid does not render is not in the cache.

## License

MIT. See [`LICENSE`](LICENSE).
