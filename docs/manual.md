# Build Alpha MCP manual

Long-form reference: the PowerShell flows, the cache, the row-search order, the
platform notes, and the troubleshooting list. The README has the short version.

The three checks that need PowerShell skip on a host without it. Windows CI runs them.

## Capabilities at a glance

| Capability | How it is done | Output |
|---|---|---|
| Read grid, find highest Sharpe | sort by Sharpe, verify in pure Python | `captures/grid-*.txt` |
| Find a strategy by name | Ctrl+F DevExpress search panel | row lookup |
| List / switch portfolio | `ComboBoxEdit` dropdown, real mouse click | `captures/portfolios.txt` |
| Capture a full 35-column record | `FromPoint` -> `DataGrid` walk, or grid clipboard copy | before snapshot |
| Bulk-load a whole portfolio | grid `Ctrl+A`/`Ctrl+C` (or `GridPattern`) over top-level rows | `captures/grid-rows.txt` |
| Re-run a strategy | right-click -> OCR `Re-run strategy` | `scripts/buildalpha_rerun_compare.ps1` |
| Read the re-run results window | diff window handles, read the new window's grid | `captures/stratABC-rerun-comparison.txt` |
| Seasonality analysis | right-click -> `Seasonality`, screenshot + read plots | `scripts/buildalpha_seasonality.ps1` |
| Read a form window | `buildalpha_form_reader.ps1` (all tabs) | `captures/re-run-fields.txt` |
| Apply a saved test filter | `Ctrl+F` dialog + PrintWindow OCR | before/after row counts |
| Start a continuous simulation | `buildalpha_continuous.ps1` (prepare -> audit -> start) | `scripts/continuous-pending.json` |
| Capture BuildAlpha status | `buildalpha_status.ps1` (read-only) | console / `-Json` |
| Serve strategies to MCP | `strategy_cache/mcp_server.py` (stdio or SSE) | 14 tools |

## Requirements

- Windows 10+ with BuildAlpha installed (the install directory is resolved from
  the uninstall registry entry, with known-path fallbacks; `-InstallDir`
  overrides). `buildalpha_start.ps1` launches it with the install directory as
  working directory, which is where its `Data/` folders belong.
- Windows PowerShell 5.1 or newer. The scripts avoid PS7-only syntax.
- An OCR language pack for `Windows.Media.Ocr` - required because the grid
  context menu and the test-filter dialog are custom-drawn and expose no items.
- Python 3.10+ and `uv` (recommended) or `pip`.

## Run

```sh
uv sync

# app lifecycle (working directory matters, see the note further down)
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_start.ps1 -Action status
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_start.ps1 -Action start

# one-off automation
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_grid_rows.ps1 -OutFile captures\grid-rows.txt
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_status.ps1

# cache + MCP (stdio)
uv run python -m strategy_cache.grid_ingest --rows captures/grid-rows.txt --portfolio "Common Portfolio"
uv run python -m strategy_cache.mcp_server --db C:\path\to\buildalpha_cache.sqlite3

# cache + MCP (SSE, for a remote client)
uv run python -m strategy_cache.mcp_server --sse --host 0.0.0.0 --port 8080 \
  --db C:\path\to\buildalpha_cache.sqlite3 --allow-actions
```

Every script prints a one-line verdict (`GRID_OK`, `PREPARED`, `FILTERED`, ...)
and documents its exit codes in the comment-based help (`Get-Help .\scripts\buildalpha_continuous.ps1 -Full`).

## 1. Re-run a strategy and compare before/after

1. Switch to the target portfolio and locate the strategy (Ctrl+F, or scan the
   `Name` column with `FromPoint`).
2. Capture its full 35-column record â€” the **before** snapshot.
3. Right-click the row and click **Re-run strategy** (OCR-assisted).
4. BuildAlpha re-simulates on the latest data and opens a **new results
   window**. Do not press Escape.
5. Snapshot the visible window handles before the click, diff them afterwards,
   and read the new window's grid â€” the **after** snapshot.
6. Diff the two records in pure Python and report the deltas.

Run: `buildalpha_rerun_compare.ps1` does all six steps and writes the report.
Use `-DryRun` to stop after step 2, and `-RowY <y>` to target a row by screen
position when its name is not unique (rows without a custom name show their
rule expression).

**Never rely on a filter you set by hand.** `buildalpha_rerun.ps1` starts with
four Escape presses to clear stray dialogs, and those also close the find panel
and drop the grid filter - after which `-RowY` points at whatever row happens to
sit there (this once re-ran a HYPE strategy instead of the ZEC one). Pass the
search text and the expected ticker instead, so the script filters and verifies
it itself:

```sh
powershell -File .\scripts\buildalpha_rerun.ps1 -Filter 'zec-trend-long' `
  -ExpectSymbol 'ZEC' -Target 'adjust'
```

- `-Filter <text>` types the text into Ctrl+F and presses Enter.
- `-ExpectSymbol <prefix>` reads the Symbol cell of the located row and exits 6
  when it does not match, before anything is clicked.
- `-KeepFilter` skips the four Escapes when the filter is already applied.
- `-Target 'adjust'` picks *Run strategy with adjustments* (a settings form) instead of the
  default **plain *Re-run strategy***. Plain Re-run uses the cached inputs, moves the stop date to
  today, runs immediately and opens a results window - no dialogue. That is what the capture tools
  need; the adjustments form is what `rerun_with_adjustments` needs. The default match is anchored
  so a plain re-run can never pick the adjustments entry by accident.

Example (`stratABC`, Robust portfolio): 146 -> **157 trades**, Sharpe
2.28 -> **2.33**, Net P&L 48,825.56 -> **54,170.94** (+5,345.38), drawdown
unchanged. Written to `captures/stratABC-rerun-comparison.txt`.

Porting example (same rules, different exchange): in *Hyperliquid #2* the only
`ZEC-USDT` strategy is `zec-trend-long vsShift: v strong` (Sharpe 1.13, 189
trades, DD 27,212.97). Re-run through **Run strategy with adjustments** against
the built-in `ZEC_1h` contract gives Sharpe **1.64**, **33** trades, DD
**16,232.05**, win 57.6%, PF 3.47 - the logic ports, the market is much thinner.
Written to `captures/zec-usdt-vs-builtin-zec-comparison.txt`.

Important: the original portfolio grid is **not** updated by a re-run. If you
read the main grid again (or press Escape, which closes the results window) you
will see the old values and conclude, wrongly, that nothing changed.

## 2. Seasonality analysis

1. Locate the strategy (`seasonality strategy test` in Robust) and right-click.
2. Click **Seasonality** in the OCR'd context menu.
3. A `Seasonality - <strategy>` window opens with four panels: Days, Months,
   Quarters, Years.
4. The charts are custom-drawn, so capture the window to a PNG and read the
   image to inspect the bars.
5. Report any month with a **red (negative)** bar, then explain it from the
   strategy's mechanics plus the quarter and day panels.

Example finding (`seasonality strategy test`, `@YM_30m`, long-only): **April is
the only losing month** (~ -$30k). Q1 is the best quarter, Q2 the worst, and
P&L is concentrated on Mondays. Because the system is long-only with wide
5.0/4.5-ATR brackets it needs trending conditions; April's post-Q1 chop
whipsaws entries into the stop. Caveat: about two trades per month, so this is
a weak seasonal signal. Written to `seasonality-analysis.txt`.

Run: `buildalpha_seasonality.ps1 -Strategy '<name>'` opens the view and saves
a PNG (`-Shot <path>`); `-Item 'Monthly Returns'` opens that table instead;
`-ListOnly` only prints the menu; `-CloseWindow` closes the view afterwards.

## 3. Form reader (`Re-Run` / `Strategy Builder`)

BuildAlpha has two near-identical dialog windows, **`Re-Run`** and **`Strategy
Builder`**. Both are forms, not grids, so they are read with UI Automation
value patterns instead of cell names.

```sh
# read every tab of the open Re-Run window into re-run-fields.txt
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_form_reader.ps1 -Title 'Re-Run'
# list the tabs only
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_form_reader.ps1 -Title 'Re-Run' -ListTabs
# read only the tab that is currently selected
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_form_reader.ps1 -Title 'Strategy Builder' -CurrentTabOnly
```

The window is opened from a strategy row's context menu with **`Re-run strategy
with adjustments`** (the plain `Re-run strategy` runs the simulation instead).
Double-clicking a row opens `Equity Curve`. Close the `Re-Run` window after
reading it; the reader leaves it open, so a batch wrapper closes it per
strategy.

The record has one `label <TAB> value <TAB> [kind]` line per field, grouped by
tab. Example values read from a `Re-Run` window:

```text
Start Date          7/14/2025 5:00:00 PM   [DateEdit]
Stop Date           9/26/2026 4:00:00 PM   [DateEdit]
Strategy Type       Long                   [ComboBoxEdit]
Profit Target Mode  ATR                    [ModeTab]
Profit Target Base  7                      [SpinEdit]
Profit Target Max   7                      [SpinEdit]
Profit Target Step  0                      [SpinEdit]
Symbols             PUMP-USDT (1 hour)     [Symbols]
Entry On            Next Bar Open          [ComboBoxEdit]
Exit On             Next Open              [TogglePair]
Out of Sample       End                    [TogglePair]
```

What it handles:
- **Tabs.** Top-level `DXTabItem` tabs (`Main`, `Additional Settings`) are
  selected in turn, read, and the originally selected tab is restored. Nested
  symbol sub-tabs are ignored.
- **Exit-settings groups** (`Main`: Profit Target, Stop Loss, Trailing Stop
  Loss, Highest High, Lowest Low, Max Holding Time, Profitable Closes). Each is
  three separate things and must not be mixed:
  1. the checkbox is the on/off switch;
  2. the `ATR` / `Fixed` / `%` strip is the **mode** - only the selected tab is
     read, emitted as `Profit Target Mode = ATR`;
  3. the three spin edits to the right are the parameter grid's **Base / Max /
     Step** columns, emitted as `Profit Target Base|Max|Step`.

  The spins are siblings of the group box, so they are collected in document
  order after the group until the next group box or the next *labelled* pane.
- **LayoutItem panes** (`Additional Settings`): a labelled pane wrapping one
  value control is read as `label -> value`. Hidden template checkboxes are
  skipped, so `Entry On` reads the combo (`Next Bar Open`) and `Rebalance
  Method` reads `Profit Factor`. When a visible checkbox and a value control
  coexist (e.g. `Max trades per day`), the value is emitted plus a
  `... Enabled` line for the checkbox.
- **Toggle pairs** (`Exit On`, `Out of Sample`): these switches expose only a
  toggle state, not their labels, so the row is OCR'd and the selected side is
  chosen from the state (`On` = right label).
- **Symbols**: the symbol name is OCR'd from the selector and paired with the
  timeframe combo on the same row (`PUMP-USDT (1 hour)`).
- **Dates** carry a time component in the `DateEdit` value even though the
  visible text box only shows `M/d/yyyy`; the reader keeps the full value.
- **Spin edits** hold doubles, so their text can carry float noise; values are
  rounded to 6 decimal places with trailing zeros removed
  (`0.0015999999595806` -> `0.0016`).

`buildalpha_form_reader.ps1` fails with a clear message and lists the open
window titles when the requested title is not present.

## 4. Continuous simulation (two-phase)

`buildalpha_continuous.ps1` prepares a run, reads every setting back, and only
starts it on a second call - nothing is launched by `prepare`.

```sh
# 1. prepare: configure the builder and audit the settings, start nothing
powershell -File .\scripts\buildalpha_continuous.ps1 -Action prepare `
  -Symbol BTC-USDT -Timeframe '1 hour' -Start 10/18/2024 -Stop 10/18/2026 -SkipSymbol

# 2. confirm: verify the form still matches, then click Continuous simulation
powershell -File .\scripts\buildalpha_continuous.ps1 -Action start          # -DryRun to verify only

powershell -File .\scripts\buildalpha_continuous.ps1 -Action show            # re-read the form
powershell -File .\scripts\buildalpha_continuous.ps1 -Action cancel          # close builder, drop pending
```

`prepare` writes `scripts/continuous-pending.json` (request + every `label/value` line
from `buildalpha_form_reader.ps1`). `start` re-reads the form, compares symbols,
timeframe and both dates against that file and **refuses** on drift (exit 10,
`-Force` overrides); only then does it click `Continuous simulation` and wait
for `Continuous Simulation results - ...`.

Audit example (`-Action prepare ... -SkipSymbol`):

```text
PREPARED symbol=BTC-USDT timeframe=1 hour start=10/18/2024 stop=10/18/2026
  Symbols = BTC-USDT (1 hour)
  Start Date = 10/18/2024 12:00:00 AM
  Stop Date = 10/18/2026 11:59:59 PM
  In Sample minimum trades = 100
  Out of Sample minimum trades = 30
  Out of Sample percent = 0.3
  Commission (market currency) = 4.5
  Slippage (market currency) = 25
```

**Filters.** `Ctrl+F` in the builder (or *Automated Workflows -> Edit Filters*)
opens the `Edit Filters` dialog: a list of saved filter groups (`Basic`,
`Foundation`, `MCP Loose`, `MCP Strict`, `Noise`, `RobustAll`, `Variance`,
`VsRandomTest`), `Simple`/`Advanced` editor tabs and `Create` / `Delete` /
`Import` / `Export`. **Switching is just selecting the list row**
(`SelectionItemPattern`); the choice survives closing and reopens pre-selected,
which is how the script verifies it.

```sh
powershell -File .\scripts\buildalpha_continuous.ps1 -Action filters        # list + active
powershell -File .\scripts\buildalpha_continuous.ps1 -Action prepare ... -Filter Noise
```

