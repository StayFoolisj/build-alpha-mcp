<#
.SYNOPSIS
  Find one strategy in the portfolio grid, prove it, and select it.

.DESCRIPTION
  The only strategy search in this project. Every consumer that needs "the row for this
  strategy" calls this and then acts on the selection.

  Input is a plan written by strategy_cache.identify.plan(): the portfolio, the symbol, the
  numbers the row must carry, and an ordered list of ways to reach it (Net P&L first, because a
  single number filters 427 rows down to ~1; name and symbol follow as fallbacks).

  What it does, in order:

    0. Take the UI lock and bring Build Alpha to the front (Start-BuildAlphaUi): OK, or UI_BUSY /
       NOT_RUNNING / INPUT_BLOCKED, each refused before anything is clicked.
    1. Read the grid (hit-testing when DevExpress leaves it out of the automation tree), then decide
       how the rows can be read at all: one GetItem decides. If it answers, values come from
       GridPattern (~3 ms per cell). If it returns nothing - an app instance can render perfectly and
       still publish no cells - the filtered rows are copied from the application itself (Ctrl+A,
       Ctrl+C) with their own headers, verified the same way, and the matched row is selected with
       Home/Down. The reply then says read_mode "clipboard" / selection_how "keyboard".
       The Symbol column must be materialised: if it is not, the search stops with
       SYMBOL_COLUMN_HIDDEN rather than falling back to a guessed column index (measured: index 1 was
       the Type column, so every row was rejected as a symbol mismatch).
    2. Confirm the portfolio, switching only when the loaded one differs (the switch is ~8 s and
       moves the operator's screen, so it is not done blind). Skipped with -SkipPortfolio.
    3. For each candidate: apply the filter, wait for the row count to settle, read the visible
       rows, and compare the row's own cells with the expected numbers
       (tolerances: 0.5 trades, 0.02 Sharpe, 0.5 Net P&L; a column scrolled out of view is
       unknown and skipped, never a mismatch).
    4. Ambiguity: several rows that *differ* -> refuse and list them. Several rows that are
       identical in every readable column (the same strategy saved twice, differing only in the
       tag) -> take one and report the others in `duplicates`. The app cannot tell them apart
       either, so refusing would make them permanently unreachable.
    5. Left-click the matched row's Symbol cell, then prove the selection: exactly one cell
       reports IsSelected, and its label carries the expected symbol and row number. The rect of
       that cell is returned, so a consumer can right-click the selected row without passing
       coordinates around.

  The filter is deliberately left applied and the row selected: a consumer's "open the row menu,
  choose item X" step then works on exactly the row that was verified.

  One line of JSON on stdout (`FIND {...}`); progress goes to stderr as `STAGE {...}` so a call
  that hangs says which step it reached.

.PARAMETER PlanFile
  JSON from strategy_cache.identify.plan().

.PARAMETER TimeoutSec
  Budget for the whole search (default 90).

.PARAMETER SkipPortfolio
  Do not read or change the portfolio (the caller has already arranged it).

.PARAMETER NoClick
  Verify and stop: report the row and its rect without clicking it.

.EXAMPLE
  powershell -NoProfile -File .\scripts\buildalpha_find_strategy.ps1 -PlanFile .\plan.json
#>
param(
  [Parameter(Mandatory = $true)][string]$PlanFile,
  [int]$TimeoutSec = 90,
  [switch]$SkipPortfolio,
  [switch]$NoClick,
  # accepted for compatibility with existing callers; clicking is the default behaviour
  [switch]$ClickRow
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\buildalpha_uia.ps1"

# One GUI driver at a time (see Enter-UiLock): a second call must not interleave its clicks and
# filters with this one. A child of a lock holder inherits the flag and skips this.
$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }

# Send-Keys types into the app through System.Windows.Forms.SendKeys; the assembly is not
# loaded by default and the failure surfaces as "Unable to find type" at the first keystroke.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---- progress trace (stderr: stdout is the reply) -------------------------------------------
$script:stageName = $null
$script:stageAt = 0
$script:stages = New-Object System.Collections.ArrayList
function Stage([string]$name) {
  $now = $sw.ElapsedMilliseconds
  if ($script:stageName) {
    [void]$script:stages.Add([pscustomobject]@{ stage = $script:stageName; ms = [int]($now - $script:stageAt) })
  }
  $script:stageName = $name
  $script:stageAt = $now
  [Console]::Error.WriteLine('STAGE ' + (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
    stage = $name; total_ms = [int]$now })))
  [Console]::Error.Flush()
}

