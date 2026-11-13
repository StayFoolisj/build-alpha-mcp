# Run log

`logs/mcp.log` — append-only JSONL, one JSON object per line, one line per event.
Written by `strategy_cache/runlog.py`; rotated at midnight or at `--log-max-mb`, keeping
`--log-retain` files. This file is the contract: if a field is not described here, nothing should
depend on it.

## Rules

- **One line = one fact.** Nothing is nested deeper than one level, so `jq`/`Select-String` work
  without knowing the payload.
- **stdout is never a log.** It carries the tool reply (and is the protocol for stdio transport).
  Diagnostics go to stderr; the durable record goes to this file.
- **Every field is bounded.** Strings at `FIELD_CAP` (4 KB), lists at `ARRAY_CAP` (8), objects at
  `KEY_CAP` (16 KB). A value that is still too big becomes a digest (`compacted: true`, `bytes`,
  `keys`), never a truncated JSON string. Truncation always adds `<field>_truncated: true` and
  where useful `<field>_bytes` / `<field>_count`.
- **The log holds a digest, not the payload.** The tool's reply is the payload; `run_id` ties the
  two together. Capture replies additionally carry `caps`-bounded `stages`.
- **Credentials are replaced** with `***` for any key matching password / secret / token /
  authorization / cookie / credential / clipboard.
- **Logging never fails the tool.** Writer errors are swallowed.
- **Levels.** `info` (default): call start, call end, failures. `debug`: also one line per capture
  stage. `warn`: every non-success finish line. Set with `--log-level` or `BA_LOG_LEVEL`.

## Events

### `log_open`
Emitted by `configure()`.

| field | meaning |
|---|---|
| `path`, `backup_count`, `max_bytes` | where and how the log rotates |

### `tool_call_start`
| field | meaning |
|---|---|
| `ts` | UTC, ISO-8601 seconds |
| `lvl` | `info` |
| `run_id` | 12 hex chars, unique per call, on every line of that call |
| `tool` | MCP tool name |
| `tag` | strategy tag when the tool takes one |
| `args` | the call's arguments, scrubbed and bounded |

A `tool_call_start` with no matching `tool_call_finish` is a call that is still running or was
killed hard. That is the one thing a log can prove about a crash.

### `stage`
`debug` only. One line per capture step: `portfolio`, `search`, `re-run`,
`wait-results-window`, `select-results-row`, `open-view`, `settle`, `capture`, `save`.

| field | meaning |
|---|---|
| `run_id`, `tool` | as above |
| `stage` | step name |
| `ms` | integer duration of that step |

Sort by `ts` within a `run_id` for the timeline. A missing next stage is where the call was when it
was killed.

### `tool_call_finish`
| field | meaning |
|---|---|
| `status` | the tool's own status (`OK`, `TIMEOUT`, `IDENTITY_MISMATCH`, `BUSY`, `SYMBOLS_MISSING`, …) |
| `ok` | false for anything but `OK` / `COMPLETED` / `DRY_RUN` / `SIZE_CAP` |
| `lvl` | `info` on success, `warn` on failure |
| `duration_ms` | integer milliseconds for the whole call |
| `last_stage` | capture only: the step the call reached (also the step it died in) |
| `result` | the reply payload, bounded; read-only successes are compacted |
| `stdout`, `stderr` | diagnostics, tail-capped at `KEY_CAP` |
| `error` | exception text when the tool raised |

`result.decision` (capture tools) records the identity inputs — `filter`, `matched_by`,
`candidates`, `attempts`, `expect_name`, `expect_symbol`, `expected`, `tolerances` — so an
`IDENTITY_MISMATCH` is explainable from the log alone.

`result.env` (capture failures) records the machine state at failure: `desktop_locked`,
`foreground_title`, `foreground_pid`, `buildalpha_pid`, `windows`, `window_count`. A locked or
disconnected session shows here; without it a UIA `Access is denied` looks like a code fault.

## The search log (`logs/find_strategy.log`)

A second, much smaller log, written by `scripts/buildalpha_find_strategy.ps1` itself rather than by
`runlog.py`. One line per search:

```
2026-11-01T05:19:25.703Z FIND {"ok":true,"status":"OK","tag":"zkdkiddhg3","matched_by":"metrics",...}
```

Same JSON object the script prints on stdout (`FIND {...}`), prefixed with a UTC timestamp.
Rotates once past 8 MB (`find_strategy.log.1`). It is gitignored with the rest of `logs/`.

Why it exists: a search run on its own left no record anywhere else - the MCP run log only knows
about tool calls, and a capture records the search only as one `search` stage plus the fields
`capture_view` copies into its reply. With this file, "which filter did it try, what did it
reject, why did it refuse" survives the session for standalone runs too.

`read_mode` says which way the row was read: `uiatree` (GridPattern values) or `clipboard`
(the application's own copy, used when the grid publishes no cells).

The fields worth reading: `status`, `matched_by` (`metrics` / `name` / `symbol`), `filter`,
`filtered_rows`, `row_number`, `row_symbol`, `duplicates`, `hscroll`, and `attempts` (one entry
per candidate with its reason). A refusal is as useful as a success here: `AMBIGUOUS` names the
rows and the differing fields, `ROW_NOT_FOUND` carries the attempt reasons.

```powershell
# what has been refused lately, and why
Select-String -Path .\logs\find_strategy.log -Pattern '"status":"(AMBIGUOUS|ROW_NOT_FOUND)"'
```

## Reading it

```powershell
# everything that failed today, with the stage
Select-String -Path .\logs\mcp.log -Pattern '"ok": false'
# one call, in order
Select-String -Path .\logs\mcp.log -Pattern '"run_id": "f0d6e1bd50f8"'
# where captures lose their time (needs --log-level debug)
Select-String -Path .\logs\mcp.log -Pattern '"event": "stage"' |
  ForEach-Object { $_.Line | ConvertFrom-Json } | Group-Object stage |
  Select-Object Name, @{n='avg_ms';e={[int](($_.Group.ms | Measure-Object -Average).Average)}}
```

The MCP tools `recent_runs` and `get_last_result` read the same file, so a call whose client timed
out can still be recovered by `run_id`.

## Retention

Rotation is size and date based; nothing else prunes. Current setting: 32 MB per file, 14 files
(~450 MB ceiling). Intent: keep ~2 weeks of history, which at this call rate is far below the cap.