`prepare -Filter` opens the dialog, selects the group, closes it, then reopens
once to confirm the selection stuck (failure: `FILTER_FAILED`, exit 14). The
chosen name is stored in `scripts/continuous-pending.json`, so `start` audits filters
together with dates/symbols. Over MCP: `list_filters()` to discover names,
`prepare_continuous_sim(..., filter="Noise")` to switch. The dialog reports the
active group; a running job's `FilteringPanel` (via `buildalpha_status`) shows
the resulting expression.

What is automated: tab selection, timeframe combo (click, not `SetValue`),
`Start Date` / `Stop Date` (set + **Enter**; Tab alone does not commit), saved
filter groups, the symbol picker, full settings read-back, drift check, start,
stop and cancel.

**Stopping** (`-Action stop`, or `stop_continuous_sim` over MCP) clicks
`STOP continuous simulation` in the builder, answers **Yes** to the modal
`Continuous Simulation` dialog, then waits until the STOP button disappears. It
does **not** close any window: the results window and the builder stay exactly
where they are. It returns `STOPPED total=<n> title='...'`, where `n` is read
from the results grid's `Row x of N` cells - the number of candidates the run
produced (live: 112 after ~60 s, 100 after ~40 s).

**Symbol picker - measured behaviour** (server-side tab):

| Sequence | Found the symbol |
|---|---|
| expand group, then search + Find | 0 / 3 |
| search + Find, expand group, **Find again** | **4 / 4** |

So the picker's search only looks at materialised nodes, and expanding does not
re-run the filter - it has to be: set the text, `Find`, expand the asset-class
group, `Find` again. Two other traps: the **Selection cell is a toggle**
(clicking an already-checked row *unchecks* it, so the script reads the state and
only clicks when it says `Unchecked`), and `PART_ToggleButton` has no
`InvokePattern`, so expansion is a click at its coordinates. Opening the popup is
flaky, so it is retried up to three times.

After `OK` the script trusts nothing: `prepare` re-reads the form and fails with
`SYMBOL_NOT_IN_FORM` (exit 13) if the symbol is not in the audited `Symbols`
line. Re-running `prepare` with the same symbol is idempotent.

**Both symbol tabs work.** The tab is chosen from the symbol: `@ES`, `@GC`, ...
go to *Built-in symbols* (`mainBuildinSymbolsSelector`), everything else to
*Server-side symbols* (`mainServerSymbolsSelector`). The built-in picker exposes
the same `Selection / Name / TF / Description` cells as the server-side one, but
its rows only materialise after the asset-class group (`Futures`, `ETF`,
`FOREX`, `Crypto`, `Custom`) is expanded - which is why built-ins looked
unreadable. `-Group` defaults to `Futures`, and if the ticker is not found
there the script tries the other groups by itself (that is how `@BC`, a Bitcoin
contract, is found under `Futures` rather than `Crypto`).

Built-in rows carry their own timeframe (the picker's `TF` column), so there is
no timeframe combo on that tab: `prepare` reports
`TIMEFRAME_SKIPPED (built-in symbols carry their own timeframe)` and prints the
row's TF as `row_timeframe=...` (e.g. `1D` for `@ES`).

Verification on the built-in tab cannot use the audited `Symbols` line (it is
empty there), so it uses the selector's `PART_Item` count button instead and
fails with `SYMBOL_NOT_IN_FORM` (exit 13) when it does not read `(1)` or more.

**Nested exchange groups** (`Crypto` > `Kraken` / `Kucoin` / `Massive`) are not
reachable with the search-first sequence: with a filter active those child rows
are not materialised, so a Kraken symbol such as `SOLUSD` cannot be selected
automatically yet. Use `-SkipSymbol` and pick it by hand in that case (top-level
`Crypto`/`Futures` symbols work).

### Status capture

`buildalpha_status.ps1` reports, read-only, whether BuildAlpha is up and what
job it is running:

```sh
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_status.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_status.ps1 -Json
```

| Field | Source |
|---|---|
| running, pid, responding, process start, cpu, memory | process table |
| `state` (`running` / `results-open` / `idle`), active job | `STOP continuous simulation` button or a live `<n> strat/sec` counter; an open results window only means results are on screen |
| job title | `Continuous Simulation results - ...` window title |
| job start, symbols, data range | `logs\app.log` - the `BrokersManager.LoadServerSideData(): start loading (...)` line before the newest `Continuous Simulation` entry |
| stop marker | `StrategiesViewModel.Destroy: detaching continuous UI hooks` in `app.log` - written when a run is stopped with STOP -> Yes |
| throughput (sims/sec) | the `<n> strat/sec` button in the results window |
| results count | grid cells `Row n of N` (N is the current total) |
| filter | `FilteringPanel` `ValuePattern`, e.g. `[Trades] >= 1` (shown as `Trades > 1`) |

`state` is the honest answer to "is it still generating?": a results window
outlives the run (it can stay open with an empty grid), so it alone does not
count as a running job. `job_started`/`job_symbols`/`job_age_seconds` describe
the most recent run in the log even after it has finished.

Example while generating:

```text
running      : yes (pid 30704, responding=True)
state        : running
job          : Continuous Simulation results - @S_1h (Long)
job started  : 2026-10-18 13:30:31  (age 0d 00:14:05)
symbols      : @S_1h,BTC-USDT_4h
throughput   : 69.43K strat/sec
results      : 500 rows (visible 56..92)
filter       : [Trades] >= 1
```

### Job lifecycle (`job` block)

Every record carries a `job` object that answers "running for how long?" and
"when did it finish?":

```json
{
  "state": "completed",
  "started": "2026-10-18T13:30:31+07:00",
  "ended": "2026-10-18T14:05:12+07:00",
  "ended_source": "observed",
  "seen_between": ["2026-10-18T14:00:40+07:00", "2026-10-18T14:05:12+07:00"],
  "duration_seconds": 2081,
  "duration": "34m 41s",
  "max_duration_seconds": null,
  "max_duration": null,
  "summary": "completed 37m ago (between 14:00 and 14:05)"
}
```

| `ended_source` | How the end time is known | `summary` reads as |
|---|---|---|
| `log` | STOP -> Yes wrote `StrategiesViewModel.Destroy` | `completed 37m ago` - exact |
| `observed` | a capture saw the job running, a later capture saw it gone | `completed 37m ago (between 14:00 and 14:05)` - accurate to the capture interval |
| `before` | no running observation, but at least two captures agree it is done | `completed before 14:52 (end not logged)` |
| `single` | first ever capture, and the job was already finished | `not running at 14:52 (run end not recorded)` |
| `none` | no run in the log | `not running (no start/end recorded)` |
| (running) | `state` is `running` | `running for 4h 32m` |

When the job is running, `duration` is `now - started`. When the end is only
bounded (`before`/`single`), `duration` is null and `max_duration` gives the
longest it could have run. Observations are kept in
`buildalpha_status.history.jsonl` (one line per capture, last 2000), which is
what makes `observed` possible after the fact.

Note: BuildAlpha writes no completion line when a run finishes on its own, so a
run that ends without STOP can only be timed to the capture interval - hence the
history file. Start times are likewise inferred from the data-load line before
the newest simulation entry in `app.log`; if the log has rotated, the field is
empty.

The `buildalpha_status` MCP tool **captures on demand** by running this script
(about a second), so a query always reflects the current state. The same
capture also works standalone and writes `buildalpha_status.json` next to the
database, which the tool uses as a fallback:

```sh
uv run python -m strategy_cache.status capture --db .\scripts\buildalpha_cache.sqlite3
uv run python -m strategy_cache.status show        # prints the JSON + age/stale
```

`capture` runs the PowerShell script, adds `captured_at`, and writes the file
atomically (override the path with `--out`, `--file`, or `BA_STATUS_FILE`).
Re-running it on a timer (Task Scheduler or a `while` loop) is optional - it just
keeps a warm copy for `fresh=false` reads and for the CLI.

## Strategy cache (SQLite + Alembic)

`strategy_cache/` stores each BuildAlpha strategy once, keyed by a deterministic
**tag**, so metrics never need re-reading and location can change freely.

```sh
uv run alembic upgrade head                     # create / migrate the DB
uv run python -m strategy_cache.ingest \
  --portfolio Kraken \
  --settings kraken-SOLUSD-15m-Long.txt \
  --grid grid-SOLUSD-15m-Long.txt              # insert or update
uv run python -m strategy_cache.ingest ... --dry-run   # print the tag, no write
uv run python -m strategy_cache.selfcheck      # normalisation + upsert tests
uv run python -m strategy_cache.tests_pipeline # 18 contract tests
```

Validation: every form-reader capture is parsed into a Pydantic `Settings`
model before any write. Fields that feed the tag (`symbol`, `strategy_type`,
`start_date`, `stop_date`, `costs`, `sizing`, `fitness`, `entry_rules`,
`exit_params`) are required and normalised with the same helpers the hash uses,
so model and tag cannot disagree. Unknown form-reader fields are kept
(`extra="allow"`), so new captures do not break ingest. On failure the run logs
the reason plus the strategy identity and writes nothing (exit code 2).
`settings_json` stores the validated model dump, never the raw text;
`Settings.from_json(...)` gives typed access without re-validating on read.

Schema (`migrations/versions/0001_create_strategies.py`,
`0002_strategy_portfolios.py`):

- `tag TEXT PRIMARY KEY`
- `logical_hash TEXT NOT NULL` (indexed) - all date windows of the same rules
- `variant_hash TEXT`, `portfolio`, `custom_name`, `first_seen`, `last_seen`
- `settings_json TEXT` - every form-reader field (91 for a Re-Run window)
- `symbol`, `strategy_type`, `entry_rules`, `exit_params` (hash provenance)
- 26 metric columns, one per metric the portfolio grid exposes: `sharpe`,
  `trade_count`, `net_pnl`, `drawdown`, `win_rate`, `drawdown_mtm`, `pnl_dd`,
  `profit_factor`, `ratio_wl`, `cagr`, `sqm`, `sqn`, `t_test`, `e_ratio`,
  `k_ratio`, `expectancy_score`, `avg_trade`, `mean_w_trades`, `mean_l_trades`,
  `std_w_trades`, `std_l_trades`, `corr_coef`, `cpc_ratio`,
  `perfect_profit_pct`, `perfect_profit_corr`, `custom_fitness`
- `strategy_portfolios(tag, portfolio, first_seen, last_seen, source)` - which
  portfolios list a strategy (PK `tag, portfolio`, index on `portfolio`).
  `strategies.portfolio` stays the **home** portfolio (first sighting, or
  Common Portfolio when ingested with `--home`); membership is the second table,
  because one strategy can be in Common Portfolio *and* Hyperliquid #2 *and*
  Kraken at the same time.

Tag:

```text
logical = symbol|type|entry_rules|exit_params
variant = logical|start|stop|costs|sizing|fitness|IS-OOS
tag     = base32(sha1(normalise(variant)))[0:10]
```

Normalisation (deterministic): rules in form-reader order; dates reduced to ISO
date (time dropped); numbers rounded to 6 dp with trailing zeros stripped; mode
tabs and toggle pairs as their selected value; symbols as `SOLUSD|15m`.

Behaviour:

- First sighting inserts settings + metrics and records the portfolio as the
  home. A later sighting of the same `variant_hash` adds a **membership** row to
  `strategy_portfolios` and refreshes `custom_name` / `last_seen` (and metrics,
  for grid rows); the home portfolio is not overwritten by a smaller portfolio.
- A truncated-tag collision (same tag, different `variant_hash`) appends
  `-2`, `-3`, ... by row order and logs it.
- A re-run does **not** change a stored strategy; a re-run with different dates
  yields a different tag and only enters the cache if it is added to a portfolio.

Current contents: **431 strategies / 740 portfolio memberships**, **312 strategies
listed in more than one portfolio**. The 427 grid rows of `Common Portfolio` are
the inventory; the rest is membership.

| portfolio | strategies |
| --- | ---: |
| Common Portfolio | 427 |
| Hyperliquid | 99 |
| Training | 67 |
| Hyperliquid #2 | 45 |
| Robust | 37 |
| XGL | 27 |
| Thai SET | 22 |
| 2010 | 10 |
| Kraken | 4 |
| Lab | 2 |

Every sweep reported `insert=0`: the named portfolios are subsets of Common
Portfolio, so they add *locations*, never new strategies.

### Bulk ingest from the portfolio grid

The grid can be read without opening a single `Re-Run` window, which is how a
whole portfolio gets into the cache in ~3 s:

```sh
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_grid_rows.ps1 -OutFile captures/grid-rows.txt
uv run python -m strategy_cache.grid_ingest --rows captures/grid-rows.txt \
  --portfolio "Common Portfolio"            # --dry-run, --no-refresh
```

**How it reads.** The fast path is the grid's own copy command: click one data
cell, `Ctrl+A`, `Ctrl+C`, and the clipboard holds the whole grid as TSV with all
35 column headers (measured: 67 rows in 3 s vs ~75 s of `GridPattern.GetItem`
calls). The copied row count is checked against `GridPattern.RowCount`; only if
the copy is short or the clipboard stays untouched does it fall back to the UIA
reader, and the header records which path was used (`source=clipboard` /
`source=uia`). The script also refuses to write a capture unless the owning
window is `Build Alpha*` (`WRONG_WINDOW`, exit 3), because another DevExpress
grid under the probe point once produced a capture of the wrong portfolio, and
it records `window=` plus `sig=` (SHA1 over Symbol|Type|Name) for verification.

**Top-level rows only.** `Common Portfolio` has 8,899 **tree nodes** but 444
strategies: basket strategies own nested child rows (one per leg). The grid's
`GridPattern` enumerates exactly the top-level strategies (`RowCount` = 444),
while cell names say `Row n of 8899` because they count every node. The reader
gooses through `GridPattern.GetItem(r, c)`, so nested legs never enter the cache;
`captures/grid-rows.txt` records `top_level=444` in its header.

**What a grid row contains:** `Name` (the rule expression, or a custom label),
`Symbol`, `Type`, `Exit Params` and the 26 metrics. It does **not** contain the
date window, costs, sizing or fitness function, so a grid row is keyed on the
*logical* identity only:

```text
logical = symbol|type|entry_rules|exit_params     (variant_hash = logical_hash)
```

Consequences worth knowing:

- 392/444 rows carry the rule expression in `Name`; the other 52 are custom
  labels (`"12 Strategy 12: v1.1 (removed July)"`), so their `entry_rules` is
  empty and the label is stored as `custom_name`.
- Re-scanning a portfolio **refreshes** the metrics of existing grid rows
  (snapshots), while form-captured rows stay immutable - `refresh_metrics` only
  touches rows whose settings say `"source":"grid"`.
- Duplicate strategies in a portfolio (15 groups, 17 extra rows in Common
  Portfolio) collapse to one cache row by tag.
- A grid tag and a form tag for the *same* strategy differ (the form adds dates,
  costs, sizing, fitness to the variant). Grid rows are the portfolio inventory;
  form capture is for inspecting a specific run.
- A grid tag and a form tag for the *same* strategy differ (the form adds dates,
  costs, sizing, fitness to the variant). Grid rows are the portfolio inventory;
  form capture is for inspecting a specific run.

### Portfolio sweep (which portfolio lists what)

Common Portfolio holds every strategy, so the bulk ingest is already the full
inventory - but it cannot say that 45 of those strategies are also in
`Hyperliquid #2` and 37 in `Robust`. That is the membership table, and it is
filled by switching through the selector:

```sh
uv run python -m strategy_cache.portfolio_sweep --dry-run
uv run python -m strategy_cache.portfolio_sweep --only "Hyperliquid #2" "Lab"
uv run python -m strategy_cache.portfolio_sweep            # all but Common
```

For each portfolio the driver runs `buildalpha_switch_portfolio.ps1` (which
must print `SWITCHED` - it reopens the popup and checks
`SelectionItemPattern.IsSelected`), then `buildalpha_grid_rows.ps1` into
`captures/grid-rows-<slug>.txt`, then ingests that capture with the portfolio attached to
every row. The portfolio that was selected at start is restored at the end.

Notes:

- Re-sweeping is cheap and idempotent: existing tags are `refresh`ed, and the
  membership row is upserted (`INSERT ... ON CONFLICT DO UPDATE`).
- A strategy that lives in Common *and* a smaller portfolio gets **two**
  membership rows; `strategies.portfolio` keeps the home.
- Common Portfolio is skipped by default (`--include-common` to sweep it too).
  Ingest it with `--home` so it stays the home portfolio:
  `uv run python -m strategy_cache.grid_ingest --rows captures/grid-rows.txt --portfolio "Common Portfolio" --home`.
- The selector itself is usually missing from the UI Automation tree (empty
  rectangle, `IsOffscreen=True`), so the switcher clicks a fixed position after
  restoring the window from minimized and moving it to `0,0,1510x900`; the popup
  items *are* exposed, and the switch is a real click on the item rectangle
  (Select() only highlights). `RESTORE_FAILED` (exit 2) is returned if the
  window refuses to come back from the taskbar - a minimized window accepts
  neither clicks nor key presses, which is what made early copies look broken.

### MCP server (read-only)

`strategy_cache/mcp_server.py` exposes the cache over **stdio** for MCP clients:

```sh
python -m strategy_cache.mcp_server --db C:\path\to\buildalpha_cache.sqlite3
# or: BA_CACHE_DB=C:\path\to\buildalpha_cache.sqlite3 python -m strategy_cache
```

The database path must be **absolute** (`--db` or `BA_CACHE_DB`) and is resolved
before the engine is created. The file is opened with SQLite
`mode=ro&uri=true`, so writes fail (`attempt to write a readonly database`).
Startup refuses to continue when the file is missing, or when
`alembic_version` is missing/not `0001` - the server never creates a database
and never runs migrations. stdout carries only JSON-RPC (stdio) or stays empty
(SSE); logs go to stderr. It imports only `strategy_cache.*` (no `computer`,
`scripts/*.ps1`, or `main`), so no GUI or BuildAlpha process is involved.

**SSE (network) transport** - same tools, same guards, stdio stays the default:

```sh
python -m strategy_cache.mcp_server --sse --host 0.0.0.0 --port 8080 \
  --db C:\path\to\buildalpha_cache.sqlite3
```

That serves the SSE endpoint at `http://<host>:8080/sse` (messages are POSTed to
`/messages/?session_id=...`), so on the tailnet it is reachable at
**`http://my-box:8080/sse`**. `--host` defaults to `0.0.0.0` and `--port` to
`8080`; `--sse` selects this transport. uvicorn's access log is redirected to
stderr, so stdout stays empty.

Note: the SSE transport has no authentication and no DNS-rebinding protection
(`MCPServer` only auto-enables that when bound to localhost) - that is what
keeps a tailnet name like `my-box:8080` working. Restrict reachability with
tailnet ACLs / host firewall; the tools are read-only but expose the portfolio.

### Action tools (opt-in)

Starting a simulation is a *state change*, so those tools exist only when the
server is started with `--allow-actions` (default: not registered at all):

```sh
python -m strategy_cache.mcp_server --sse --host 0.0.0.0 --port 8080 \
  --db C:\path\to\buildalpha_cache.sqlite3 --allow-actions
```

Two steps, mirroring `buildalpha_continuous.ps1`:

Built-in tickers work too: a `symbol` starting with `@` (`@ES`, `@GC`, `@BC`)
switches the builder to the *Built-in symbols* tab, the asset-class group is
found automatically, and the row's own timeframe is used (the response carries
`row_timeframe`, and `timeframe` is ignored for those symbols).