$plain = [ordered]@{
  ok                     = $false
  status                 = 'SCRIPT_FAILED'
  detail                 = ''
  tag                    = ''
  portfolio              = ''
  portfolio_read         = ''
  portfolio_switched     = $false
  portfolio_switch_error = ''
  filter                 = ''
  filtered_rows          = -1
  grid_rows              = -1
  row_index              = -1
  row_number             = -1
  row_name               = ''
  row_symbol             = ''
  row_rect               = $null
  hscroll                = $null
  row_clicked            = $false
  row_click_x            = $null
  row_click_y            = $null
  row_y                  = $null
  selected_text          = ''
  selection_how          = ''
  read_mode              = ''
  matched_by             = ''
  attempts               = @()
  duplicates             = @()
  sample_names           = @()
  duration_ms            = 0
  stages                 = @()
}

function Finish([string]$status, [string]$detail = '') {
  $now = $sw.ElapsedMilliseconds
  if ($script:stageName) {
    [void]$script:stages.Add([pscustomobject]@{ stage = $script:stageName; ms = [int]($now - $script:stageAt) })
  }
  $plain.status = $status
  if ($detail) { $plain.detail = $detail }
  $plain.ok = ($status -eq 'OK')
  $plain.duration_ms = [int]$now
  $plain.stages = @($script:stages)
  Write-Output ('FIND ' + ($plain | ConvertTo-Json -Compress -Depth 6))
  # Journal the verdict. Without this the only record of a search is the capture's summary, so a
  # standalone run left no evidence at all. Capped: rotate once past 8 MB.
  try {
    $logPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\find_strategy.log'
    $dir = Split-Path $logPath -Parent
    if (Test-Path $dir) {
      if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 8MB) {
        Move-Item $logPath "$logPath.1" -Force
      }
      $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      Add-Content -LiteralPath $logPath -Encoding utf8 -Value (
        $stamp + ' FIND ' + ($plain | ConvertTo-Json -Compress -Depth 6))
    }
  } catch { }
  switch ($status) {
    'OK' { exit 0 }
    'ROW_NOT_FOUND' { exit 10 }
    'AMBIGUOUS' { exit 11 }
    'SELECTION_FAILED' { exit 12 }
    'GRID_NOT_VISIBLE' { exit 30 }
    'PORTFOLIO_SWITCH_FAILED' { exit 5 }
    'INPUT_BLOCKED' { exit 25 }
    'TIMEOUT' { exit 28 }
    default { exit 1 }
  }
}

if (-not (Test-Path $PlanFile)) { Finish 'SCRIPT_FAILED' "plan file not found: $PlanFile" }
try { $plan = Get-Content $PlanFile -Raw | ConvertFrom-Json }
catch { Finish 'SCRIPT_FAILED' "plan file is not valid JSON: $_" }
$plain.tag = "$($plan.tag)"
$plain.portfolio = "$($plan.portfolio)"
$symbolFull = "$($plan.symbol_full)"
$expectSymbol = "$($plan.symbol)"
$want = @{
  trades  = if ($null -ne $plan.expected.trades) { [double]$plan.expected.trades } else { $null }
  sharpe  = if ($null -ne $plan.expected.sharpe) { [double]$plan.expected.sharpe } else { $null }
  net_pnl = if ($null -ne $plan.expected.net_pnl) { [double]$plan.expected.net_pnl } else { $null }
}
$candidates = @($plan.candidates)
if ($candidates.Count -eq 0) { Finish 'ROW_NOT_FOUND' 'the plan carries no candidates' }

$TOL_TRADES = 0.5
$TOL_SHARPE = 0.02
$TOL_PNL = 0.5

