# Rerun performance — measurements and dead ends

Everything below was measured on this machine with the phase timers in
`scripts/buildalpha_rerun_adjust.ps1` (`PHASE <name> ms=<n>` lines on stdout). Keep
that instrumentation when changing the script: without it these arguments are
guesswork, and two of the "obvious" optimisations turned out to make things slower.

Tag used: `ph37u4ux2f` (`btc-trend-short`), built-in `BTC`, stop `2026-10-22`.

## Where the time goes

| phase | real run | dry run | what it is |
|---|---|---|---|
| portfolio | 3.5 s | 3.5 s | nested `buildalpha_switch_portfolio.ps1 -List` asks which portfolio is selected |
| filter+row | 12.5 s | 12.5 s | `Ctrl+F`, type, Enter, poll, then `GridPattern.GetItem` reads |
| open-rerun | 7.4 s | 7.4 s | nested `buildalpha_rerun.ps1`: right-click, OCR the custom-drawn menu, click it, wait for the dialog |
| picker | 11–12 s | 11–12 s | tab switch 2.3 · selector 0.5 · dropdown 1.0 · find 4.4 · select 2.2 · OK 1.5 |
| dates | 1.6 s | 1.6 s | two date writes + read-back |
| form-read | 8.2 s | — | in-process walk of the Re-Run form (91 fields, all tabs) |
| simulate+read | 5.9 s | — | the actual simulation, plus reading the results row |
| **total** | **~50 s** | **~38 s** | |

The simulation is ~6 s. Everything else is UI automation.

## Costs of the primitives (measured, not estimated)

These numbers explain why most "cheap poll instead of sleep" ideas fail here:

| call | cost | note |
|---|---|---|
| `GridPattern.GetItem(r, c)` | ~0.2 s | the only way to read portfolio-grid cells |
| `FindAll` on the Re-Run dialog or its picker | 1–3 s | thousands of elements (tree list × 4 columns × many rows) |
| `FindFirst` with an `AutomationId` condition, same dialog | ~0.5 s | *not* free: server-side filtering does not help enough |
| `Get-Picker` (popup probe: enum windows + UIA check) | **~2 s** | so polling it is the expensive option |
| `Select-WindowTab` | ~2.3 s | |
| form walk (`Read-FormFields`) | ~8 s | 91 fields across all tabs |
| spawning a second `powershell -NoProfile` | ~0.7 s | plus UIA/OCR re-initialisation |

## Kept

- **Phase timers** — the whole reason this file can exist.
- **In-process form read** (was a nested `buildalpha_form_reader.ps1`): 10.4 → 8.2 s.
  The subprocess remains as a fallback when the in-process pass returns fewer than 3
  fields. The full 91-field read is deliberate: more fields will be mutated later.
- **Identity-first row read**: read `Symbol` + `Name` (columns 1 and 5) to decide
  whether a row matches, then the full row once. Time-neutral but removes ~40 UIA
  calls; column indexes are verified by the returned names, with a fallback scan.
  Note the off-by-one that hid here for a while: `Name` is **column 5**, not 6.
- **Filter row-count poll** instead of a flat 2 s sleep.
- **Picker dropdown/result polls** instead of two flat 2 s sleeps.
- **Close a stale `Re-Run` window** before opening a new one (an aborted run used to
  leave one behind, which was then mistaken for the new dialog and hung the run).
- **Nested-script failures are reported**: run the child with
  `ErrorActionPreference=Continue`, otherwise a `Write-Error` inside it kills the
  parent with exit 1 and no message.
- **`$verified` initialised before the date loop** (it used to be reset afterwards,
  so a failed date read-back could never fail the run).

## Tried and reverted — do not repeat blind

Each of these looked obviously right and measured worse, or lost reliability:

1. **Remember the last portfolio instead of asking** (saves 3.5 s). A stale hint — the
   user switched portfolio by hand, or an earlier aborted run left the selector
   elsewhere — made the grid filter return 0 rows and the run died at `FILTER_EMPTY`.
   Asking is slow but cannot be wrong.
2. **Skip the tab switch when the selector already exists** (2.3 s → 0.15 s). The same
   `AutomationId` exists on hidden tabs, so the "already there" check passed while the
   wrong tab was active; the picker then often failed to open, and the popup probe
   *blocked* inside a cross-process UIA call instead of timing out.
3. **Poll for the picker window to close** instead of the flat 1.5 s sleep after OK.
   The probe costs ~2 s, so the poll cost **10.6 s** where the sleep cost 1.5 s.
4. **One `FindAll` snapshot of the portfolio grid to replace the per-cell `GetItem`
   reads.** The grid's cells are *not* in the control-view tree — the snapshot returned
   zero rows. Only `GridPattern.GetItem` materialises them.
5. **Targeted `FindFirst` polls inside the picker** (replacing the cell walks with a
   selector-count check): the picker went 10.8 → 22 s, because `FindFirst` on that
   DevExpress dialog costs about as much as `FindAll`.