```jsonc
// 1. configure + audit, nothing runs yet (server-side symbol)
{"symbol": "BTC-USDT", "timeframe": "1 hour",
 "start": "10/18/2024", "stop": "10/18/2026"}
// -> {"ok": true, "status": "PREPARED", "settings": {"Symbols": "BTC-USDT (1 hour)",
//     "Start Date": "10/18/2024 12:00:00 AM", ...}, "pending": {...}}

// built-in ticker: tab, asset-class group and timeframe all come from the row
{"symbol": "@GC", "start": "10/18/2024", "stop": "10/18/2026"}
// -> {"ok": true, "status": "PREPARED", "row_timeframe": "1D", ...}

// only when the picker must be left alone (nested exchange sub-groups)
{"symbol": "SOLUSD", "timeframe": "15 minutes", "skip_symbol": true}

// 2. verify only, then (without dry_run) start
{}                                  // -> status DRY_RUN / STARTED
```

Drift is refused (status `REFUSING`, exit 10); `force=true` overrides. The tool
runs `buildalpha_continuous.ps1` through PowerShell (300 s timeout) and returns
its verdict plus the audit lines. Both symbol tabs are supported (`@ES` on
*Built-in symbols*, `PUMP-USDT` on *Server-side symbols*), and built-in tickers
are selected for you - the asset-class group (`Futures`, `ETF`, `FOREX`,
`Crypto`, `Custom`) is found automatically, and the response carries the row's
own timeframe as `row_timeframe`. The one case the picker automation cannot
reach is a nested exchange sub-group (`Crypto` > `Kraken`/`Kucoin`/`Massive`):
those rows are not materialised while a search filter is active, so pass
`skip_symbol=true` and pick the symbol by hand. Everything else is selected and
verified against the audited `Symbols` line (or the `(N)` count on the built-in
tab).

**Security:** with `--allow-actions` anyone who can reach the port can start a
simulation on the production machine. Keep it on the tailnet only, and expect a
warning line in the server log when it is enabled.

Tools (all read-only):