# ---- the grid -------------------------------------------------------------------------------
function Get-Data($item, [string]$id) {
  $e = $item
  for ($i = 0; $i -lt 6 -and $e; $i++) {
    try { if ($e.Current.AutomationId -eq $id) { return $e } } catch { return $null }
    $e = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($e)
  }
  return $null
}

function Get-GridNow([int]$tries = 3) {
  # Measured on this app: a descendant search for 'stratGrid' takes ~1.4 s and does NOT find it
  # (DevExpress rarely publishes the grid into the window's tree), while hit-testing a point
  # inside the grid reaches it in 3-23 ms. So hit-testing is tried FIRST and the tree is the
  # fallback - it was the other way round, which put 1.4 s into every acquisition and made the
  # filter poll cost 12 s.
  for ($i = 0; $i -lt $tries; $i++) {
    $el = $null
    foreach ($pt in @(@(400, 300), @(600, 400), @(300, 250))) {
      try {
        $hit = Get-ElementAt $pt[0] $pt[1]
        if ($hit) { $el = Get-Data $hit 'stratGrid' }
      } catch { }
      if ($el) { break }
    }
    if (-not $el) {
      try {
        $win = Get-MainWindow
        if ($win) {
          $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
              [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
        }
      } catch { }
    }
    if ($el) {
      $gp = $null
      [void]$el.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)
      if ($gp) {
        $rows = $null
        try { $rows = $gp.Current.RowCount } catch { $rows = $null }
        if ($null -ne $rows) { return @{ el = $el; gp = $gp; rows = [int]$rows } }
      }
    }
    Start-Sleep -Milliseconds 200
  }
  return $null
}

function Get-Cell([object]$gp, [int]$r, [int]$c) {
  try { return $gp.GetItem($r, $c) } catch { return $null }
}

# Cells carry their own column label: "Row 6003 of 14, Column Name, Column 6 of 35: value".
function ConvertFrom-CellName([string]$name) {
  if (-not $name) { return $null }
  $m = [regex]::Match($name, '^(?:TextEdit)?Row (\d+) of (\d+), Column (.+?), Column (\d+) of (\d+): (.*)$')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    row = [int]$m.Groups[1].Value; rows = [int]$m.Groups[2].Value
    col = $m.Groups[3].Value.Trim(); value = $m.Groups[6].Value.Trim()
  }
}

#: label -> column index, built once from row 0. A GetItem costs ~3 ms, so the map is ~30 ms and
#: then each row costs 5 reads instead of 18.
$script:colMap = @{}
$NEEDED_COLUMNS = @('Symbol', 'Name', 'Trades', 'Sharpe', 'Net P&L')

function Get-ColumnMap($gp) {
  # Labels are authoritative: GridPattern reports 40 columns while the cells say 35, and the
  # indices differ between layouts, so the index is discovered, never assumed.
  if ($script:colMap.Count -ge $NEEDED_COLUMNS.Count) { return $script:colMap }
  $map = @{}
  for ($c = 0; $c -lt 20; $c++) {
    $cell = Get-Cell $gp 0 $c
    if (-not $cell) { continue }
    $part = ConvertFrom-CellName "$($cell.Current.Name)"
    if (-not $part) { continue }
    if (-not $map.ContainsKey($part.col)) { $map[$part.col] = $c }
    if (@($NEEDED_COLUMNS | Where-Object { -not $map.ContainsKey($_) }).Count -eq 0) { break }
  }
  if ($map.ContainsKey('Symbol')) { $script:colMap = $map }
  return $map
}

function Get-HScroll($grid) {
  $sp = $null
  if (-not $grid.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$sp)) { return -1 }
  try { return [int]$sp.Current.HorizontalScrollPercent } catch { return -1 }
}

function Reset-HScroll($grid, [int]$at) {
  # A grid scrolled right does not materialise the columns to its left, so Symbol / Trades /
  # Sharpe / Net P&L read as absent - which the comparison treats as "unknown", quietly leaving
  # the match resting on whichever columns happen to be on screen. Reset to the left edge before
  # reading, and report the scroll position so a weaker comparison is visible in the reply.
  if ($at -le 0) { return $at }
  Reset-GridHorizontal $grid
  Start-Sleep -Milliseconds 120
  return (Get-HScroll $grid)
}

