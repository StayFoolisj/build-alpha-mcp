# Captures

Two kinds of file live here.

## 1. Fixtures, tracked in git

| File | Kind |
| --- | --- |
| `kraken-SOLUSD-15m-Long.txt` | form-reader record, 110 lines |
| `grid-SOLUSD-15m-Long.txt` | grid row, 36 lines |
| `kraken-XXBTZUSD-1h-Long.txt` | form-reader record |
| `grid-XXBTZUSD-1h-Long.txt` | grid row |

These four files are **synthetic**. I invent the values, the rule text, and the exit parameters. They keep the exact shape that `strategy_cache/parse.py` reads, so the test suite runs without a Build Alpha install and without real strategy data.

`strategy_cache/tests_pipeline.py` names them at the top of the file. If you replace them, keep the names and the shape.

## 2. Live captures, ignored by git

A run of `scripts/buildalpha_grid_rows.ps1` or `scripts/buildalpha_form_reader.ps1` writes here. These files hold your own strategy names, rule expressions, and results. The `.gitignore` keeps every capture out of the repository except the four fixtures.

## Formats

**Form record.** A header, then `== TAB: <name> ==` sections, then `Label<TAB>Value<TAB>[ControlType]` lines. One `== RULES ==` section holds `RULE<TAB>Entry=On Required=Off Exit=Off<TAB>expression` lines. `strategy_cache/parse.py` reads it with `read_form()`.

```text
# BuildAlpha form record
# window   : Re-Run
# captured : 2026-01-15T09:30:00.0000000+00:00

== TAB: Main ==
Profit Target	On	[CheckBox]
Profit Target Base	2	[SpinEdit]
Symbols	SOLUSD (15 minutes)	[Symbols]
```

**Grid row.** One `# row=... symbol=... type=...` header, then `Column<TAB>Value` lines.

```text
# row=8809 symbol=SOLUSD_15m type=Long
Sharpe	2.01
Trades	258
Name	close[0] > sma(close,20)[0], rsi(14)[0] < 30
```

## Regenerating a fixture

Read a live capture, then replace every field that carries strategy content: `Name`, `Exit Params`, and the metric columns. Keep the header, the `Symbol`, the `Type`, and the line order. Run `uv run python -m strategy_cache.tests_pipeline` afterwards.