| Tool | Returns |
|---|---|
| `list_strategies(portfolio: str \| None)` | `tag, symbol, strategy_type, sharpe, trade_count, portfolio, custom_name` |
| `query_strategies(...)` | filtered/sorted/paginated rows **plus `total`**. Filters: `portfolio` (current membership), `include_removed` (ever-seen ledger), `symbol` (exact `@ES\
| `get_strategy(tag)` | full row with `settings_json` parsed; MCP tool error if the tag is unknown |
| `list_portfolios(include_removed)` | portfolios from the newest **ok scan**: `count`, `as_of`, `scan_id`, `ok`, and `removed` (strategies deleted since). `include_removed=true` returns the append-only counts |
| `portfolio_changes(portfolio)` | `added` / `removed` tags between the two newest ok scans of a portfolio - this is how a deletion surfaces |
| `get_last_result(tag, include_dry_run)` | newest journalled real run for a tag plus any run in flight - fetch a result instead of re-running |
| `recent_runs(limit, tool, status, tag)` | recent journalled calls, newest first; filter by status for failures, by tag for all runs of one strategy |
| `describe_metrics()` | glossary for the 26 metric columns: label, unit, direction, group, note |
| `buildalpha_status(fresh: bool = True)` | **live capture** (~1 s via UI Automation): process, `state`, `job` (with `summary` like `running for 4h 32m` / `completed 37m ago`), throughput, results, filter; `mode='live'`. `fresh=false` reads the last snapshot instead |
| `prepare_continuous_sim(symbol, timeframe, start, stop, group, filter, skip_symbol)` | **only with `--allow-actions`**. Step 1: configures the Strategy Builder (including a saved filter group), audits every setting back, starts nothing |
| `start_continuous_sim(dry_run, force)` | **only with `--allow-actions`**. Step 2: re-reads the builder, refuses on drift, then starts the run; `dry_run=true` verifies only |
| `list_filters()` | **only with `--allow-actions`**. Saved filter groups with the active one marked |
| `stop_continuous_sim()` | **only with `--allow-actions`**. Stops the running run (STOP -> confirm Yes) without closing any window, and returns `results_total` = candidates produced |
| `apply_test_filter(filter)` | **only with `--allow-actions`**. Post-test filtering: applies a saved group to the finished run, returns `before`/`after` counts, `changed`, and the applied `expression` |
| `current_test_filter()` | **only with `--allow-actions`**. Current candidate count + applied expression (no changes) |
| `cancel_continuous_sim()` | **only with `--allow-actions`**. Closes the builder and deletes the pending request |
| `rerun_with_adjustments(tag, symbol, portfolio, start_date, stop_date, dry_run, row_timeout_sec)` | **only with `--allow-actions`**. Re-runs the strategy identified by **tag**: resolves the row from the cache (grid Name, symbol, baseline metrics), filters by symbol only, requires an exact Name match and identical trades/Sharpe/P&L (`IDENTITY_MISMATCH` otherwise), then applies the symbol and/or date-window change and returns `baseline`, the results row and the per-metric `delta`. `dry_run=true` applies and verifies only |
| `capture_variance_test(tag, run_id, name, timeout_sec, max_image_bytes, include_image)` | **only with `--allow-actions`**. Screenshots BuildAlpha's *Variance Testing* view for one strategy (`tag`, same identity check as above) or one journalled re-run (`run_id`), saves `captures/screens/<name>-variance.png` and returns `path/bytes/sha256/width/height`, `selection_how`/`selection_evidence` and the window `title`. The view and the re-run results window are closed afterwards. `timeout_sec` defaults to 150: the flow needs 43-64 s and a smaller budget produces TIMEOUT before the view opens |

## Finding a strategy row (read this before writing a tool)

Almost every tool here has to point at one strategy in BuildAlpha's portfolio grid. The
decision - which string to search with, and what to do when that finds nothing - lives in
**one** place:

| file | role |
|---|---|
| `strategy_cache/identify.py` | decides the order (`plan()`), and is the only thing that reads `custom_name` / `entry_rules` to choose a search string |
| `scripts/buildalpha_find_strategy.ps1` | executes a plan against the live grid, records every attempt, returns the row |

**Do not add another filter block to a script.** Three previous copies existed
(`capture_view`, `rerun_adjust`, `trades`) and all carried the same bug.

### The order

1. the `name` the caller passed;
2. the cached `custom_name`, **if it is searchable**;
3. the symbol, disambiguated against the cached `trade_count`, then `sharpe`, then `net_pnl`;
4. the symbol alone, so the caller gets "several candidates" rather than nothing.

A miss on one step is recorded in `attempts[]` and the next step runs. Nothing is fatal until
every step has been tried.

### Why the rule text is not searched

A strategy with no custom name has its rule expression in the grid's Name cell. That text
cannot be typed into the find box - measured on `zkdkiddhg3`:

| filter text | rows |
|---|---|
| `DownRange` | 4 |
| `low[0]` | 78 |
| `DownRange(1,0) = 1` | **0** |
| `low[0] > EMA(close,12)[0]` | **0** |
| the full rule expression | **0** |
| `hype-mr-short vsShift: med` | 1 |
| `HYPE-MR-SHORT VSSHIFT: MED` | 1 (the find box is case-insensitive) |

`>`, `(`, `)` and `=` are syntax to that control, so it returns nothing and the grid looks
empty. `identify.is_searchable_name()` rejects such text and the plan says why
(`reason_name_absent`), rather than typing it and calling the empty result "grid not visible".

### Using it

```bash
# 1. the plan (no UI): tag -> what to search, plus the numbers to verify against
uv run python -c "
import json
from sqlalchemy import create_engine
from strategy_cache import identify
eng = create_engine('sqlite:///buildalpha_cache.sqlite3')
with eng.connect() as c:
    print(json.dumps(identify.plan(c, tag='zkdkiddhg3')))
" > plan.json

# 2. the search (needs BuildAlpha running)
powershell -NoProfile -File .\scripts\buildalpha_find_strategy.ps1 -PlanFile .\plan.json
```

One line of JSON on stdout (`FIND {...}`), progress on stderr as `STAGE {...}`:

```jsonc
{"status": "OK", "matched_by": "metrics", "tag": "zkdkiddhg3",
 "portfolio_read": "Common Portfolio", "portfolio_switched": false, "hscroll": 0,
 "filter": "133606.25", "filtered_rows": 1, "grid_rows": 443,
 "row_number": 9108, "row_index": 0, "row_symbol": "HYPE-USDT_1h",
 "row_rect": {"x": 48, "y": 155, "width": 80, "height": 22},
 "selected_text": "Row 9108 of 1, Column Symbol, Column 2 of 35: HYPE-USDT_1h",
 "selection_how": "clicked-cell", "duplicates": [], "attempts": [...], "stages": [...]}
```

Statuses: `OK`, `ROW_NOT_FOUND`, `AMBIGUOUS`, `SELECTION_FAILED`, `SYMBOL_COLUMN_HIDDEN`,
`GRID_NOT_VISIBLE`, `PORTFOLIO_SWITCH_FAILED`, `INPUT_BLOCKED`, `BUSY`, `TIMEOUT`,
`SCRIPT_FAILED`. Exit codes are in the script's help; `capture_view` maps
`AMBIGUOUS`/`SELECTION_FAILED`/`ROW_NOT_FOUND` to `IDENTITY_MISMATCH`, so a capture never continues
on a guess. `BUSY` means another call holds the UI lock (see "One driver at a time"); nothing was
touched. `SYMBOL_COLUMN_HIDDEN` means the grid is scrolled or configured so the Symbol column is not
materialised - identity is impossible then, and the reply says so instead of guessing an index.

### What it guarantees

- **The order is chosen for selectivity, not habit.** `identify.plan` emits candidates with the
  exact text to type (`search`) beside the numbers to verify against: Net P&L first (416 distinct
  values across Common's 427 rows, so one filter usually leaves one row), then a caller-given
  name, then the cached `custom_name` if it is a name rather than a rule expression, then the
  symbol - which is never empty, leaves a short scan, and is the fallback when the cached numbers
  are stale.
- **Two ways to read the row, chosen by one cheap check.** Grid values come from
  `GridPattern.GetItem` (~3 ms per cell) when the grid answers. Some app instances render perfectly
  but publish no cells at all - `GetItem` returns null for every row, every tree cell reports an
  infinite rectangle, and hit-testing inside the grid yields only a `DataPanel` - which was
  measured after a restart. One `GetItem` decides: if it answers, the UIA path runs unchanged; if
  not, the filtered rows are copied from the application itself (`Ctrl+A`, `Ctrl+C`) with their own
  headers, the same fields are verified, and the matched row is selected with `Home`/`Down`. The
  reply then reports `read_mode: "clipboard"` and `selection_how: "keyboard"`. The clipboard's
  previous contents are restored on the way out.
- **A match is every readable field agreeing.** Symbol prefix, Trades ±0.5, Sharpe ±0.02,
  Net P&L ±0.5, and at least one of them must be readable. A column scrolled out of view is
  *unknown and skipped*, never a mismatch - otherwise a correct row gets rejected.
- **The horizontal position is reset first** and reported as `hscroll`. DevExpress materialises
  only the cells that are on screen: with the grid scrolled right, the Symbol and metric columns
  are absent, which would silently weaken the comparison and leave nothing to click.
- **Ambiguity is refused, not guessed.** Several rows carrying the numbers *and differing* in a
  readable column -> `AMBIGUOUS`, with the rows and the differing fields listed. Several rows
  identical in every readable column -> the first is taken and the rest reported in `duplicates`,
  because the application cannot tell them apart either (they differ only in tag).
- **Success requires a proven selection.** The Symbol cell of the matched row is clicked, then
  that very cell is asked for `SelectionItemPattern.IsSelected` (`selection_how:
  "clicked-cell"`), its row number must equal the matched row's, and its text must carry the
  expected symbol. Only then is `OK` returned, with the cell's rect in `row_rect` so a consumer
  can right-click the verified row without passing coordinates around.
- **The filter is left applied and the row selected**, which is what a consumer's "open the row
  menu, choose item X" step needs.
- **Children are bounded.** The portfolio read and switch run under `Invoke-ScriptBounded`
  (hard deadline, killed on overrun): a UI Automation call inside them can block forever - one
  measurement had `buildalpha_switch_portfolio.ps1 -TimeoutSec 30` still alive 15 minutes later.

### Measured

`zkdkiddhg3`, filtered grid, per-step: grid 0.9-1.0 s, portfolio read 2.7 s (skipped when the
caller passes `-SkipPortfolio`), filter 1.4-6.6 s, scan 0.07-0.4 s, select 0.2-0.24 s, verify
0.06-0.09 s. In a capture the whole search stage is **3.3 s**; the same stage was **49.4 s**
before this rewrite. The residual spread is the application, not the round-trips: the same plan
run twice gave 5.6 s and 1.4 s on the filter alone, and the portfolio read swung 2.6 -> 11.6 s on
identical work.

### Reliability evidence

Run end to end against the live app: the four capture views on an unnamed tag (OK, 42-47 s), a
named tag (OK), a tag whose only portfolio is `Kraken` (OK, switch exercised), a grid scrolled
fully right (`hscroll 100 -> 0`, OK), and three deliberate refusals - duplicate Net P&L
(`AMBIGUOUS`), correct filter with wrong expected numbers (`ROW_NOT_FOUND`), and a filter that
matches nothing (`ROW_NOT_FOUND`). No wrong capture in the set.

Known limits: the duplicate-P&L pairs (11 of them) are unreachable by design - they differ only in
the leading word order of the Name (`'1 Strategy close[0] > close[1]...'` vs
`'Strategy 1 close[0] > close[1]...'`) with identical symbol and metrics, so the policy above
refuses them; `SELECTION_FAILED` and the `TIMEOUT` budget have never fired in a real run; nothing
yet guards two searches running against one grid at the same time.

Every verdict is appended to `logs/find_strategy.log` (rotates at 8 MB), so a standalone search
leaves evidence - see `docs/logging.md`.

### Who uses it

The four capture tools **do** (2026-10-31 onward), and nothing else yet:
`buildalpha_rerun_adjust.ps1` still carries its own copy of the filter/scan in its §1,
`buildalpha_seasonality.ps1` still uses `Find-Row` from `buildalpha_uia.ps1`, and
`buildalpha_rerun.ps1` still has `Find-RowPoint` (bypassed when a capture passes `-RowY`). Those
three are the remaining DRY gap - the contract above is what they should be refactored onto.

The capture path is:

1. `identify.plan` -> the candidates in selectivity order plus the numbers to verify against;
2. `find_strategy.ps1` (called with `-SkipPortfolio`, because the capture arranges the portfolio
   itself) types the Net P&L, falls back to name then symbol, verifies every readable field,
   clicks the Symbol cell and proves the selection;
3. **plain `Re-Run`** (`buildalpha_rerun.ps1`, no `-Target`) on that filtered row -> a results
   window appears in ~4 s. Plain Re-Run runs the cached inputs with the stop date moved to today;
   `Run strategy with adjustments` is the other menu item and opens a settings form - never use it
   for a capture;
4. the results window is focused, its only row is left-clicked, and the selection is **verified by
   asking the grid for `SelectionPattern.GetSelection()`** (fallback: a per-cell flag re-read after
   the click). If no selection can be shown the call fails and never invokes the view;
5. the view button is invoked **in that results window** via `InvokePattern` (a freshly resolved
   button each time);
6. the window is accepted on its **view prefix** alone. The title is recorded but not compared:
   BuildAlpha reorders the entry rules in the title, so matching that text rejected correct
   captures for no reason;
7. the view window is sized to 1000x750, captured, downscaled if wider than -MaxWidth, saved;
8. view and results window are closed.

Why the view is never opened from the portfolio: BuildAlpha binds each analysis view to a strategy
of its own choosing. Measured - grid filtered to one row, Strategy Details showing that row's
P&L, and `Variance Testing` still opened titled with an unrelated strategy. Support confirms there
is no fix; the re-run is the only way to bind it. Opening a view with no row selected makes the app
answer *"No strategy selected"*, which is why the selection check above is mandatory.

Measured timings: search 11-19 s, plain re-run ~4 s, whole capture 43-64 s. PNG ~600 KB at
1000x750 versus ~1.1 MB maximised.

### Variance Testing screenshots (`capture_variance_test`)

The view is a navigation button in a results window's right-hand icon panel, which UI
Automation exposes as `ControlType.Button Name='Variance Testing' AutomationId=
'HamburgerMenuNavigationButton'`. One way is used: `InvokePattern` on a freshly resolved button.
The accelerator and OCR-label fallbacks that used to be tried first are gone - they clicked around
the menu and sometimes consumed the action.

The view is **never** opened from the portfolio window; see "Finding a strategy row" for why (the
views keep their own strategy binding) and for the re-run step that has to precede it.

```jsonc
{"tag": "zkdkiddhg3", "timeout_sec": 150}
// -> status OK, path captures/screens/zkdkiddhg3-variance.png, ~600000 bytes,
//    984x734, sha256 e2e48e52…, selection_how "cell-selected",
//    title "Variance Testing - low[0] > EMA(close,12)[0], …", then an image block
```

- **Identity is checked before anything is clicked.** A `tag` is resolved to its exact grid
  `Name` plus the cached trades/Sharpe/net P&L; the located row must show the cached symbol
  and carry those numbers (tolerances 0.5 trades, 0.02 Sharpe, 0.5 P&L) or the call stops
  with `IDENTITY_MISMATCH` and `detail` naming the field that differed. `run_id` skips that
  comparison on purpose: a re-run's row carries the *re-run's* numbers, not the portfolio's.
- **The portfolio is selected first, then the grid is filtered to the row.** The cache names
  the portfolio (a tag can be a member of several) and `buildalpha_switch_portfolio.ps1` is
  called once to select it — the same call `rerun_with_adjustments` makes, never a re-implemented
  selector. Then the grid is narrowed with the find panel before anything is read: walking 443
  rows with `GridPattern.GetItem` is both slow and wrong, because DevExpress only materialises
  the visible screenful, so a far row throws and gets skipped — which used to be reported as
  "no row matched". A failed switch is not fatal by itself: the row still decides.
- **Every failure carries the grid context**: `grid.portfolio`, `grid.rows`,
  `grid.filtered_rows`, `grid.filter`, `grid.sample_names` (two names actually seen). That is
  what distinguishes "wrong screen" from "renamed strategy" at a glance. Cache freshness is
  deliberately absent here - it belongs to a scan tool, not to a capture.
- **`INPUT_BLOCKED`** when BuildAlpha cannot be made the foreground window (locked desktop,
  disconnected session). Nothing is clicked and no window is touched; without this, a dead
  input channel surfaced as a name mismatch minutes later.
- **`GRID_NOT_VISIBLE`** when the strategies grid is not in the automation tree at all (the
  documented "provider gone" state) — no row claim can be made then.
- **A stale window is never captured.** Only windows that appeared *after* the action are
  candidates, the window must come from a re-run of the verified row, and an already-open results
  window is reused only when its `Name` cell equals the row being asked for. Leftovers showing
  another strategy are closed.
- **The title is recorded, not compared.** BuildAlpha reorders the entry rules when it writes them
  into the title, so comparing that text to the row's Name rejected correct captures. Identity
  comes from the verified grid row; the title prefix only says which view opened.
- **`name` defaults to the target**, so a capture writes `u3z4vkztlz-variance.png` or, when
  the call carries a `run_id`, `<run_id>-variance.png`. Pass `name` to choose a different
  stem; the file is sanitised to `[A-Za-z0-9-_.]`.
- **Capture is the client area, not the window frame**, taken with `PrintWindow` +
  `PW_RENDERFULLCONTENT` so an obscured window still yields its own pixels. A flat result
  (>97 % one colour) falls back to a raised screen grab and, if that is flat too, fails with
  `CAPTURE_FAILED` rather than saving the wrong image. The script also requires the title to
  start with `Variance Testing` and the window to exceed 300x200, so the parent window can
  never be mistaken for the child.
- **The view window is sized to 1000x750 before the capture** (`view_resized` reports it) and
  closed afterwards. Maximised it is ~1528x918 and the PNG lands at ~1.1 MB; at 1000x750 it is
  ~600 KB with the text at native pixels. Only the view is touched - the portfolio layout is never
  resized, moved or pinned.
- **The width is capped at 1568** and the height follows the aspect ratio and the height follows the aspect ratio
  (`downscaled_from` reports the original width, so `770 → 770` means no scaling happened —
  today's dialog is 770 px wide, so in practice nothing is downscaled until a wider view
  exists; at `-MaxWidth 600` the same view becomes 600x521, which is how the path is tested).
- **`SIZE_CAP` is a success.** The capture worked and the file is on disk; only the image
  block was left out because the encoded form exceeded `max_image_bytes`. `ok` stays true,
  `status` is `SIZE_CAP`, `image_included` is false, `image_omitted_reason` is `SIZE_CAP`,
  and `path`/`bytes`/`sha256` are all filled in. `include_image=false` is the caller saying
  "text only": `ok` true, `image_omitted_reason: "NOT_REQUESTED"`.
- **The file is the durable record.** `path`, `bytes` and `sha256` are always reported, and
  the digest is recomputed when the image is encoded: a file that changed between capture
  and reply fails the call instead of being returned under a stale hash.
- **Two calls on the same tag are not byte-identical.** Each capture draws a fresh set of
  random paths, so the chart — and therefore the PNG — differs; only the strategy, row and
  numbers are the same. Compare `sha256` across calls only when you expect the same picture.
- **The dialog is closed after the capture.** An open Variance Testing window holds the
  foreground, so it would fight the next tool call; `dialog_closed` reports that it went
  away. A pre-existing `Variance Testing` window is closed first and counted in
  `closed_preexisting`, because it shows some other strategy.
- **Journalled** like every other tool (status, duration, file path), with `capture_variance_test`
  in `runlog.NO_JOURNAL` so the base64 image can never enter the log.

The statuses are `OK`, `TAG_NOT_FOUND`, `IDENTITY_MISMATCH`, `MENU_ITEM_MISSING`,
`WINDOW_NOT_FOUND`, `CAPTURE_FAILED`, `SIZE_CAP`, `TIMEOUT`, `PORTFOLIO_SWITCH_FAILED`,
`INPUT_BLOCKED`, `GRID_NOT_VISIBLE`, and `detail` is always filled on a failure.
A lookup failure sets `image_omitted_reason: "NOT_FOUND"` ("the tag does not exist", not "the
capture broke"); any other failure leaves that field `null` and lets `status` carry the meaning.

#### The `summary` block (OCR of the statistics panel)

The bottom-left panel is read with OCR and returned as `summary` plus `summary_status`
(`OK` / `PARTIAL` / `OCR_FAILED`). Twelve keys: `simulation`, `make_money_count`,
`make_money_pct`, `ruin_count`, `ruin_odds_pct`, `avg_pnl_dd`, `avg_profit`,
`avg_drawdown`, `conf95_profit_low/high`, `conf95_drawdown_low/high`.

```jsonc
"summary_status": "PARTIAL",
"summary": {"simulation": null, "make_money_count": 965, "make_money_pct": 96.5,
            "ruin_count": 93, "ruin_odds_pct": 9.3, "avg_pnl_dd": 2.88,
            "avg_profit": 30824.07, "avg_drawdown": 10714.81,
            "conf95_profit_low": -5977.75, "conf95_profit_high": 67625.88,
            "conf95_drawdown_low": 2002.31, "conf95_drawdown_high": 19427.3}
```

- The panel is **read from the captured bitmap**, cropped out of the window and upscaled 4×:
  it is small white-on-black text, and reading the *screen* meant a dialog that was not in
  front produced OCR of whatever was behind it (the portfolio grid, once). The saved image and
  the summary now come from the same pixels.
- **Numbers are floats.** `USD`, `%`, thousands separators and the OCR's slashed zero
  (`løøø`, `1ø792.42`) are normalised away.
- **A field that was not read is `null`, never a guess.** A confidence interval whose low
  reads *above* its high is treated as a misread digit and both ends become `null`.
- **`simulation` is `null` in practice**: the panel prints `Results of Simulation:` as a
  caption with no total of its own. A figure is only accepted when it is printed next to
  that caption, which never happens for these views — so `PARTIAL` is the normal result, and
  `OK` is unreachable until BuildAlpha prints a simulation count.
- **A failed OCR does not fail the call.** `OCR_FAILED` still returns the image and the file.
- The parsing is a pure function of the OCR lines (`ConvertFrom-VarianceText`), pinned by
  test 33 against text recorded from a live capture.

### Re-run with adjustments (`rerun_with_adjustments`)

One call = one strategy, **identified by its tag** - never by a search string. The row is found by
the shared search (`scripts/buildalpha_find_strategy.ps1`, driven by `identify.plan`: Net P&L first,
then name, then symbol, with every readable metric compared - see "Finding a strategy row"), and the
baseline the reply reports is the cells **that search verified**, not a re-read by row position
(a re-read by index was measured landing on a different row: trades 182 where 179 had been verified).
`portfolio` is only needed when the tag is listed in several portfolios.

The search's own status reaches the caller instead of being flattened to a generic failure:
`ROW_NOT_FOUND`, `AMBIGUOUS`, `IDENTITY_MISMATCH`, `SELECTION_FAILED`, `GRID_NOT_VISIBLE`,
`SYMBOL_COLUMN_HIDDEN`, `INPUT_BLOCKED`, `BUSY`.

**If the Re-Run form opens with no symbols** - which BuildAlpha does for some strategies, and does
the same when the form is opened by hand - the script puts the strategy's own symbol back through the
picker: the grid names it `LTC_1h` (instrument then timeframe), so the picker gets `LTC` plus the
timeframe row, trying the **built-in** list first and the **server-side** list second (`LTC_1h` is
built-in, `HYPE-USDT_1h` is server-side, and the two look identical). If neither list holds it the
call stops with `SYMBOLS_MISSING` and nothing is simulated. The
"No symbols chosen for simulation!" modal is dismissed and reported the same way, so a call can
never sit behind it.

```jsonc
// re-run one strategy on another symbol
{"tag": "zkdkiddhg3", "portfolio": "Hyperliquid #2",
 "symbol": {"kind": "builtin", "name": "HYPE", "timeframe": "1h"}}
// -> {"ok": true, "status": "COMPLETED", "adjustment": "field=symbol server=HYPE-USDT_1h -> builtin:HYPE",
//     "resolved": {"name": "low[0] > EMA(close,12)[0], ...", "symbol": "HYPE-USDT",
//                  "expected": {"trades": 258, "sharpe": 2.39, "net_pnl": 133606.25}},
//     "baseline": {"Symbol": "HYPE-USDT_1h", "Trades": "258", "Sharpe": "2.39", ...},
//     "results": {"result_symbol": "HYPE_1h", "trades": ..., "sharpe": ..., "delta": {...}}}
```

`baseline` is the portfolio-grid row **before** the run and `delta` is
`after - before` for every metric the grid and the results row share: Trades,
Sharpe, Net P&L, Drawdown, Drawdown MTM, P&L / DD, Win Percentage, Profit
Factor, Ratio WL, CAGR, SQM, SQN, T-Test, E-Ratio, K-Ratio, Expectancy Score,
Avg Trade, Mean/Std W and L trades, Corr Coef, CPC Ratio, Perfect Profit %,
Perfect Profit Correlation and Custom Fitness (26 values). `Robust Index` only
appears when the grid row exposes it, which portfolio rows do not.
`baseline` is reported **once**, at the top level; it is not repeated inside
`results`.



Typical calls:

```jsonc
// validate without running anything (~40 s)
{"tag": "zkdkiddhg3", "portfolio": "Hyperliquid #2", "dry_run": true}
// -> {"status": "DRY_RUN", "resolved": {...}, "verification": ["selector_count='(1)'", ...]}

// another server-side symbol (the form then reads back 'ETH-USDT (1 hour)')
{"tag": "ph37u4ux2f", "symbol": {"kind": "server", "name": "ETH-USDT", "timeframe": "1 hour"}}

// an UNNAMED strategy needs nothing special: its rule expression is the grid
// Name, and the cache already holds it, so the tag alone identifies the row
{"tag": "fvptp7fjxb", "symbol": {"kind": "builtin", "name": "HYPE", "timeframe": "1h"}}
// -> resolves the exact Name, filters by symbol only, and refuses
//    (IDENTITY_MISMATCH) if the located row's trades/sharpe/P&L differ

// change the date window as well (the caller's per-strategy stop dates differ, so
// without this a cross-venue comparison also compares different windows)
{"tag": "ph37u4ux2f", "portfolio": "Hyperliquid #2",
 "symbol": {"kind": "builtin", "name": "BTC", "timeframe": "1h"},
 "start_date": "2024-01-01", "stop_date": "2026-10-22"}
```

`start_date` / `stop_date` are written into the Re-Run form's own `Start Date` and
`Stop Date` fields and read back before anything is simulated; if the field does
not take the value the run stops with `DATE_NOT_APPLIED` (exit 21) and the window
is closed. Only the **date** is authoritative: BuildAlpha normalises the stop
time to `23:59:59`, so passing `2026-10-22 23:00` still lands on `11:59:59 PM`.

#### In-sample / out-of-sample settings (dry run only)

The dry-run reply also carries the split settings, because the strategy pages need them
and they already sit in the same 91-field form read that produces the dates:

```jsonc
{"status": "DRY_RUN", "start": "7/31/2021 12:00:00 AM", "stop": "9/23/2026 11:59:59 PM",
 "strategy_type": "Short", "commission": "0.0008",
 "oos": {"mode": "End", "percent_raw": "0.3", "percentage": 30,
         "fraction": 0.3, "split_date": "2025-03-08", "split_basis": "computed"}}
```

and on the `VERIFY` line next to the dates:

```
VERIFY start='7/31/2021 12:00:00 AM' stop='9/23/2026 11:59:59 PM' type='Short' commission='0.0008 ' oos_mode='End' oos_percent='0.3' oos_split_date='2025-03-08' oos_split_basis='computed' oos_percent_as_shown='0.3'
```

- **`mode`** is the `Out of Sample` toggle: `End` or `Begin`, i.e. which side of the
  window the out-of-sample slice sits on. It is read, not inferred.
- **`percentage`** is derived from the form's own value, which is a **fraction**: a form
  showing `0.3` means 30 %. Confirmed against BuildAlpha's serialized config, which holds
  `<OosLocation>1</OosLocation><OutOfSamplePercent>0.3</OutOfSamplePercent>` for a form
  reading `End` / `0.3`. `percent_raw` keeps the value as the form shows it, so a reader
  never has to trust the conversion.
- **`split_date` is computed**, not read — the form has no split field. It is
  `stop − span × fraction` for `End` and `start + span × fraction` for `Begin`, and it says
  `split_basis: "computed"` for that reason. It is a date arithmetic result over the
  *stated* window; BuildAlpha splits the **bars**, so a window with a gap (a data outage,
  a weekend-only series) can move the real boundary by a few bars.
- **Disabled out-of-sample reports `mode: "off"` and no percentage at all** — no `0`, no
  empty field — because `0` is not a percentage, it is the absence of a split.

This appears on the dry-run path only; the real run's stdout and payload are unchanged.

When you change the dates, the cached baseline no longer describes the run — the
delta then mixes a symbol change with a window change. Align the windows first
(`dry_run` to confirm), then compare.

### Trade lists

`rerun_with_adjustments(include_trades=true)` also captures the trade list of the run. It
is taken from the results window's own `Show Trades` (right-click the row) while that
window is still open — about 8–14 s — and it is written **to a file**, never into the
response: a thousand trades would bloat both the payload and the journal.

- File: `captures/trades/<tag>-<run_id>.tsv` — keyed by run id as well, because the same
  tag is re-run with different windows and a tag-only name would overwrite history.
- Pointer: `record.result.results.trades_detail` in the journal carries `{status, rows,
  grid_rows, columns, header_ok, rows_ok, result_sum, pnl_ok, path}`.
- Rows: `trades(run_id, offset, limit)` pages them. A local path is useless to a remote
  caller, so this is the interface and the file is only storage.
- Verification, not trust: parsed rows must equal the grid's own `RowCount`, every column the
  reader depends on must be present **in order** (the table carries 14 columns now, so an exact
  count would reject a good export), and `sum(Result)` must equal the run's net P&L (observed within
  0.06) → `TRADES_OK`, otherwise `TRADES_SUSPECT`. The `Result` column is found **by name**: index 9
  used to be hardcoded, and with 14 columns that index is `Position size`, which produced a
  plausible-looking wrong sum (519393.71 for a run whose P&L was 131528.92).
- The right-click anchor comes from the window's **own cells** (one `FindAll`), never from a
  hardcoded x: measured x=120/60/760 fell left of every column on a results window whose grid starts
  at x=131, no context menu opened, and the export ended `CONTEXT_MENU_MISSING`.
- `include_trades` with `dry_run` is rejected: a dry run simulates nothing.

Copying beats reading cells: 233 rows × 10 columns through `GridPattern.GetItem` would be
~2,330 calls at ~0.2 s each, against ~2 s for one `Ctrl+A`/`Ctrl+C`.

Two traps here: right-clicking inside the **Name** column opens the interactive (rename)
menu instead of the grid menu, so the click goes to a plain column (`x=120`); and the row's
Y must be a data row, not the header. When the caller supplies the row itself,
`-ExpectName` verifies the Trades window title against the strategy before copying.

**The first right-click sometimes misses the menu.** A right-click on a grid that does not
have focus does nothing, and just after a simulation the results window has only just
appeared. Each attempt therefore focuses the window, left-clicks the row, then right-clicks,
and waits 4 s — up to three times. A run that still reports `CONTEXT_MENU_MISSING` did the
simulation fine and only lost the export; retrying the run is safe.

`trades(run_id)` distinguishes four "no rows" outcomes, so a caller never discards a good
run: `NO_TRADES` (the run took none), `TRADES_NOT_CAPTURED` (`include_trades` was asked for
but nothing was stored — read the run's status), `TRADES_EXPORT_FAILED` (the simulation ran,
the export step failed — `export_status` says how), `NO_TRADES_RECORDED` (the run never
asked for trades).

**Trade times carry no offset.** BuildAlpha renders them in the host's local zone. The
paged response states it: `trade_times: {source, utc_offset, zone}` — on this machine
`+0700`, `SE Asia Standard Time`. Convert before joining against UTC data.

**Take `run_id` from the journal record, not from the start reply.** The `RUNNING` reply
returns both (`run_id` = journal id, `job_id` = internal handle); only the record's
`run_id` works with `trades(run_id)`.

**Zero trades is a result, not a failure.** BuildAlpha renders no data row when a run
takes no trades. That is reported as `status: "NO_TRADES"` (exit 0, `ok: true`) with
`trades: "0"`, `no_trades: true` and `symbol_evidence: "no_results"` — the symbol
cannot be confirmed from a grid with no row. It is *not* a blank success and not an
unreadable-grid error. The `costs` block (commission and slippage, with their modes) is
returned for every run, including this one.

**Symbol verification.** A run is only reported with metrics once the results grid's own
`Symbol` column matches the request; if it shows another series the
run stops with `SYMBOL_MISMATCH` (exit 24) and the results window is closed
before any numbers are returned. A *dry run* cannot do that — there is no results
grid — so its evidence is the picker row whose checkbox was ticked, reported as
`symbol_evidence: "picker_row"`.

The form's `Symbols` reading (`symbols_line`) is **OCR of the drawn selector**, not
a UIA value — `symbols_line_source: "ocr"`. A stray glyph can be glued onto the
name, so `builtin:XRP` sometimes reads back as `IXRP`; that is OCR noise, not a
symbol code and not an alias. A name that appears anywhere inside the OCR text is
accepted; anything else is reported as `FORM_LABEL_OCR_MISMATCH`
(`form_label_ocr_differs: true`) and never turned into a guess about what the
symbol "really" is.

Deliberately a **closed set**: only the symbol is adjustable today. Dates, costs,
type and fitness each need their own verified interaction method (a DevExpress
combo only commits on a real mouse click, a date edit only on `SetValue` +
Enter), so they are added one at a time instead of exposing "any of the 91
fields". Results are **not** written to the cache: the cache holds only what a
portfolio contains, and a variant run is never saved into one.

Typical queries:

```jsonc
// best 5 strategies of a portfolio with at least 50 trades
{"portfolio": "Common Portfolio", "min_metrics": {"trade_count": 50},
 "sort": "sharpe", "order": "desc", "limit": 5}

// every @ES timeframe with drawdown under 2000, tightest first
{"symbol": "@ES", "max_metrics": {"drawdown": 2000},
 "sort": "drawdown", "order": "asc", "limit": 20}

// page 3 of short strategies that use rsi, by trade count
{"strategy_type": "Short", "name_contains": "rsi",
 "sort": "trade_count", "order": "desc", "limit": 20, "offset": 40}
```

Each response carries `total` (ignoring `limit`/`offset`), the echoed filters and
`rows`, so a client can page without guessing. Invalid `sort` or metric names
return a tool error listing the valid ones; values are bound parameters, and
only whitelisted columns reach the SQL.

The tool shells out to `buildalpha_status.ps1` on every call (UI Automation,
~1 s). No GUI modules are imported into the server process, and the SDK runs
sync tools on a worker thread, so a capture does not block other requests.
Concurrent captures are serialised, and `--status-timeout` (default 30 s) bounds
a hung capture. Every capture rewrites the snapshot, which `fresh=false` and the
CLI then read:

```sh
uv run python -m strategy_cache.status capture --db .\scripts\buildalpha_cache.sqlite3   # producer
uv run python -m strategy_cache.mcp_server --sse --db C:\path\to\buildalpha_cache.sqlite3  # consumer
```

The snapshot defaults to `buildalpha_status.json` next to the database; point
elsewhere with `--status <file>` or `BA_STATUS_FILE`. Without a snapshot,
`buildalpha_status` returns a tool error that says how to create one.

## Files

- `strategy_cache/identify.py` - the single decision point for "how do we find this strategy's
  row": name first, then symbol + cached numbers, and why rule text is never used.
- `scripts/buildalpha_find_strategy.ps1` - executes an `identify.plan()` against the live grid
  and reports every attempt (`FIND {...}` on stdout).

Layout:

```text
scripts/                           every buildalpha_*.ps1 (UI Automation)
strategy_cache/                    Python package: parse, cache, queries, MCP server
migrations/                        Alembic migrations 0001, 0002
captures/                          recorded data: grid/form captures and analysis notes
alembic.ini, pyproject.toml,        configuration; runtime state stays git-ignored
uv.lock, pyrightconfig.json        (cache DB, status snapshot and history)
```

The scripts are invoked by path (`scripts\buildalpha_grid_rows.ps1`); they find
their shared helper through `$PSScriptRoot`, so the whole folder can move as one
unit. Python constants that point at them live in `strategy_cache/actions.py`
(`DEFAULT_SCRIPT`, `DEFAULT_FILTER_SCRIPT`) and `strategy_cache/status.py`
(`SCRIPT`), and `portfolio_sweep.py` defaults its captures to `captures/`.

- `captures/grid-probe.txt`: notes from investigating the portfolio grid's row count
  (it is a TreeList; `RowCount` is the top-level strategy count while the
  `"of 8899"` total counts nested child nodes).
- `captures/portfolios.txt`: the 10 BuildAlpha portfolio names, plus how to read and
  switch them via UI Automation.
- `scripts/buildalpha_rerun.ps1`: re-runs a portfolio strategy via its right-click
  context menu (OCR-assisted, because the menu has no accessible item names).
- `scripts/buildalpha_start.ps1`: starts / inspects / stops BuildAlpha with the
  **install directory** as working directory (`-Action status|start|stop`), so
  `Data/`, `DataCache/` and `logs/` never land in this repository.
- `scripts/buildalpha_uia.ps1`: shared UI-Automation helpers (foreground, grid read,
  row lookup, OCR menu, window diff, screenshot) dot-sourced by the scripts
  below.
- `scripts/buildalpha_rerun_compare.ps1`: re-runs a strategy, reads the separate
  results window, and writes a `Metric / Before / After / Delta` report
  (`-DryRun`, `-RowY`, `-KeepResults`).
- `scripts/buildalpha_seasonality.ps1`: opens the Seasonality (or Monthly Returns)
  view for a strategy and saves a PNG (`-ListOnly`, `-Item`, `-CloseWindow`).
- `scripts/buildalpha_form_reader.ps1`: reads every labelled field from a `Re-Run` or
  `Strategy Builder` form across all tabs (`-Title`, `-ListTabs`,
  `-CurrentTabOnly`).
- `scripts/buildalpha_status.ps1`: read-only status report (process, active job, job
  start, throughput, result count, filter); `-Json` for machine output.
- `captures/re-run-fields.txt`: a captured `Re-Run` form record (91 fields across the
  `Main` and `Additional Settings` tabs).
- `captures/kraken-*.txt`: per-strategy config dumps for the four Kraken strategies
  (`captures/kraken-configs.txt` is the combined record).
- `captures/grid-*.txt`: full 35-column portfolio-grid captures (metrics source).
- `strategy_cache/`: tag computation, capture parsing, SQLite ingest, selfcheck.
- `strategy_cache/models.py`: Pydantic `Settings` validation for ingest.
- `strategy_cache/queries.py`: read-only query helpers (`list_strategies`,
  `get_strategy`, `list_portfolios`, `cache_stats`).
- `strategy_cache/metrics.py`: glossary for the 26 metric columns (label, unit,
  direction, group) used by the `describe_metrics` MCP tool.
- `strategy_cache/status.py`: status capture + snapshot - `capture` runs
  `buildalpha_status.ps1`, `refresh` captures now, `latest` falls back to the
  snapshot (with `capture_error`) when capture fails; `read` annotates
  `age_seconds` / `stale` / `mode`. Stdlib only, no GUI imports.
- `buildalpha_status.json`: latest status snapshot (output of the above).
- `buildalpha_status.history.jsonl`: one line per capture, used to detect when a
  running job disappeared (`job.ended_source = observed`).
- `strategy_cache/mcp_server.py`, `strategy_cache/__main__.py`: read-only MCP
  server (stdio by default, `--sse` for the tailnet; 6 tools).
- `scripts/buildalpha_grid_rows.ps1`: bulk-reads the portfolio grid's top-level rows
  (444 for Common Portfolio) via `GridPattern`, all 35 columns, ~75 s.
- `captures/grid-rows.txt`: the last grid capture (`# top_level=...` header + TSV).
- `strategy_cache/grid_ingest.py`: parses a grid capture into cache rows
  (logical tag, 26 metrics, `"source":"grid"`), refreshes metrics on re-scan.
- `strategy_cache/actions.py`: opt-in action bridge - runs
  `buildalpha_continuous.ps1` and summarises its verdict/audit for MCP.
- `strategy_cache/tests_pipeline.py`: contract tests for tags and cache semantics.
- `alembic.ini`, `migrations/`: schema migrations (`0001` creates `strategies`,
  `0002` creates `strategy_portfolios` and backfills membership).
- `scripts/buildalpha_switch_portfolio.ps1`: switches the portfolio selector
  (`-List`, `-Name`); verifies by reopening the popup and checking
  `IsSelected`; exit 4/5 when the name is unknown / unconfirmed.
- `scripts/buildalpha_settings.ps1`: opens / closes the **Settings** window
  (`-Action open|close|status`, `-ClickFirst`); F8 first, row click as fallback.
  See *Opening Settings (F8)*.
- `strategy_cache/portfolio_sweep.py`: switch â†’ capture â†’ ingest for every
  named portfolio, restoring the one selected at start.
- `buildalpha_cache.sqlite3`: the cache (git-ignored).
- `stratABC-rerun-comparison.txt`: before/after metrics for a re-run (146 ->
  157 trades), including the note that the re-run opens a separate results
  window.
- `seasonality-analysis.txt`: Seasonality findings for
  `seasonality strategy test` (April is the only losing month, with reasoning).
- `result.txt`: output from the last run.

## Platform notes

### Input guard, topmost and the desktop lock

A run once pinned the main BuildAlpha window with
`SetWindowPos(hwnd, HWND_TOPMOST, …)` and never released it (`HWND_NOTOPMOST` appeared
nowhere in that script). When a confirmation dialog from another program appeared, the
pinned window sat above it and above Task Manager, the dialog could not be reached, and
the machine had to be restarted. Three things now prevent that, and one heals it.

1. **No task script pins a window.** `Focus-Main` in `scripts/buildalpha_rerun_adjust.ps1`
   clears topmost instead of setting it (`Clear-Topmost`, `HWND_NOTOPMOST`). Raising above
   its own dialogs is `BringWindowToTop`, which does not affect other processes.
2. **One guarded path for every injected event.** `Test-InjectionAllowed` lives in the
   shared helper `scripts/buildalpha_uia.ps1`; `Send-Keys`, `Send-KeyEvent`,
   `Invoke-LeftClick`, `Invoke-RightClick` and `Set-AppForeground` all call it immediately
   before acting, so a dialog appearing between the check and the keystroke is still
   caught. If the foreground belongs to **another program** (measured: an editor left in front while
   a tool ran) it brings Build Alpha back to the front **once** and continues - input must never land
   in the other window, but refusing outright turned "the operator is looking at a log" into a hard
   blocker. It still refuses for a BuildAlpha window this run did not open (a popup owned by a window
   it did open, such as the picker, is fine). A refusal ends the run as `INPUT_BLOCKED` (exit 25)
   with the dialog still clickable, instead of typing into whatever is in front.
3. **Teardown on every exit.** `scripts/buildalpha_rerun_adjust.ps1` has a script-level
   `trap` that releases topmost before exiting, whatever the failure.
4. **A pre-flight that heals leaks.** `rerun_adjust.release_topmost()` runs
   `scripts/buildalpha_release.ps1` before every run started through the MCP tool. A
   PowerShell `finally` does not run when the process is killed, and a timeout kill, a
   host reboot or an RDP loss skips teardown entirely — so the next run clears
   `WS_EX_TOPMOST` on every existing BuildAlpha window. Its result is returned as
   `preflight` in the tool payload.

`scripts/buildalpha_release.ps1` is also usable by hand (after any bad state, no reboot
needed):

```powershell
powershell -File scripts\buildalpha_release.ps1 -Json
# {"status":"RELEASED","windows":19,"cleared":[{"hwnd":67124,"title":"Build Alpha"}],...}
```

It uses `SWP_ASYNCWINDOWPOS` (`0x4000`) on purpose: `SetWindowPos` sends
`WM_WINDOWPOSCHANGING` synchronously, so against a hung window a synchronous release would
block — exactly when it is needed.

Verified: a topmost window is cleared and read back as clear; a pin simulated on the real
BuildAlpha window is cleared by the pre-flight (`still_topmost: []`); a dry run leaves
`GetWindowLong(-20) & 0x8 == 0` on every BuildAlpha window; and with a foreign window
holding the foreground the run ends `INPUT_BLOCKED` (exit 25) without injecting input.
Not verified end-to-end: the "user clicks a dialog, run aborts" case needs a human click,
because Windows refuses foreground grants to processes that are not already in front.

### One driver at a time (`BUSY`)

Every tool that drives the GUI acts on one grid, one foreground window and one selection, and the
MCP server runs synchronous tools in a thread pool - so two calls can overlap without anyone
intending it, and one call's click lands in the other's filtered grid.

`logs/ui.lock` is opened with `FileShare.None` and held for the life of the driving process. Windows
releases it when that process dies, so a crashed run cannot wedge the app and there is no stale-pid
bookkeeping. A child inherits `BA_UI_LOCK_HELD` and passes through, so a capture's search and re-run
children do not fight their own parent.

Every driving script starts with `Start-BuildAlphaUi`, which does exactly three things and returns
one word:

| result | meaning | exit |
|---|---|---|
| `OK` | lock taken, BuildAlpha running, now in front | 0 |
| `UI_BUSY` | another call holds the lock - nothing was touched | 40 |
| `NOT_RUNNING` | BuildAlpha is not running | 41 |
| `INPUT_BLOCKED` | it will not come to the front | 25 |

The lock has **no timeout, by design**: expiring it would let a second call start while the first is
still clicking. It clears when the owner exits, or when you kill it. A process blocked inside a Win32
or UI Automation call (or behind a modal) stays alive and holds the lock - measured twice; the fix is
to kill it by pid:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' or Name='python.exe'" |
  Where-Object { $_.CommandLine -match 'buildalpha_' }
Stop-Process -Id <pid> -Force
```
### Rerun performance

A rerun takes ~50 s (dry run ~38 s) and only ~6 s of that is the simulation. The
phase-by-phase breakdown, the measured cost of each UI-automation primitive, and a
list of optimisations that were **tried and measured worse** live in
[`PERFORMANCE.md`](PERFORMANCE.md) - read it before trying to speed this up, so the
same three dead ends are not attempted again.

### Opening Settings (F8)

`scripts/buildalpha_settings.ps1` drives the **Settings** window, which is where
the built-in symbol definitions live (`Symbols` tab: 164 rows x 18 columns -
`Name, Time, Unit, Variation, Description, Time Zone, Is DST, Point Value,
Margin, Session End, Currency, Type, Min Tick, Min size, Swap, Slippage File,
Tick Data File, Filename`; `Filename` is the data file for that symbol).

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_settings.ps1 -Action status
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_settings.ps1 -Action open
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_settings.ps1 -Action close
```

- `open` restores the window if it is minimised (`-32000,-32000`) or narrower
  than 1000 px, brings it to the foreground, then presses **F8**. If Settings
  does not appear within 6 s it clicks a portfolio-grid row (that click is what
gives the grid keyboard focus) and presses F8 again; the output says which path
  won (`via=f8`, `via=f8-after-click`, or `via=click-then-f8` with
  `-ClickFirst`).
- `close` uses the window's own `Close` button (UIA `Invoke`), falls back to
  `WM_CLOSE`, and fails loudly with `PROMPT title=...` if a modal appears
  instead. Settings closes without a prompt - it holds no unsaved state.
- `status` reports `STATE_OPEN hwnd=... rect=... symbol_grid rows=.. cols=..` or
  `STATE_CLOSED`.

Verified: three consecutive open/close cycles, all `via=f8` (1.4-2.7 s to open,
0.22 s to close, grid always `164 x 18`); open from a minimised window; the
`-ClickFirst` path; and idempotency (`ALREADY_OPEN` / `ALREADY_CLOSED`).

Two traps this encodes: F8 is only handled when the **portfolio grid** has
focus, so a fresh restore may need the row click first; and the Settings window
is an *owned* top-level window, so a helper that filters windows by title must
not skip owned windows (a plain enumerator can miss it).

### Finding a symbol in Settings (search)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_lookup.ps1 -Symbol xyz_CL
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_lookup.ps1 -Symbol ZEC -Json -Close
```

It opens Settings if needed, records the current search text and the row count,
sets the query (via `ValuePattern`, not keystrokes, so `@`, `&`, spaces and
brackets survive), waits for the filter, reads row 1, and **restores the search
panel** afterwards. Verdicts:

| status | exit | meaning |
|---|---|---|
| `FOUND_EXACT` | 0 | exactly one row and its `Name` equals `-Symbol` |
| `AMBIGUOUS` | 4 | several rows matched; they are listed as `candidate:` lines |
| `NAME_MISMATCH` | 5 | one row matched but its `Name` differs (a hit in another column) |
| `NOT_FOUND` | 3 | no rows matched |
| `WARN`/exit 6 | 6 | the panel could not be restored to its baseline count |

The find panel **matches substrings across every column** and **debounces for
~1.2 s**, which are the two things that make naive automation lie: waiting for
the row count to "stop changing" returns the pre-filter baseline, and a raw
query like `CL` matches `@CL`, `@MCL` *and* `xyz_CL`. Queries of one or two
letters can match all 164 rows (`e` and `C` both do, via the Time Zone text
"Coordinated"). Hence: wait for a *change* then settle, read the count, and only
trust a hit when the count is 1 and the `Name` column equals the query.

Limitation: a genuine symbol name can still match several rows (`HYPE` matches
30), so an ambiguous verdict is refused rather than guessed. The candidate list
makes that resolvable by an exact `Name` comparison — see *Known limitations*.

### Writing a single cell in Settings > Symbols

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Get
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Value 'abc'
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column 'Tick Data File' -Clear
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Value 'abc' -DryRun
```

This is the gesture set that actually works; every step below was arrived at by
measurement, and each earlier naive attempt failed for a specific reason:

1. **Filter first, then verify identity.** The find panel searches all columns and
   debounces ~1.2 s, so the script waits for the row count to *change* and settle,
   then refuses unless the count is 1 **and** row 1's `Name` equals `-Symbol`
   (`SYMBOL_NOT_FOUND` / `AMBIGUOUS` / `ROW_MISMATCH`, nothing is clicked).
2. **Cell geometry comes from the column header,** not from the cell: headers have
   sane bounding rects and scroll with their columns; cells expose `NaN`/infinite
   rects once virtualised. The script clicks the header's x (left part of the cell,
   to avoid a path column's browse button) at the first data row's y.
3. **The editor must be confirmed open before any key is sent.** A cell in edit
   mode exposes `TextEditRow …` (plain text) or `ButtonEditRow …` (path column with
   a browse button). Keys sent earlier go to the *grid*, which is exactly how a
   value gets typed into the wrong cell or appended instead of replaced.
4. **`Ctrl+A` inside the editor** really does select the whole text (the grid's own
   select-all does not apply there). So `Ctrl+A` + paste replaces, and `Ctrl+A` +
   `Delete` clears a cell to empty - the operation that no direct gesture managed.
5. **The write is verified by reading the cell back** (short poll; the peer lags a
   beat behind the commit) and retried once, then reported as `VERIFY_MISMATCH`
   with the actual value - never as success.
6. **The editor is dismissed afterwards,** and the find panel is restored to empty
   with the row count re-checked.

Path columns (`Slippage File`, `Tick Data File`, `Filename`) commit on **focus
change**, not on `Enter`, so the script clicks another cell to commit them.

Verified end to end: `Variation` write and clear; `Tick Data File` write and clear;
a no-op rewrite of `Filename` with its own value; a 180-character value written and
cleared (the length that previously produced a concatenated mess); `-DryRun`
leaving the cell untouched; `CL` refused as ambiguous; an unknown column refused;
and after all of it the `xyz_CL` row compared **byte-identical** to a snapshot of
the table taken beforehand (`captures/symbols-backup.tsv`, 164 rows).

### Starting BuildAlpha: the working directory matters

BuildAlpha resolves its data folders **relative to the process working
directory**. The log shows bare relative paths (`Downloading (Data\SMHRaw.txt)`)
and no config file in the install directory carries a data path
(`AppConfig.config`, `HavAppConfig.config`, `BuildAlpha_x64.exe.config` were
checked). Launching the exe while the working directory is this repository
creates `Data/`, `DataCache/`, `logs/` **here** - a 994 MB `Data/` tree
(`dailybars.zip` alone 867 MB) is exactly what happened once.

Always start it with the install directory as CWD:

```sh
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_start.ps1 -Action status
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_start.ps1 -Action start
powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_start.ps1 -Action stop   # -Force to kill
```

`status` prints pid, start time, window state and the `Data/` directory that is
actually being written. `start` sets `-WorkingDirectory` to the install
directory (found via the uninstall registry entry, then known paths) and waits
for the `Build Alpha` window; it refuses to start twice. Every other script here
only *attaches* to the running app and never launches it.

Watch out for launchers that `cd` into this repo first (a `Start-Process` from a
shell sitting here, a scheduled task, an IDE run configuration): that is what
creates the stray `Data/`. `Data/` is git-ignored, and can be deleted once
BuildAlpha is stopped - it is a partial copy of the install's own data.

- BuildAlpha access uses Windows UI Automation on the `stratGrid` portfolio
  **TreeList**. Important behaviours:
  - The grid's automation peer is only exposed shortly after the app finishes
    loading, so the script **polls** for it (and dismisses the one-time
    "Indexes" modal each pass) instead of a fixed sleep.
  - The "Indexes" modal is a top-level window whose raw Win32 title is exactly
    `Indexes`; its `No` button (`PART__NoDialogButton`) has no `InvokePattern`,
    so it is clicked by coordinates.
  - Synthesised input only reaches the app when it is the true foreground
    window; the script forces this with `AttachThreadInput`.
- BuildAlpha portfolios (list / switch): the Portfolio pane header has a
  selector `ComboBoxEdit` (~127,71). Escape then click to open the dropdown.
  Each `ListItem`'s automation Name is the object type
  (`TradersToolbox.Core.Serializable.PortfolioSettings`); the real name is in
  the item's child `Text` element. A whole-desktop scan also returns desktop
  icons, so filter to the dropdown by geometry (x ~29, width ~196).
  To **switch**, a real **mouse click** on the item commits it â€”
  `SelectionItemPattern.Select()` only highlights. Verify by reopening the
  dropdown and checking the item whose `IsSelected = true` (the combo's
  `ValuePattern` is not populated while the new portfolio loads). See
  `portfolios.txt`.
- BuildAlpha strategy **re-run**: use the ready-made script `buildalpha_rerun.ps1`
  (verified against v3.22.37). It selects a real data row (left-click a
  non-editable `Symbol` cell, then right-click it), waits for the row context
  menu, screenshots it, OCRs the item text with the built-in
  `Windows.Media.Ocr` engine, and clicks `Re-run strategy`.

  ```sh
  # list the menu items only (safe, no click)
  powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_rerun.ps1 -ListOnly
  # actually re-run the first visible strategy
  powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_rerun.ps1
  # re-run a specific row (optional Y coordinate)
  powershell -ExecutionPolicy Bypass -File .\scripts\buildalpha_rerun.ps1 -RowY 131
  ```

  Why it needs OCR: the popup contains a `Menu` with
  `AutomationId='GridContextMenu'`, but the menu is **custom-drawn** â€” its ~25
  child nodes have **empty automation names**, so items can't be found by name
  via UIA (keyboard Down moves the highlight but `FocusedElement` stays on the
  window). Items include `Delete selected`, `Enable/Disable selected`,
  `Move to`, `Show Trades`, `Show Chart`, `Seasonality`,
  `Intelligence Report`, `Optimization and Sensitivity`, and
  **`Re-run strategy`**. Requires Windows 10+ with an OCR language pack.

  Success check: `app.log` right after the click shows
  `BrokersManager.LoadServerSideData(): start loading (<symbol>)` for the row's
  symbol, then `Reading AdditionalData ... complete` (the re-simulation).
- BuildAlpha grid reads: when `FindFirst(AutomationId='stratGrid')` returns
  null, individual cells are still reachable via
  `AutomationElement.FromPoint(x,y)` (returns the `TreeItem` for that cell), so
  screen-point probing is a reliable fallback for reading/targeting rows.
- Capturing a full strategy record: find the `DataGrid` by walking up from
  `FromPoint(x, y)` at a non-editable column (x ~ 200), then parse cell names
  with `^Row (\d+) of \d+, Column (.+?), Column \d+ of \d+: (.*)$`. While a
  cell is in edit mode the names become `TextEditRow ...`, so press Escape a
  few times first. The columns are virtualised: scroll the grid horizontally
  (`ScrollPattern`) and merge the cells for the target row to realise all 35
  columns. Row height is ~20-24 px; the `Name` column is at x ~ 400 and `Type`
  at x ~ 200.
- Re-run results window: clicking **Re-run strategy** does **not** change the
  original grid. BuildAlpha opens a **new top-level window** for the result
  (same PID, empty Win32 title, full-size ~1510x894, floating over the main
  window). `buildalpha_rerun_compare.ps1` snapshots the visible handles before
  the click and diffs afterwards; skip the transient `GridContextMenu` popup.
  Its grid has a slightly different
  schema: it adds **Robust Index**, shows `Index` as `1 ALL`, omits
  `Type`/`State`/`X`/`Live Position`, and its `Name` is the rule expression
  rather than the portfolio's custom name - so match the strategy by `Symbol`
  plus `Exit Params`. Do **not** send Escape after the click: that closes the
  results window.
- Seasonality / Monthly Returns: both menu items open their own windows
  (`Seasonality - <strategy>`, `Monthly Returns`). The charts are custom-drawn,
  so bar values are **not** exposed through UI Automation. Capture the window
  with `Graphics.CopyFromScreen` into a PNG and inspect the image. The
  Seasonality window has four panels (Days, Months, Quarters, Years); negative
  bars are drawn in **red**. `Monthly Returns` is a month x year grid whose
  headers and values are `Text` elements with screen coordinates, but mapping
  rows/columns by position is noisy - treat it as best-effort.
- Form windows (`Re-Run`, `Strategy Builder`): these are `SimTaskWizardView`
  forms with a top-level `DXTabControl` whose `DXTabItem` tabs are `Main` and
  `Additional Settings`. Only the selected tab's content exists in the
  automation tree, so each tab must be selected (`SelectionItemPattern.Select`)
  before reading. `Main` groups exit settings in `GroupBox`es (checkbox label +
  `ATR`/`Fixed`/`%` unit sub-tabs + spin edits that are **siblings** of the box,
  matched by screen Y); `Additional Settings` wraps each field in a labelled
  `LayoutItem` pane. Fields expose `ValuePattern` (dates include the time of
  day), checkboxes expose `True`/`False`. Use `buildalpha_form_reader.ps1`.
- Window housekeeping: move a window aside with
  `SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE|SWP_NOZORDER)` and close a
  result window with `PostMessage(hwnd, WM_CLOSE, 0, 0)` instead of pressing
  Escape, so the main app is not disturbed.

### Common Portfolio is the master list

Every strategy exists in Common Portfolio. Being listed there means nothing on its own; a strategy
is *additionally* linked to Training / Robust / Hyperliquid / ... only when it was added to that
saved portfolio. Two consequences the code now enforces:

- **A scan of the master list must not create a second tag.** Identity is derived from the row text,
  so the same strategy read again can produce a new tag (a re-formatted rule expression moves the
  hash). Measured: `XMR|1h` and `ZEC|1h`, identical symbol / trades / Sharpe / P&L / drawdown / name,
  two tags each. Ingest now looks for an equivalent strategy first - same symbol, Trades within 0.5,
  Sharpe within 0.02, Net P&L within 0.5 (`db.find_equivalent_tag`) - and adopts that tag. Merged rows
  do **not** go through `upsert_strategy` (doing so appended `-2` and recreated the duplicate under a
  new name); they only record the membership. Named portfolios keep their own rows untouched.
- **A short capture is never trusted.** The clipboard grid copy is flaky (433 rows once, then 355 and
  367 of 433 in one session) and a short copy is indistinguishable from "these strategies were
  deleted". `buildalpha_grid_rows.ps1` retries until the copy's row count equals
  `GridPattern.RowCount`, then fails with `GRID_COPY_INCOMPLETE`. The scan itself is stored with
  `ok=0` whenever parsed rows disagree with the grid, so it can never become current.

Running a scan: `python -m strategy_cache.portfolio_sweep --only '<Portfolio>' ...`. It switches
through `scripts/buildalpha_set_portfolio.ps1` (UI guard + in-process `Set-PortfolioVerified`, no
resize, no topmost pin) and reads each grid with `buildalpha_grid_rows.ps1` (guarded, clears any
leftover filter first - measured: a stale filter produced `grid_rows=1`, which would have marked 432
strategies deleted).

### Portfolio membership is a snapshot (so deletions are visible)

Membership used to be an append-only ledger: a strategy deleted in BuildAlpha kept
its row forever and the cache could not tell it had gone. Schema `0003` makes a
**scan** the unit of truth:

- `portfolio_scans` — one row per capture: `started_at`, `finished_at`,
  `captured_rows` (parsed) vs `grid_rows` (what BuildAlpha's grid reported),
  `source`, `ok`.
- `scan_memberships` — one row per strategy seen in that scan, with its `position`
  (grid order).

So "currently in portfolio P" means *in the membership of the newest scan of P
with `ok = 1`*. A strategy deleted in BuildAlpha is simply **absent from that
snapshot** — no flags, no timestamp guessing:

| question | how it is answered |
|---|---|
| is it in P now? | `query_strategies(portfolio="P")` (current semantics) |
| was it ever in P? | `query_strategies(portfolio="P", include_removed=True)` |
| what was deleted, and when? | `portfolio_changes("P")` → `added` / `removed` between the two newest ok scans |
| where did it go? | `portfolios` vs `portfolios_ever` on each row |

**Nothing is lost by scanning.** Old scans are kept, so history stays answerable:
a removed strategy still exists in `strategies` (identity, settings, last-read
metrics) and you can see which scan it disappeared after. Old scans are dropped
only by explicit retention: `portfolio_sweep.py --retain N` keeps the newest `N`
scans per portfolio **plus the first one** (the diff baseline). `--retain 0`
(the default) keeps everything; at ~740 membership rows per full sweep that is
single-digit megabytes per year of daily sweeps.

**A bad capture can never look like a deletion.** `ok` is only set when the parsed
row count equals the row count the grid reported; otherwise the scan is stored
with `ok = 0` and `note`, so it stays auditable but never becomes "current". The
first snapshot on an existing database is backfilled from the `0002` ledger, so an
upgraded cache is usable immediately without re-sweeping.

### Run log (post-mortem for failed calls)

Every tool call is journalled as one line of JSON in `mcp.log` next to the database
(`--log-file` to move it, `--log-file ''` to disable), plus a `tool_call_start`
line so a killed or hung call is identifiable by a start with no matching finish:

```jsonc
{"ts":"…","event":"tool_call_start","run_id":"9455bf1dbb3d","tool":"rerun_with_adjustments","tag":"ph37u4ux2f","args":{…}}
{"ts":"…","event":"tool_call_finish","run_id":"9455bf1dbb3d","tool":"rerun_with_adjustments","tag":"ph37u4ux2f",
 "status":"DRY_RUN","exit_code":0,"duration_ms":58756.0,"windows":["Build Alpha"],
 "stdout":"portfolio: already on Hyperliquid #2\n…","stderr":"","result":{…full payload…}}
```

- **Retention is the stdlib handler's job**: rotate at midnight *or* at
  `--log-max-mb` (default 32), keeping `--log-retain` files (default 14). Nothing
  else prunes. Typical use is tens of MB retained; compaction is what keeps it there.
- **Compaction:** a *successful* read-only call stores a digest
  (`{"compacted":true,"total":45,"rows":45,…}`) instead of 50 rows. Action tools
  and **every non-OK status keep the payload in full** — those are the ones worth
  recovering or debugging.
- Text fields are capped at 256 KB each with `stdout_truncated` / `stdout_bytes`
  set, so a runaway script dump cannot blow the file up.
- `stdout`/`stderr` are the **script's** output, captured by the wrapper even
  though they never reach the caller's payload.

Two tools read it back:

| tool | use |
|---|---|
| `get_last_result(tag, include_dry_run=False)` | after a timeout or a `RUNNING` reply: the work was already journalled, so fetch it instead of re-running. Returns `{record, in_flight, dry_run_record}` - `record` is a **real** run (a dry run is only returned with `include_dry_run=true`), and `in_flight` means "still running, poll again" |
| `recent_runs(limit, tool, status, tag)` | post-mortem view, newest first; `status='FORM_READ_FAILED'`/`'EXCEPTION'`/`'TOOL_ERROR'` for failures, `tag='<tag>'` for every run of one strategy (a later run never hides the earlier evidence) |

**Slow runs are handed off, not failed.** A real rerun takes 52-75 s while a caller
may give up at 60 s, so `rerun_with_adjustments` waits `max_wait_sec` (default 45)
and then returns `{"status": "RUNNING", "run_id": ...}` while the run continues in
the background and journals its own outcome. Only one BuildAlpha run may be in
flight at a time: a second call gets `{"status": "BUSY", "active_run_id": ...}`
because two would fight over the same UI.

The log readers and the rerun tool are never journalled by the generic wrapper
(`get_last_result` would otherwise shadow the record it is looking up, and the
rerun tool journals itself because it may finish after the call returns).

A failure payload now also carries `windows: ["Build Alpha"]` (the titles actually on
screen), and `windows_cleaned` is derived from that list rather than from which
cleanup branch ran — so it can no longer claim the window was left open when it
was not.

The log's fields, levels and rules are specified in `docs/logging.md`; `--log-level debug`
adds one line per capture stage. **Where the time went, and where a call died.** A capture reports `stages` - one entry per step
with its duration - and `last_stage`. The same lines are written to the log, lifted to the top
level of the `tool_call_finish` record, so `grep last_stage logs/mcp.log` answers "which step" for
every call, failed or not. A killed call used to leave nothing but `capture timed out after 150s`
and the command line; the runner now keeps the child's partial stderr, and the script announces
each stage on stderr before starting it, so a timeout reads `TIMEOUT ... during stage
'wait-results-window'` with the stages it reached.

Measured example (`capture_mc_drawdown`, HYPE row, healthy session): `portfolio=7973 ms,
search=38906 ms`. On a disconnected session the search step fails fast with `Access is denied @
184` - previously that surfaced as a bare `IDENTITY_MISMATCH`.

### Known limitations

- **`MENU_ITEM_MISSING` has no live reproduction.** The item is a navigation button, not a
  menu entry, so it is either present in the panel's UIA tree or the whole tree changes with
  a BuildAlpha update. The status and the "no file written" behaviour are covered by unit
  test 32 (a missing `CAPTURE` line maps exit 6 to `MENU_ITEM_MISSING` with `path: null`),
  but no live call has ever produced it.

- **No row with out-of-sample switched off has been observed.** Every form read so far
  shows `Out of Sample: End` with `0.3`, and BuildAlpha's serialized config carries a
  single `<OutOfSamplePercent>0.3</OutOfSamplePercent>`, so the split appears to be an
  application-wide default rather than something a strategy stores per row. The
  `mode: "off"` branch is therefore covered by a unit test on the reader (percent `0`
  and a blank both report `off` with no percentage) but has **not** been seen on a live
  row. If a real row ever reports `off`, that is the first evidence of a per-row setting.

- **The Settings symbol search is substring-across-all-columns, not a name
  lookup.** `buildalpha_symbol_lookup.ps1` therefore exposes the ambiguity
  instead of resolving it: `HYPE` matches 30 rows, `CL` matches `@CL`, `@MCL`
  and `xyz_CL`, and one- or two-letter queries match all 164 rows. Only
  `rows == 1` plus an exact `Name` comparison is reported as `FOUND_EXACT`.
  Resolving the ambiguous case automatically requires comparing the candidate
  list against the query on the `Name` column only - designed, not implemented.
- **Editing the Symbols grid requires the dedicated script.** `Delete`,
  `Delete`+`Enter`, `Ctrl+X` and the grid's own select-all do not clear or replace
  a cell; only the sequence in `buildalpha_symbol_cell.ps1` does (filter, verify
  identity, header-derived cell point, confirm the editor is open, `Ctrl+A`, then
  paste or `Delete`, then read back). Ad-hoc clicking/types here will corrupt a
  row, and this grid commits every keystroke with no Apply/Cancel, so there is no
  undo. Take a snapshot first (the whole table copies out with `Ctrl+A`/`Ctrl+C`
  when it is *unfiltered*; a single-row filtered grid copies only one cell).
- **The built-in symbol selector has no readable *value*.** Selection itself
  works (`@ES`, `@GC`, `@BC`, `@CL` all verified); what cannot be read back is
  the ticker as text: the selector is a `LookUpEdit` with no `ValuePattern` (its
  editor text is the type name
  `System.Collections.Generic.List'1[System.Object]`) and the audited `Symbols`
  line stays empty on that tab. `prepare` therefore confirms via the selector's
  `(N)` count button and reports the picked row's timeframe as `row_timeframe`,
  rather than echo the ticker. If you need the ticker in text, add the strategy
  to a portfolio and read it from the grid.
- **BuildAlpha must be in the foreground for clicks, keys and OCR.** A minimised
  window accepts neither synthetic clicks nor key presses, and an occluded one
  returns the occluding window's pixels when the selector or dialog is read by
  screenshot. The scripts restore the window (`ShowWindow(SW_RESTORE)`), raise
  it with `AttachThreadInput`, and report `RESTORE_FAILED` / `WRONG_WINDOW`
  instead of pretending the capture worked. The grid's automation peer is also
  absent while the window is behind another app; if the portfolio panel shows
  `Preparing results...`, wait - the grid does not exist until it renders.
- **A self-finishing continuous run has no end timestamp.** BuildAlpha logs a
  `StrategiesViewModel.Destroy` line only when a run is stopped with
  STOP -> Yes; a run that completes (or is closed some other way) logs nothing.
  `job.ended` is therefore exact for stopped runs, otherwise inferred from
  capture history (`ended_source = observed|before|single`) - accuracy is the
  capture interval, and a run that ended before the first capture can only be
  bounded (`completed before HH:MM`).
- **Grid rows and form rows do not share a tag.** The portfolio grid exposes no
  date window, costs, sizing or fitness function, so a grid row is keyed on
  `symbol|type|entry_rules|exit_params` only; capturing the same strategy through
  its `Re-Run` form adds those fields and yields a different tag. Use grid rows
  as the portfolio inventory and form captures for run-level detail; do not
  expect the two to merge automatically. For the 52 custom-named rows the grid
  also hides the entry rules (only the label is visible).

- **A results window can stop exposing its grid to UI Automation.** The window
  keeps painting its rows, but the tree shrinks to ~48 elements (title bar,
  toolbar buttons, a status text) with **no `DataGrid`, no `FilteringPanel` and
  no `Row n of N` cells**; the MSAA fallback reports only 2 children. Observed
  after heavy post-test filtering on a large result set. Effects:
  `current_test_filter` / `apply_test_filter` report the count as unknown
  (`-1` / `null`) and `-Action show` returns `UNREADABLE`. Applying a filter
  still works, because that path only needs the toolbar and the dialog.
  Recovery: start a fresh run or restart BuildAlpha; the new window publishes
  its grid again and counts return. Two workarounds were tried and rejected:
  OCR of the window bitmap (miscounts rows) and Export to CSV (exact, but opens
  a Save As dialog and writes files on the production desktop).
- **Results-window buttons are driven by `SetFocus` + Space.** A synthetic click
  lands on whatever window is on top, and a background window (an editor, the
  terminal) will swallow it - test-filter opens in ~0.9 s that way, while clicks
  appeared to do nothing. The scripts also raise the target window with
  `SetWindowPos(HWND_TOPMOST)` before interacting.

## Troubleshooting

- BuildAlpha shows no grid, or the search field stays empty: the grid's
  automation peer can be briefly disconnected and the app must be reachable to
  its servers (it exits on startup if its licence/update check fails). The
  script auto-dismisses the "Indexes" modal and polls for the grid. If a find
  run leaves duplicated text in the search box, close the search panel (Ctrl+F)
  and rerun.
- Re-run appears to change nothing: you are reading the original grid. The
  re-run result lives in a new window; re-run and diff the window handles
  before touching the keyboard (Escape closes the new window).
- Seasonality plot looks blank to UI Automation: expected. The chart is
  custom-drawn; capture the window to a PNG and read the image instead.
- Grid cells report `TextEditRow ...` names: the grid is in in-cell edit mode.
  Press Escape a few times before reading.
- A strategy's name changes after a re-run: the row may show its rule
  expression instead of the custom name. Target it with `-RowY` and confirm it
  is the same strategy via `Symbol` and `Exit Params`.
- Form reader returns few fields: the tab content may not have finished
  loading. Re-run it; for a single tab use `-CurrentTabOnly`. If the window's
  title differs, run `-Title '<exact title>'` (the error lists open windows).
- The portfolio grid shows rows but exposes no cells to UI Automation (after a
  wizard is closed or a portfolio is switched, the grid peer can stay detached):
  read the rows from a screenshot and still open each row's `Re-Run` window -
  the form windows expose their fields normally.