function Test-UiCellsReadable($gp, $symbolCol) {
  # Cheap check (one GetItem): does this grid provider hand over cell values at all?
  # Measured 2026-11-03: an app instance can render the grid perfectly - the operator sees and
  # clicks the single filtered row - while GetItem returns null for every cell and every tree cell
  # has an infinite rectangle. Nothing in the UIA path can work then, and no amount of waiting
  # fixes it. The app's own clipboard still can.
  $cell = Get-Cell $gp 0 $symbolCol
  if (-not $cell) { return $false }
  $part = ConvertFrom-CellName "$($cell.Current.Name)"
  if (-not $part -or -not $part.value) { return $false }
  return $true
}

function Copy-FilteredRows($gridEl) {
  # Ask the application itself: select the filtered rows and copy them. Returns an array of
  # ordered dictionaries keyed by the grid's own column headers, or $null when the clipboard gave
  # nothing usable. The clipboard is global, so what was there before is restored on the way out.
  $prev = ''
  try { $prev = Get-Clipboard -Raw } catch { }
  $rect = $gridEl.Current.BoundingRectangle
  try {
    Invoke-LeftClick ([int]($rect.Left + 300)) ([int]($rect.Top + 110))
    Start-Sleep -Milliseconds 200
    Send-Keys '^a' 'grid-select-all'
    Send-Keys '^c' 'grid-copy'
    Start-Sleep -Milliseconds 700
    $text = ''
    try { $text = Get-Clipboard -Raw } catch { }
  } finally {
    if ($prev) { try { Set-Clipboard -Value $prev } catch { } }
  }
  if (-not $text) { return $null }
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  if ($lines.Count -lt 2) { return $null }
  $headers = @($lines[0] -split "`t" | ForEach-Object { "$_".Trim() })
  $rows = @()
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    $cols = @($line -split "`t")
    if ($cols.Count -lt 3) { continue }
    $rec = [ordered]@{}
    for ($i = 0; $i -lt $headers.Count -and $i -lt $cols.Count; $i++) { $rec[$headers[$i]] = "$($cols[$i])".Trim() }
    $rows += $rec
  }
  return @{ headers = $headers; rows = $rows }
}

function Get-RowNumber([object]$gp, [int]$r) {
  $cell = Get-Cell $gp $r 0
  if (-not $cell) { return -1 }
  $part = ConvertFrom-CellName "$($cell.Current.Name)"
  if ($part) { return $part.row }
  return -1
}

function Read-RowCells([object]$gp, [int]$r, $map) {
  # Only the columns that can decide the match. Unreadable (scrolled out of view) stays absent,
  # which the comparison treats as unknown rather than as a mismatch.
  $cells = [ordered]@{}
  foreach ($label in $NEEDED_COLUMNS) {
    if (-not $map.ContainsKey($label)) { continue }
    $cell = Get-Cell $gp $r $map[$label]
    if (-not $cell) { continue }
    $part = ConvertFrom-CellName "$($cell.Current.Name)"
    if ($part) { $cells[$label] = $part.value }
  }
  return @{ cells = $cells; row = $r; rowNumber = (Get-RowNumber $gp $r) }
}

function ConvertTo-Numeric($text) {
  # '' or unparseable means the column is not on screen: unknown, never a mismatch
  if ($null -eq $text) { return $null }
  $s = ("$text" -replace '[^0-9\.\-]', '')
  if (-not $s -or $s -eq '-' -or $s -eq '.') { return $null }
  $v = 0.0
  if ([double]::TryParse($s, [ref]$v)) { return $v }
  return $null
}