## Trade capture (include_trades)

Measured with `TRADES_PHASE` marks inside `Get-TradeTable` (buildalpha_uia.ps1).

| stage | before | after | what changed |
|---|---|---|---|
| activate-source | 842 | ~40–400 | skipped entirely when the window is already in front |
| menu-popup | 1293 | ~460 | poll the popup every 80 ms instead of 200 ms |
| menu-ocr | 120 | ~100 | unchanged (screenshot + Windows OCR) |
| menu-click | 229 | ~210 | — |
| trades-window | 315 | ~330 | 150 ms poll |
| trades-grid | 10 | ~10 | — |
| activate-trades | 878 | 0 | skipped: the window is already foreground |
| grid-focus | 1237 | ~340 | 120 ms instead of a fixed 500 ms |
| clipboard | 1352 | ~360 | 100 ms polls, 120 ms between Ctrl+A and Ctrl+C |
| close-window | 365 | ~360 | unchanged |
| **second PowerShell** | ~2000 | **0** | the extractor is a function called in-process |
| **total, standalone** | 7.6 s | **2.6 s** | wall clock including PowerShell start |
| **total, inside a run** | 14.2 s | **3.8 s** | `PHASE trades` |

The three structural lessons: a nested `powershell` costs ~2 s before it does anything; every
`Start-Sleep` around a UI event can usually become a poll of the state you were waiting for;
and re-activating an already-foreground window costs ~850 ms for nothing.


The remaining seconds are latency per *interaction*, not sleeps, so the only moves
left are structural:

- fewer interactions with the dialog (e.g. drive the symbol selector without the
  picker at all — keyboard/native input, not more UIA);
- one process instead of four nested `powershell` invocations (~0.7 s each plus
  re-initialisation), which also simplifies the run log;
- caching the OCR'd context-menu offset (once per session), since the menu is always
  in the same place.

Anything else should be measured with the phase timers and committed only if it wins.

## If you want to make it faster

## The alternative to all of it

Latency is no longer on the caller's critical path: `rerun_with_adjustments` hands a
run off after `max_wait_sec` (default 45) with `{"status": "RUNNING", "run_id": ...}`,
and `get_last_result(tag)` fetches the outcome afterwards. Speed now only affects
throughput, not correctness.

## Capture path (2026-11-01)

| stage | measured |
|---|---|
| `search` (portfolio read + Net P&L filter + scan + proven selection) | 3.3-4.8 s |
| `re-run` (right-click + menu OCR + activate) | 4.5 s |
| `wait-results-window` | 5.8 s |
| `select-results-row` (click + prove) | 0.9 s |
| `open-view` (nav button + window + redraw detection) | 3.9-4.3 s |
| `settle` (two frames) | 2.5-2.7 s |
| `capture` + `save` | 1.2 s |
| **whole capture** | **29.5-33.5 s** |

The same capture took **80-86 s** before this work: the search was 49.4 s of it (a symbol filter
that left 14 rows to scan), the portfolio step was 8.5 s (a child PowerShell), and `verify` was
1.5 s (a descendant scan of the whole grid). The search is now 3.3 s, the portfolio read is ~1.2 s
in-process, and the selection is proven by asking the clicked cell (3 ms).

Where the remaining time goes, in order: `wait-results-window` (polls at 500 ms for a window that
appears in ~4 s), `re-run` (the context menu is custom-drawn, so its items are found by OCR),
`open-view`, and `settle`. Each is a candidate for the same treatment the search got: measure the
primitive, then remove round-trips and sleeps.

Consequences already recorded in code: the capture tools default to `timeout_sec=150` (the old 30 s
default produced TIMEOUT before the view opened), the view window is sized to 1000x750 before the
capture (~600 KB PNG instead of ~1.1 MB, text still at native pixels), and one GUI-driving call at
a time is enforced by `Enter-UiLock` (a second capture returns `BUSY` in ~0.5 s).

## Checks that cost something (2026-11-03)

| check | cost | why it exists |
|---|---|---|
| UI lock (`Enter-UiLock`) | <1 ms | one driver at a time; a second call gets `BUSY` in ~0.5 s |
| `Start-BuildAlphaUi` (lock, is-it-running, bring to front) | 0.3-0.5 s | the alternative was typing into whatever window was in front |
| portfolio read (`Set-PortfolioVerified`) | ~1.2 s | one dropdown open; switching only when the loaded one differs |
| reading the row from UIA vs clipboard | ~15 ms vs ~1 s | the clipboard path only runs when `GetItem` answers nothing |
| grid copy for a scan (433 rows) | 3-5 s, retried if short | one `Ctrl+A`/`Ctrl+C` for the whole grid |

The grid copy is the one flaky measurement: 433 rows on one attempt, 355 and 367 of 433 on the next
two, in the same session. It is retried until the row count matches `GridPattern.RowCount`, because a
short copy looks exactly like "these strategies were deleted".