function Test-RowAgainstExpected($cells) {
  $checked = 0
  $reasons = @()
  $sym = "$($cells['Symbol'])"
  if ($expectSymbol -and $sym -and $sym -notlike "$expectSymbol*") {
    return @{ ok = $false; checked = 0; reason = "symbol $sym != $expectSymbol*" }
  }
  foreach ($spec in @(
      @{ col = 'Trades'; key = 'trades'; tol = $TOL_TRADES },
      @{ col = 'Sharpe'; key = 'sharpe'; tol = $TOL_SHARPE },
      @{ col = 'Net P&L'; key = 'net_pnl'; tol = $TOL_PNL })) {
    $wantValue = $want[$spec.key]
    if ($null -eq $wantValue) { continue }
    $actual = ConvertTo-Numeric $cells[$spec.col]
    if ($null -eq $actual) { continue }          # column not visible: unknown
    $checked++
    if ([Math]::Abs($actual - $wantValue) -gt $spec.tol) {
      $reasons += "$($spec.col) $actual != $wantValue"
    }
  }
  if ($checked -eq 0) {
    return @{ ok = $false; checked = 0; reason = 'no comparable column was readable' }
  }
  if ($reasons.Count) { return @{ ok = $false; checked = $checked; reason = ($reasons -join '; ') } }
  return @{ ok = $true; checked = $checked; reason = '' }
}

# ---- filter ---------------------------------------------------------------------------------
function Get-RowCount($gp) {
  # Reading the count off the pattern we already hold costs ~5 ms; re-acquiring the grid costs
  # 300-500 ms. The poll below used to re-acquire on every tick, which is where 12 s of a 23 s
  # search went. Re-acquire only when the read itself fails (provider re-created).
  try { return [int]$gp.Current.RowCount } catch { return -1 }
}

function Set-FilterText([string]$text, $gp, $gridEl) {
  # The find box is not an Edit we can set (the only one is a disabled infinite-rect artifact),
  # so it is typed. Keystrokes only land on the grid: click inside the grid's own rectangle,
  # never on its header (a header click sorts and reorders the rows under us).
  #
  # Measured: the panel filters *as you type* - by the time Enter is pressed the row count is
  # already the filtered one - so there is nothing to wait for after Enter, and the old
  # "wait for the count to change, then settle" loop (360 ms plus ticks) was waiting for
  # something that had already happened. Also measured: one batched SendWait of
  # "^a{DEL}<text>{ENTER}" takes ~400 ms against ~800 ms in four separate calls, because every
  # Send-Keys call re-checks which window owns the foreground.
  $rect = $gridEl.Current.BoundingRectangle
  $before = Get-RowCount $gp
  Send-Escape 1
  Start-Sleep -Milliseconds 60
  Invoke-LeftClick ([int]($rect.Left + 60)) ([int]($rect.Top + 40))
  Start-Sleep -Milliseconds 120
  Send-Keys '^f' 'find-open'
  Start-Sleep -Milliseconds 150
  # no brace escaping in PowerShell double quotes: "{DEL}" is already literal
  Send-Keys ("^a{DEL}" + $text + "{ENTER}") 'find-apply'
  # The count can still be catching up for a long string; two identical reads 70 ms apart are
  # the cheapest honest check. If it never moves away from the pre-filter value, that is the
  # answer - the filter really did change nothing.
  $last = Get-RowCount $gp
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 70
    $now = Get-RowCount $gp
    if ($now -lt 0) { return -1 }
    if ($now -eq $last) { break }
    $last = $now
  }
  return $last
}

# ---- selection proof ------------------------------------------------------------------------
function Get-SelectedCells($grid) {
  # The portfolio grid has NO SelectionPattern (measured: Scroll, Grid, SynchronizedInput only),
  # so the grid cannot be asked for its selection. SelectionItemPattern on the cells can: a
  # fresh descendant scan returns exactly one cell with IsSelected for a normal selection.
  $cells = @($grid.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column ' })
  $selected = @()
  foreach ($c in $cells) {
    $p = $null
    if ($c.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) {
      try { if ($p.Current.IsSelected) { $selected += $c } } catch { }
    }
  }
  return @{ cells = $cells; selected = $selected }
}

# ---- 1. the grid ----------------------------------------------------------------------------
Stage 'grid'
# The grid is only reachable while BuildAlpha is the foreground window: another app on top makes
# every hit-test land in that app, which is indistinguishable from "the grid is not published".
$proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Finish 'GRID_NOT_VISIBLE' 'BuildAlpha is not running' }
$mainHwnd = @(Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' }) | Select-Object -First 1
if (-not $mainHwnd) { Finish 'GRID_NOT_VISIBLE' 'the Build Alpha main window is not visible' }
[void](Set-AppForeground $mainHwnd)
Start-Sleep -Milliseconds 300
$g = Get-GridNow 5
if (-not $g) {
  $fgHwnd = [System.Windows.Automation.AutomationElement]::FocusedElement
  $fg = if ($fgHwnd) { "window $($fgHwnd.Current.NativeWindowHandle)" } else { 'unknown' }
  Finish 'GRID_NOT_VISIBLE' ("the strategies grid is not reachable; foreground is '$fg'")
}
$plain.grid_rows = $g.rows
$grid = $g.el
$gp = $g.gp

# ---- 2. the portfolio -----------------------------------------------------------------------
if (-not $SkipPortfolio -and $plain.portfolio) {
  Stage 'portfolio'
  # Reading costs ~1.2 s in-process (the dropdown has to be opened: the combo publishes no text).
  # The child-process version of this cost 2.7-8 s for the same answer.
  $ens = Set-PortfolioVerified -Name $plain.portfolio
  $plain.portfolio_read = "$($ens.Read)"
  if (-not $ens.Ok) { $plain.portfolio_switch_error = "$($ens.Reason)" }
  if ($ens.Switched) {
    $plain.portfolio_switched = $true
    $g = Get-GridNow 3
    if ($g) { $grid = $g.el; $gp = $g.gp; $plain.grid_rows = $g.rows }
  }
}

# ---- 3. the attempts ------------------------------------------------------------------------
Stage 'search'
$hit = $null
$plain.hscroll = Reset-HScroll $grid (Get-HScroll $grid)
$map = Get-ColumnMap $gp
$symbolCol = if ($map.ContainsKey('Symbol')) { $map['Symbol'] } else { 1 }
$amb = $null
$samples = @()

foreach ($cand in $candidates) {
  if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
    $plain.attempts += @{ kind = "$($cand.kind)"; search = "$($cand.search)"; matched = $false
                          reason = 'budget exhausted before this attempt' }
    break
  }
  $text = "$($cand.search)"
  $attempt = [ordered]@{ kind = "$($cand.kind)"; search = $text; source = "$($cand.source)"
                         matched = $false; filtered_rows = -1; reason = '' }

  Stage 'filter'
  $n = Set-FilterText $text $gp $grid
  $attempt.filtered_rows = $n
  $plain.filter = $text
  $plain.filtered_rows = $n
  if ($n -lt 0) {
    $attempt.reason = 'the grid could not be reached to filter it'
    $plain.attempts += $attempt
    break
  }
  if ($n -eq 0) {
    $attempt.reason = "the filter '$text' matched no row"
    $plain.attempts += $attempt
    continue
  }

  Stage 'scan'
  $g = Get-GridNow 3
  if (-not $g) { $attempt.reason = 'the grid provider died mid-search'; $plain.attempts += $attempt; break }
  $grid = $g.el; $gp = $g.gp; $plain.filtered_rows = $g.rows
  $plain.hscroll = Reset-HScroll $grid (Get-HScroll $grid)
  $script:colMap = @{}                     # column indices are only valid for this layout
  $map = Get-ColumnMap $gp
  $symbolCol = if ($map.ContainsKey('Symbol')) { $map['Symbol'] } else { 1 }

  # Only the visible rows are materialised (measured: 35 of 443), so a filter that leaves more
  # than a screenful is scanned up to that limit and then reported, never guessed at.
  # UIA first. If the provider answers, nothing changes. If it does not, ask the app itself for the
  # filtered rows via the clipboard - same identity rules, different source.
  if (-not (Test-UiCellsReadable $gp $symbolCol)) {
    $copied = Copy-FilteredRows $grid
    $plain.read_mode = 'clipboard'
    if (-not $copied -or $copied.rows.Count -eq 0) {
      $attempt.reason = 'the grid cells are not readable and copying them returned nothing'
      $plain.attempts += $attempt
      continue
    }
    $best = $null
    $examined = @()
    $idx = -1
    foreach ($rec in $copied.rows) {
      $idx++
      $verdict = Test-RowAgainstExpected $rec
      $examined += ("clipboard row[{0}] symbol='{1}' trades='{2}' sharpe='{3}' net_pnl='{4}' -> {5}" -f
        $idx, $rec['Symbol'], $rec['Trades'], $rec['Sharpe'], $rec['Net P&L'],
        $(if ($verdict.ok) { 'MATCHED' } else { $verdict.reason }))
      if ($verdict.ok -and -not $best) { $best = @{ index = $idx; cells = $rec } }
    }
    $attempt.evidence = @($examined | Select-Object -First 6)
    if (-not $best) {
      $attempt.reason = "copying the filtered rows gave $($copied.rows.Count) row(s), none matching the expected numbers"
      $plain.attempts += $attempt
      continue
    }
    # select it with the keyboard: the row band has no geometry, but the app still responds to keys
    $rect = $grid.Current.BoundingRectangle
    Invoke-LeftClick ([int]($rect.Left + 300)) ([int]($rect.Top + 110))
    Start-Sleep -Milliseconds 150
    Send-Keys '{HOME}' 'grid-first-row'
    for ($k = 0; $k -lt $best.index; $k++) {
      Send-Keys '{DOWN}' 'grid-next-row'
      Start-Sleep -Milliseconds 60
    }
    $plain.row_index = $best.index
    $plain.row_name = "$($best.cells['Name'])"
    $plain.row_symbol = "$($best.cells['Symbol'])"
    $plain.row_cells = $best.cells
    $plain.selection_how = 'keyboard'
    $plain.matched_by = "$($cand.kind)"
    $attempt.matched = $true
    $attempt.reason = 'matched from the clipboard copy (UIA cells unavailable)'
    $plain.attempts += $attempt
    Finish 'OK' ''
  }
  $plain.read_mode = 'uiatree'

  $survivors = @()
  $limit = [Math]::Min($g.rows, 40)
  for ($r = 0; $r -lt $limit; $r++) {
    $symCell = Get-Cell $gp $r $symbolCol
    if (-not $symCell) { continue }
    $symPart = ConvertFrom-CellName "$($symCell.Current.Name)"
    if (-not $symPart) { continue }
    if ($expectSymbol -and $symPart.value -and $symPart.value -notlike "$expectSymbol*") { continue }
    $row = Read-RowCells $gp $r $map
    if (-not $row.cells['Name']) { continue }          # row not rendered yet
    if ($samples.Count -lt 2) { $samples += "$($row.cells['Name'])" }
    $verdict = Test-RowAgainstExpected $row.cells
    if ($verdict.ok) { $survivors += @{ row = $row; cells = $row.cells } }
  }
  $plain.sample_names = @($samples)

  if ($survivors.Count -eq 0) {
    $attempt.reason = "no row among $($g.rows) filtered row(s) carried the expected numbers"
    $plain.attempts += $attempt
    continue
  }
  if ($survivors.Count -eq 1) {
    $attempt.matched = $true
    $attempt.reason = 'single row matched'
    $plain.attempts += $attempt
    $plain.matched_by = "$($cand.kind)"
    $hit = $survivors[0]
    break
  }

  # Several survivors. If they differ in any readable column they are different strategies and
  # picking one would be a guess. If they agree everywhere, the app itself cannot tell them
  # apart (the tag differs; nothing visible does) - take one and say so.
  $first = $survivors[0]
  $differences = @()
  for ($k = 1; $k -lt $survivors.Count; $k++) {
    $other = $survivors[$k]
    $diff = @()
    foreach ($key in $first.cells.Keys) {
      if ("$($first.cells[$key])" -ne "$($other.cells[$key])") { $diff += $key }
    }
    if ($diff.Count) {
      $differences += @{ row_number = $other.row.rowNumber; name = "$($other.cells['Name'])"; fields = $diff }
    }
  }
  if ($differences.Count) {
    $attempt.matched = $false
    $attempt.reason = "$($survivors.Count) rows matched and differ; refusing to guess"
    $plain.attempts += $attempt
    $plain.duplicates = @($differences)
    $amb = "the filter '$text' left $($survivors.Count) rows that all carry the expected numbers but differ in $((($differences | ForEach-Object { $_.fields }) | Select-Object -First 3) -join ', '); refusing to guess"
    break
  }
  $attempt.matched = $true
  $attempt.reason = "$($survivors.Count) identical rows; took the first and reported the rest"
  $plain.attempts += $attempt
  $plain.matched_by = "$($cand.kind)"
  $plain.duplicates = @($survivors | Select-Object -Skip 1 | ForEach-Object {
      @{ row_number = $_.row.rowNumber; name = "$($_.cells['Name'])"; fields = @() } })
  $hit = $first
  break
}

if ($amb) { Finish 'AMBIGUOUS' $amb }
if (-not $hit) { Finish 'ROW_NOT_FOUND' "no candidate matched; the grid holds $($plain.grid_rows) row(s) in '$($plain.portfolio_read)'" }

$plain.row_index = $hit.row.row
$plain.row_number = $hit.row.rowNumber
$plain.row_name = "$($hit.cells['Name'])"
$plain.row_symbol = "$($hit.cells['Symbol'])"

# ---- 4. select it, and prove it -------------------------------------------------------------
if ($NoClick) { Finish 'OK' '' }

Stage 'select'
$symCell = Get-Cell $gp $hit.row.row $symbolCol
if (-not $symCell) { Finish 'SELECTION_FAILED' 'the matched row could not be located for the click' }
$rect = $symCell.Current.BoundingRectangle
if ($rect.IsEmpty -or $rect.Width -le 0) { Finish 'SELECTION_FAILED' 'the matched cell has no usable rectangle' }
$clickX = [int]($rect.X + $rect.Width / 2)
$clickY = [int]($rect.Y + $rect.Height / 2)
Invoke-LeftClick $clickX $clickY
$plain.row_clicked = $true
$plain.row_click_x = $clickX
$plain.row_click_y = $clickY
$plain.row_y = [int]$rect.Y

Stage 'verify'
# Cheapest honest proof first: the very cell we clicked, asked whether it is selected. That is
# one UIA call (~3 ms) instead of a descendant scan of the whole grid (~100 ms, more when the
# filter leaves many rows). The scan is the fallback for a provider that re-created the element.
$selectedCell = $null
$selectionHow = ''
for ($try = 0; $try -lt 8 -and -not $selectedCell; $try++) {
  $si = $null
  try {
    if ($symCell.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$si)) {
      if ($si.Current.IsSelected) { $selectedCell = $symCell; $selectionHow = 'clicked-cell' }
    }
  } catch { }
  if (-not $selectedCell) { Start-Sleep -Milliseconds 60 }
}
if (-not $selectedCell) {
  $gg = Get-GridNow 2
  if ($gg) { $grid = $gg.el; $gp = $gg.gp }
  $sel = Get-SelectedCells $grid
  if ($sel.selected.Count -eq 1) { $selectedCell = $sel.selected[0]; $selectionHow = 'grid-scan' }
}
if (-not $selectedCell) { Finish 'SELECTION_FAILED' 'the grid reports no single selected cell after the click' }
$selectedPart = ConvertFrom-CellName "$($selectedCell.Current.Name)"
$plain.selected_text = "$($selectedCell.Current.Name)"
$plain.selection_how = $selectionHow
if (-not $selectedPart) { Finish 'SELECTION_FAILED' "the selected cell could not be parsed: $($plain.selected_text)" }
if ($selectedPart.row -ne $hit.row.rowNumber) {
  Finish 'SELECTION_FAILED' ("the selected cell belongs to row $($selectedPart.row), not the matched row $($hit.row.rowNumber)")
}
if ($expectSymbol -and $selectedPart.value -and $selectedPart.value -notlike "$expectSymbol*") {
  Finish 'SELECTION_FAILED' "the selected cell reads '$($selectedPart.value)', not '$expectSymbol*'"
}
$selRect = $selectedCell.Current.BoundingRectangle
$plain.row_rect = @{ x = [int]$selRect.X; y = [int]$selRect.Y
                     width = [int]$selRect.Width; height = [int]$selRect.Height }
Finish 'OK' ''
