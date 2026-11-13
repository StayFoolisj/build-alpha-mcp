# NOTE (2026-10-31): the row SEARCH is shared - strategy_cache/identify.py decides the order and
# scripts/buildalpha_find_strategy.ps1 executes it. Do not add filter logic here. See README,
# 'Finding a strategy row'.
<#
.SYNOPSIS
  Capture one analysis view for one strategy, as a PNG.

.DESCRIPTION
  Views ignore the portfolio selection, so never open one from the portfolio window.

  1. Identify the strategy: tag or run_id -> plan (identify.plan): the row, its symbol, its numbers.
  2. Find that row in the portfolio grid: filter by symbol, match Trades / Sharpe / Net P&L.
  3. Re-run it: scripts/buildalpha_rerun.ps1 with no -Target (plain "Re-run strategy", not "with
     adjustments"). It right-clicks the identified row, runs with the cached inputs and the stop
     date moved to today, and opens a results window.
  4. Select the row inside that results window - its view buttons do nothing until it is selected.
  5. Open the requested view from that results window's icon panel: invoke its
     HamburgerMenuNavigationButton ('Variance Testing' / 'Monte Carlo Analysis' / ...).
  6. Accept only a window that appeared after the action and whose title carries the requested
     view's prefix. The strategy identity comes from the verified row, not from the title text:
     BuildAlpha reorders the rules in the title, so comparing that text fails for no good reason.
  7. Two stable frames, capture the client area, downscale to -MaxWidth, save.
  8. Close the view and the results window.

  If the re-run or its results window does not appear: fail (RERUN_WINDOW_MISSING). There is no
  fallback that opens a view from the portfolio window.

.PARAMETER Tag
  Cached tag, recorded in the reply.

.PARAMETER ExpectName
  Exact grid Name of the row. Empty means "use whatever row is filtered in".

.PARAMETER ExpectSymbol
  Symbol the row must show, e.g. HYPE-USDT (the timeframe suffix is ignored).

.PARAMETER ExpectedTrades / ExpectedSharpe / ExpectedPnl
  Cached metrics used to recognise the row in the grid. -1 disables that comparison.

.PARAMETER View
  Which view to open. See $viewSpecs for the accepted names.

.PARAMETER Button
  Optional button to press once the view is open (e.g. Resample). Empty by default.

.PARAMETER Out
  PNG path.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_capture_view.ps1 `
      -Tag u3z4vkztlz -View 'MC Analysis' -Button Resample -Suffix '-mc.png'
#>
param(
  [string]$Tag = '',
  [string]$RunId = '',
  [string]$Portfolio = '',
  [Alias('View')]
  [string]$ViewName = 'Variance Testing',  # view to open: see $viewSpecs
  [string]$PlanFile = '',                # identify.plan() JSON: use the shared row search
  [string]$Button = '',                  # button to click once open ('' = none)
  [string]$Suffix = '-variance.png',     # suffix for the default file name
  [string]$ExpectName = '',
  [string]$ExpectSymbol = '',
  [double]$ExpectedTrades = -1,
  [double]$ExpectedSharpe = -1,
  [double]$ExpectedPnl = -1,
  [string]$Out = '',
  [string]$OcrDump = '',            # diagnostic: write the raw OCR lines here
  [int]$TimeoutSec = 30,
  [int]$MaxWidth = 1568
)

$ErrorActionPreference = 'Stop'

# Send-Keys needs the WinForms assembly loaded explicitly; without it the type is missing
# and the grid filter silently does nothing (a documented trap in this repo).
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
. "$PSScriptRoot\buildalpha_uia.ps1"

# One GUI driver at a time (see Enter-UiLock): a second call must not interleave its clicks and
# filters with this one. A child of a lock holder inherits the flag and skips this.
$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }


# --- view spec ------------------------------------------------------------
# One table for every analysis view: the nav button's UIA name, the window-title prefix,
# and the accelerator to try if the button cannot be invoked. A new view is three values
# here, not a new script.
$viewSpecs = [ordered]@{
  'variance testing'     = @{ Nav = 'Variance Testing';     Title = '^Variance Testing'; Key = 'v';      Suffix = '-variance.png' }
  'mc analysis'          = @{ Nav = 'Monte Carlo Analysis';  Title = '^MC Analysis';      Key = $null;    Suffix = '-mc.png' }
  'mc'                   = @{ Nav = 'Monte Carlo Analysis';  Title = '^MC Analysis';      Key = $null;    Suffix = '-mc.png' }
  'monte carlo analysis' = @{ Nav = 'Monte Carlo Analysis';  Title = '^MC Analysis';      Key = $null;    Suffix = '-mc.png' }
  # This window's title is 'Monte Carlo Drawdown - Cumulative results' and carries no row name,
  # so its identity rests on 'appeared after the action' plus the filtered single-row grid.
  'monte carlo draw down' = @{ Nav = 'Monte Carlo Draw Down'; Title = '^Monte Carlo Draw[d]?own'; Key = $null; Suffix = '-mcdd.png' }
  'monte carlo drawdown'  = @{ Nav = 'Monte Carlo Draw Down'; Title = '^Monte Carlo Draw[d]?own'; Key = $null; Suffix = '-mcdd.png' }
  'mc dd'                 = @{ Nav = 'Monte Carlo Draw Down'; Title = '^Monte Carlo Draw[d]?own'; Key = $null; Suffix = '-mcdd.png' }
  'mcdd'                  = @{ Nav = 'Monte Carlo Draw Down'; Title = '^Monte Carlo Draw[d]?own'; Key = $null; Suffix = '-mcdd.png' }
  'dd'                    = @{ Nav = 'Monte Carlo Draw Down'; Title = '^Monte Carlo Draw[d]?own'; Key = $null; Suffix = '-mcdd.png' }
  # The Metrics button sits in the same panel but its AutomationId is plain 'metrics', so the
  # usual 'HamburgerMenuNavigationButton' filter misses it. Its window is a 5 x 4 grid of plots
  # with E-Ratio in the top-left cell.
  'metrics'               = @{ Nav = 'Metrics'; Title = '^Metrics'; Key = $null; Suffix = '-eratio.png'; NavId = 'metrics'; Crop = 'cell' }
  'm'                     = @{ Nav = 'Metrics'; Title = '^Metrics'; Key = $null; Suffix = '-eratio.png'; NavId = 'metrics'; Crop = 'cell' }
  'e-ratio'               = @{ Nav = 'Metrics'; Title = '^Metrics'; Key = $null; Suffix = '-eratio.png'; NavId = 'metrics'; Crop = 'cell' }
  'eratio'                = @{ Nav = 'Metrics'; Title = '^Metrics'; Key = $null; Suffix = '-eratio.png'; NavId = 'metrics'; Crop = 'cell' }
}
$specKey = "$ViewName".Trim().ToLowerInvariant()
if (-not $viewSpecs.Contains($specKey)) {
  [Console]::Error.WriteLine('VIEW_NOT_FOUND unknown view ' + $ViewName)
  exit 31
}
$spec = $viewSpecs[$specKey]
$navName = $spec.Nav
$titleRegex = $spec.Title
# The view table owns the file suffix, so a new view adds one row here and nothing else.
if (-not $PSBoundParameters.ContainsKey('Suffix')) { $Suffix = $spec.Suffix }
# Any of these views left open steals the foreground and hides the menu button, so cleanup
# is by the union of every known view title, not just the one being captured now.
$anyViewRegex = '^(' + ((@($viewSpecs.Values | ForEach-Object { $_.Title.TrimStart("^") }) | Sort-Object -Unique) -join '|') + ')'
# --- output path ----------------------------------------------------------
if (-not $Out) {
  $stemSource = if ($Tag) { $Tag } elseif ($RunId) { $RunId } else { 'target' }
  $stem = ($stemSource -replace '[^A-Za-z0-9._-]', '')
  $Out = Join-Path (Split-Path $PSScriptRoot -Parent) ("captures\screens\$stem$Suffix")
}

# --- OCR switch -----------------------------------------------------------
# The stats-panel OCR is disabled. It was called trivial and it was not: white-on-black
# small text needed two upscale passes, a per-view key set and a positional fallback, and
# it still produced wrong numbers often enough to be a liability. The code below is left in
# place, behind this single switch, and nothing calls it while the switch is off. With it off
# there is no 'summary' and no 'summary_status' in the reply at all - a field that is always
# absent is noise, and an always-null field with a status is worse.
$script:EnableOcrSummary = $false

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
  status = 'CAPTURE_FAILED'
  tag = $Tag
  run_id = $RunId
  portfolio = $Portfolio
  loaded_portfolio = ''
  portfolio_switched = $false
  portfolio_switch_error = ''
  filter = ''
  grid_rows = 0
  filtered_rows = 0
  nav_buttons = 0
  nav_name = ''
  nav_id = ''
  nav_window = ''
  nav_candidates = @()
  descendants = 0
  sample_names = @()
  row = ''
  view = $ViewName
  plan_matched_by = $null
  rerun_opened = $false
  rerun_reused = $false
  reuse_row = ''
  rerun_closed = $false
  results_row_selected = $false
  selection_how = ''
  selection_evidence = ''
  results_row = ''
  results_row_click = ''
  view_opened_by = $null
  button_clicked = ''
  button_redraw = $null
  symbol = ''
  path = ''
  bytes = 0
  sha256 = ''
  width = 0
  height = 0
  format = 'png'
  downscaled_from = 0
  title = ''
  accelerator_used = $null
  capture_area = 'client'
  dialog_open = $false
  closed_preexisting = 0
  already_open = $false
  duration_ms = 0
  detail = ''
}

# clear the row filter at the end so the grid is left the way it was found
function Restore-Grid {
  if (-not $script:filterUsed) { return }
  try {
    Invoke-LeftClick 400 200
    Start-Sleep -Milliseconds 150
    Send-Keys '^f' 'grid-filter'
    Start-Sleep -Milliseconds 400
    Send-Keys '{ESC}' 'grid-filter-close'
    Start-Sleep -Milliseconds 300
  } catch { }
}

# Progress trace. A call that hangs tells you nothing on its own: the reply line is written once,
# at the end, so a timeout leaves an operator with 'it timed out' and no idea which of the six
# steps was stuck. Each stage therefore announces itself on STDERR as it starts - stderr, never
# stdout, because stdout is the reply - so the last line before a kill names the stage that hung.
# The same list is carried in the reply as `stages` for calls that do finish.
$script:stages = New-Object System.Collections.ArrayList
$script:stageName = $null
$script:stageAt = 0

function Stage([string]$name) {
  $now = $sw.ElapsedMilliseconds
  if ($script:stageName) {
    $ms = [int]($now - $script:stageAt)
    [void]$script:stages.Add([pscustomobject]@{ stage = $script:stageName; ms = $ms })
  }
  $script:stageName = $name
  $script:stageAt = $now
  [Console]::Error.WriteLine('STAGE ' + (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
    stage = $name; total_ms = [int]$now })))
  [Console]::Error.Flush()
}

function Get-EnvSnapshot {
  # Why a call failed is often not in the call: a locked or disconnected desktop, another app in
  # front, BuildAlpha restarted underneath. Recorded on failure only, where it costs nothing.
  $snap = [ordered]@{}
  try {
    if (-not ('BASV.Desktop' -as [type])) {
      $cs = @'
[DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
'@
      Add-Type -Namespace BASV -Name Desktop -MemberDefinition $cs -ErrorAction SilentlyContinue
    }
    $h = [BASV.Desktop]::OpenInputDesktop(0, $false, 0x0100)
    $snap.desktop_locked = ($h -eq [IntPtr]::Zero)
    $fg = [BASV.Desktop]::GetForegroundWindow()
    $fgPid = 0
    [void][BASV.Desktop]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $snap.foreground_title = Get-WindowTitle $fg
    $snap.foreground_pid = [int]$fgPid
  } catch { $snap.snapshot_error = "$_" }
  try {
    $snap.buildalpha_pid = $procId
    $snap.windows = @(Get-VisibleWindows $procId | ForEach-Object { Get-WindowTitle $_ })
    $snap.window_count = @($snap.windows).Count
    $snap.portfolio_window_visible = ($mainHwnd -ne [IntPtr]::Zero)
  } catch { }
  return $snap
}

function Finish([string]$status, [string]$detail = '') {
  $now = $sw.ElapsedMilliseconds
  # on failure, append the state of the machine: the cause is frequently outside the call
  if ($status -ne 'OK' -and $status -ne 'SIZE_CAP') {
    try { $result.env = Get-EnvSnapshot } catch { }
  }
  if ($script:stageName) {
    [void]$script:stages.Add([pscustomobject]@{ stage = $script:stageName; ms = [int]($now - $script:stageAt) })
    [Console]::Error.WriteLine('STAGE ' + (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
      stage = $script:stageName; ms = [int]($now - $script:stageAt); done = $true })))
  }
  $result.stages = $script:stages
  $result.last_stage = $script:stageName
  Restore-Grid
  $result.status = $status
  if ($detail) { $result.detail = $detail }
  $result.duration_ms = [int]$sw.ElapsedMilliseconds
  Write-Output ('CAPTURE ' + ($result | ConvertTo-Json -Compress -Depth 5))
  $code = switch ($status) {
    'OK' { 0 }
    'TAG_NOT_FOUND' { 2 }
    'IDENTITY_MISMATCH' { 20 }
    'GRID_NOT_VISIBLE' { 30 }
    'VIEW_NOT_FOUND' { 31 }
    'RESAMPLE_NOT_FOUND' { 32 }
    'INPUT_BLOCKED' { 25 }
    'PORTFOLIO_SWITCH_FAILED' { 5 }
    'MENU_ITEM_MISSING' { 6 }
    'WINDOW_NOT_FOUND' { 17 }
    'TIMEOUT' { 28 }
    default { 1 }
  }
  exit $code
}

function AlmostEqual([string]$a, [string]$b, [double]$tolerance) {
  # missing values are not evidence against a match (same rule as the re-run script)
  if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $true }
  $x = 0.0; $y = 0.0
  if (-not [double]::TryParse($a.Trim(), [ref]$x)) { return $true }
  if (-not [double]::TryParse($b.Trim(), [ref]$y)) { return $true }
  return ([math]::Abs($x - $y) -le $tolerance)
}

function Get-ElementTop($el) {
  # A virtualised row reports NaN or an infinite rect; casting that to [int] throws.
  if (-not $el) { return $null }
  $top = $el.Current.BoundingRectangle.Top
  if ([double]::IsNaN($top) -or [double]::IsInfinity($top)) { return $null }
  return [int]$top
}

function Get-ViewWindows([int]$procId, [IntPtr]$mainHwnd, [string]$titlePattern) {
  # Written as an explicit loop: a `return $false` inside a Where-Object block leaks a boolean
  # into the pipeline, and the caller then hands a non-handle to Get-WindowTitle.
  $out = @()
  foreach ($h in (Get-VisibleWindows $procId)) {
    if ($h -eq $mainHwnd) { continue }
    $r = Get-WindowRect $h
    if (($r.Right - $r.Left) -le 300 -or ($r.Bottom - $r.Top) -le 200) { continue }
    if ((Get-WindowTitle $h) -match "($titlePattern|^\s*$)") { $out += $h }
  }
  return $out
}

$win = Get-MainWindow
if (-not $win) { Finish 'WINDOW_NOT_FOUND' 'BuildAlpha main window not found (is the app running?)' }
$mainHwnd = [IntPtr]$win.Current.NativeWindowHandle
$procId = $win.Current.ProcessId

[void](Set-AppForeground $mainHwnd)
# Can this session type at all? SendKeys throws 'Access is denied' when the desktop is locked or
# the session is disconnected, and then the portfolio switch, the grid filter and every menu
# click silently do nothing - which later reads as 'the row is not there'. Activation is the
# earliest honest test: if BuildAlpha cannot be made the foreground window, no injected input
# can be trusted.
if (-not (Test-WindowIsForeground $mainHwnd)) {
  $fg = [BA]::GetForegroundWindow()
  $fgTitle = if ($fg -and $fg -ne [IntPtr]::Zero) { Get-WindowTitle $fg } else { '(nothing is foreground)' }
  Finish 'INPUT_BLOCKED' ("cannot activate BuildAlpha: foreground is $fgTitle. The desktop looks " +
    "locked or the session disconnected; nothing was changed and no window was touched.")
}
Send-Escape 3
Park-ResultWindows -ProcessId $procId -MainHwnd $mainHwnd

# --- the dialog may already be open ---------------------------------------
# A window left from an earlier attempt shows some other strategy, so it cannot be reused:
# capturing it would answer a question nobody asked. Close it and say so.
$existing = Get-ViewWindows $procId $mainHwnd $anyViewRegex
foreach ($h in $existing) {
  $t = Get-WindowTitle $h
  if ($t -match $anyViewRegex) {
    [void](Close-WindowChecked -hwnd $h -ProcessId $procId -Allowed @($mainHwnd))
    $result.closed_preexisting++
  }
}

# --- 1. identity ----------------------------------------------------------
$gridHwnd = @(Get-VisibleWindows $procId | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' }) | Select-Object -First 1
$gridWin = [System.Windows.Automation.AutomationElement]::FromHandle($gridHwnd)
$grid = $gridWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
# DevExpress frequently does NOT publish the grid into the window's descendant tree, but the
# grid is always reachable by hit-testing. Searching the tree alone reported "no grid" while the
# rows were plainly on screen; several points are tried because the grid's area differs with the
# window layout.
function Find-GridByPoint {
  foreach ($pt in @(@(400, 300), @(600, 400), @(300, 250), @(400, 200))) {
    try {
      $hit = Get-DataGrid (Get-ElementAt $pt[0] $pt[1])
      if ($hit) { return $hit }
    } catch { }
  }
  return $null
}
if (-not $grid) { $grid = Find-GridByPoint }
$gp = $null
for ($i = 0; $i -lt 20 -and -not $gp; $i++) {
  if ($grid) { [void]$grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp) }
  if (-not $gp) {
    Start-Sleep -Milliseconds 300
    $grid = $gridWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
    if (-not $grid) { $grid = Find-GridByPoint }
  }
}
if (-not $gp) {
  # The strategies grid can vanish from the UIA tree entirely (the documented "provider
  # gone" state: the Portfolio group is there, no DataGrid under it). Nothing about a row
  # can be answered then, and "no row matched" would be a lie about the strategy.
  $all = @($gridWin.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
  $grids = @($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataGrid }).Count
  Finish 'GRID_NOT_VISIBLE' ("the strategies grid is not in the window's automation tree " +
    "($($all.Count) elements, $grids DataGrid, stratGrid absent). BuildAlpha's portfolio view is " +
    "not materialised - bring it back (View > Portfolio, switch portfolio, or restart the app) " +
    "before capturing; nothing about a row can be checked without it.")
}

$SYMBOL_COL = 1
$NAME_COL = 5
$rowY = 0
$rowCount = $gp.Current.RowCount
$result.grid_rows = $rowCount

# --- 0. portfolio ------------------------------------------------------------
# Not done here any more. The row search owns the portfolio: it is the only place that knows
# which portfolio the tag belongs to, and it reads/switches in-process (~1.2 s) as part of its own
# first step. Doing it here as well meant two dropdown reads per capture and a -SkipPortfolio flag
# to stop the search repeating it - the duplication this removes.
# The row search lives in one place now (scripts/buildalpha_find_strategy.ps1, driven by
# strategy_cache/identify.py). When the caller supplies the plan, that script decides what to
# try and in what order; the block below is the older single-shot filter, kept for callers
# that do not pass a plan yet.
Stage 'search'
if ($PlanFile) {
  # The child narrates its progress on stderr, and a native command's stderr arrives here as an
  # error record: under $ErrorActionPreference = 'Stop' the FIRST 'STAGE {...}' line terminated
  # this script (reported as CAPTURE_FAILED with the stage line as the detail). Same guard the
  # re-run call below already uses.
  $prevEapFind = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $findOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'buildalpha_find_strategy.ps1') -PlanFile $PlanFile -ClickRow 2>&1
  $ErrorActionPreference = $prevEapFind
  # The child's stderr is merged into this stream, so a line may arrive as
  # 'powershell.exe : FIND {...}'. Matching only a line that STARTS with 'FIND ' failed silently
  # and fell back to the old filter.
  $findLine = @($findOut | Where-Object { "$_" -match 'FIND \{' }) | Select-Object -Last 1
  if (-not $findLine) {
    # No verdict means the search itself failed; say what it said instead of falling through to
    # the old single-shot filter, which then reports an empty grid and hides the real cause.
    $why = (($findOut | Where-Object { "$_".Trim() } | Select-Object -First 4) -join ' | ')
    Finish 'IDENTITY_MISMATCH' ("the row search gave no verdict: $why")
    # The shared search did not even run (missing file, syntax, dead provider). Fall through to
    # the older single-shot path instead of failing the capture on a bug in the new code.
    [Console]::Error.WriteLine("find-strategy gave no verdict: " + (($findOut | Select-Object -Last 2) -join ' '))
    $findLine = $null
    $searchDone = $false
  }
  if ($findLine) {
  $found = ($findLine -replace '^.*?FIND \{', '{') | ConvertFrom-Json
  $result.row_match = $found.matched_by
  # the portfolio the search settled on, so the reply keeps the same fields as before
  if ($found.portfolio_read) { $result.loaded_portfolio = "$($found.portfolio_read)" }
  $result.portfolio_switched = [bool]$found.portfolio_switched
  if ($found.portfolio_switch_error) { $result.portfolio_switch_error = "$($found.portfolio_switch_error)" }
  # kept for diagnosis: what was expected of the row and every attempt's verdict, so a mismatch
  # can be explained without re-running anything
  $result.expect_name = $ExpectName
  $result.expect_symbol = $ExpectSymbol
  if ($PlanFile -and (Test-Path $PlanFile)) {
    try {
      $planDoc = Get-Content $PlanFile -Raw | ConvertFrom-Json
      if ($planDoc.expected) { $result.plan_expected = $planDoc.expected }
      if ($planDoc.candidates) { $result.plan_candidates = @($planDoc.candidates | Select-Object -First 4) }
    } catch { }
  }
  $result.attempts = @($found.attempts)
  $result.filter = $found.filter
  $result.filtered_rows = $found.filtered_rows
  $result.grid_rows = $found.grid_rows
  if ($found.sample_names) { $result.sample_names = @($found.sample_names) }
  if ($found.status -ne 'OK') {
    $status = switch ($found.status) {
      'GRID_NOT_VISIBLE' { 'GRID_NOT_VISIBLE' }
      'INPUT_BLOCKED'    { 'INPUT_BLOCKED' }
      'PORTFOLIO_SWITCH_FAILED' { 'PORTFOLIO_SWITCH_FAILED' }
      'ROW_NOT_FOUND'    { 'IDENTITY_MISMATCH' }
      # several rows carried the numbers and differed: a guess would be a wrong answer
      'AMBIGUOUS'        { 'IDENTITY_MISMATCH' }
      # the row was found but the click could not be proven
      'SELECTION_FAILED' { 'IDENTITY_MISMATCH' }
      default            { 'IDENTITY_MISMATCH' }
    }
    Finish $status $found.detail
  }
  # The search knows the row's real grid Name and matched it by its numbers. From here the
  # proven single-shot path does the selecting: filter on the symbol (which the find box
  # accepts) and match that exact Name, so the row, its Y and the context menu all come from
  # one process and one screen state.
  # The search narrowed the grid to one row, clicked it and confirmed through the Strategy
  # Details panel that the app holds that strategy. Running the old filter+scan after that undid
  # all three: it re-filtered on the symbol, overwrote filtered_rows and clicked its own guess.
  if ($found.row_name) { $ExpectName = "$($found.row_name)" }
  $planMatchedBy = $found.matched_by
  $searchDone = $true
  $planClickedRow = [bool]$found.row_clicked
  $rowIndex = [int]$found.row_index
  $rowName = "$($found.row_name)"
  $rowSymbol = "$($found.row_symbol)"
  if ($null -ne $found.row_y) { $rowY = [int]$found.row_y }
  # the rect of the Symbol cell the search proved: its centre is where the re-run menu belongs
  if ($found.row_rect) { $script:foundRowRect = $found.row_rect }
  }
}

# Narrow the grid to the row before reading it. Walking 443 rows one GetItem at a time is
# both slow (minutes) and unreliable: DevExpress only materialises the visible screenful, so
# a cell read far down the grid throws and the row is silently skipped - which is how a
# present strategy came back as "no row matched". The find panel is the same grid filter the
# re-run flow uses, so the two tools see the same thing.
$script:filterUsed = ''
if ($script:filterOverride) {
  $script:filterUsed = $script:filterOverride
} elseif ($ExpectName) {
  $script:filterUsed = $ExpectName
} elseif ($ExpectSymbol) {
  $script:filterUsed = $ExpectSymbol
}
if ($script:filterUsed -and -not $searchDone) {
  Invoke-LeftClick 400 200
  Start-Sleep -Milliseconds 200
  Send-Keys '^f' 'grid-filter'
  Start-Sleep -Milliseconds 500
  Send-Keys $script:filterUsed 'grid-filter-text'
  Start-Sleep -Milliseconds 1200
  $gp = $null
  [void]$grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)
  $result.filter = $script:filterUsed
  $result.filtered_rows = if ($gp) { $gp.Current.RowCount } else { -1 }
}

if ($searchDone) { $gp = $null }   # the shared search already resolved and verified the row
if (-not $searchDone -and (-not $gp -or $gp.Current.RowCount -le 0)) {
  # A live grid always has rows. Zero (or no pattern) after the portfolio step means the
  # automation tree is empty, not that the portfolio is empty - the difference matters, so
  # it is reported instead of being turned into a name mismatch.
  Finish 'GRID_NOT_VISIBLE' ("the strategies grid reports " + $(if ($gp) { $gp.Current.RowCount } else { 'no GridPattern' }) +
    " row(s) in portfolio '$($result.loaded_portfolio)'; BuildAlpha's portfolio view is not materialised")
}
if (-not $searchDone) {
$samples = @()
if (-not $searchDone) {
$rowName = ''
$rowSymbol = ''
$rowIndex = -1
$rowCount = $gp.Current.RowCount
$samples = @()
for ($r = 0; $r -lt $rowCount; $r++) {
  $symCell = $null; $nmCell = $null
  try { $symCell = $gp.GetItem($r, $SYMBOL_COL) } catch { }
  try { $nmCell = $gp.GetItem($r, $NAME_COL) } catch { }
  if (-not $symCell -or -not $nmCell) { continue }
  $sym = (($symCell.Current.Name -split ': ', 2)[1])
  $nm = (($nmCell.Current.Name -split ': ', 2)[1])
  if (-not $sym -or -not $nm) { continue }
  # what the grid actually contains, so a failure can say whether the screen or the name is wrong
  if ($samples.Count -lt 2) { $samples += $nm.Trim() }
  if ($ExpectSymbol -and ($sym -notlike "$ExpectSymbol*")) { continue }
  if ($ExpectName -and ($nm.Trim() -ne $ExpectName.Trim())) { continue }
  $rowIndex = $r; $rowName = $nm.Trim(); $rowSymbol = $sym.Trim()
  $t = Get-ElementTop $nmCell
  if ($null -ne $t) { $rowY = $t }
  break
}
$result.sample_names = $samples
}
}
if ($planMatchedBy) { $result.row_match = $planMatchedBy }
if ($rowIndex -lt 0) {
  $where = if ($result.loaded_portfolio) { " in portfolio '$($result.loaded_portfolio)'" } else { '' }
  $gridInfo = "grid rows=$($result.grid_rows) filtered=$($result.filtered_rows) filter='$($script:filterUsed)'"
  $sampleInfo = if ($samples.Count) { " saw: " + (($samples | ForEach-Object { "'$_'" }) -join ', ') } else { ' saw: no readable rows' }
  $msg = "no row matched name='$ExpectName' symbol='$ExpectSymbol*'$where [$gridInfo].$sampleInfo"
  if ($result.portfolio_switch_error) {
    Finish 'PORTFOLIO_SWITCH_FAILED' ("$msg The portfolio could not be selected either " +
      "($($result.portfolio_switch_error)), so the row may simply not be on screen.")
  }
  Finish 'IDENTITY_MISMATCH' $msg
}
$result.row = $rowName
$result.symbol = $rowSymbol

# the row's own metrics must be the ones the cache predicted, else this is a namesake
if ($ExpectedTrades -ge 0 -or $ExpectedSharpe -ge 0 -or $ExpectedPnl -ge 0) {
  $cells = @{}
  for ($c = 0; $c -lt 40; $c++) {
    $cell = $null
    try { $cell = $gp.GetItem($rowIndex, $c) } catch { continue }
    if (-not $cell) { continue }
    if ($cell.Current.Name -match 'Column (.*?), Column \d+ of \d+: (.*)$') {
      $cells[$Matches[1]] = $Matches[2]
    }
  }
  $bad = @()
  if ($ExpectedTrades -ge 0 -and -not (AlmostEqual "$($cells['Trades'])" "$ExpectedTrades" 0.5)) {
    $bad += "trades expected=$ExpectedTrades actual='$($cells['Trades'])'"
  }
  if ($ExpectedSharpe -ge 0 -and -not (AlmostEqual "$($cells['Sharpe'])" "$ExpectedSharpe" 0.02)) {
    $bad += "sharpe expected=$ExpectedSharpe actual='$($cells['Sharpe'])'"
  }
  if ($ExpectedPnl -ge 0 -and -not (AlmostEqual "$($cells['Net P&L'])" "$ExpectedPnl" 0.5)) {
    $bad += "pnl expected=$ExpectedPnl actual='$($cells['Net P&L'])'"
  }
  if ($bad.Count) { Finish 'IDENTITY_MISMATCH' ($bad -join '; ') }
}

# A navigation-panel button. Most carry AutomationId 'HamburgerMenuNavigationButton', but not
# all - Metrics is plain 'metrics' - so a name match inside the menu pane counts too.
function Find-NavButton($root, $name, $navId) {
  $all = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
  $byName = @($all | Where-Object {
      $_.Current.Name -eq $name -and
      ($_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' -or
       ($navId -and $_.Current.AutomationId -eq $navId))
    })
  if ($byName.Count) { return $byName }
  $walk = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  foreach ($el in @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Button' -and $_.Current.Name -eq $name })) {
    $n = $el
    for ($i = 0; $i -lt 6; $i++) {
      $n = $walk.GetParent($n)
      if (-not $n) { break }
      if ($n.Current.AutomationId -eq 'HamburgerMenu') { return $el }
    }
  }
  return @()
}

# --- 1b. open the strategy in a Re-Run window ------------------------------
# BuildAlpha binds its analysis views to the strategy each view was last opened for, so opening
# 'Variance Testing' from the portfolio view can show a different strategy even though the grid
# is filtered to one row and the Strategy Details panel shows ours (verified: details 133606.25,
# view titled with an unrelated Thai SET strategy). BuildAlpha support confirms there is no fix
# yet; the workaround is to re-run the row first and open the view from the Re-Run window,
# which is seeded with that strategy.
function Test-ResultsWindow([IntPtr]$h) {
  # A re-run results window has no title in UI Automation AND shows the strategy's columns.
  # Matching on "untitled" alone picked the wrong window whenever several were left open.
  if ((Get-WindowTitle $h) -ne '') { return $false }
  $r = Get-WindowRect $h
  if (($r.Right - $r.Left) -lt 400) { return $false }
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $cells = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
      Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Symbol, ' })
    return ($cells.Count -gt 0)
  } catch { return $false }
}

function Find-ResultsWindow([int]$seconds = 12) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    foreach ($cand in (Get-VisibleWindows $procId)) {
      if ((Get-WindowTitle $cand) -ne '') { continue }
      $r = Get-WindowRect $cand
      if (($r.Right - $r.Left) -lt 400) { continue }
      try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($cand)
        $strategyCells = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
          [System.Windows.Automation.Condition]::TrueCondition) |
          Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Symbol, ' })
        if ($strategyCells.Count -gt 0) { return $cand }
      } catch { }
    }
    Start-Sleep -Milliseconds 400
  }
  return [IntPtr]::Zero
}

function Test-RowSelected([IntPtr]$hwnd) {
  # Ask the GRID for its selection set (SelectionPattern.GetSelection), not a per-cell IsSelected
  # flag. The pattern belongs to the grid, is re-read after the click, and returns the rows the
  # application itself considers selected - the per-cell flag lags and lies.
  $el = $null
  try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { return @{ ok = $false; why = 'window gone' } }
  $grid = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::DataGrid)))
  if (-not $grid) { return @{ ok = $false; why = 'no DataGrid in this window' } }
  $sp = $null
  if ($grid.TryGetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern, [ref]$sp)) {
    try {
      $sel = @($sp.Current.GetSelection())
      if ($sel.Count -gt 0) {
        $names = @($sel | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
        return @{ ok = $true; how = 'grid-selection-pattern'; names = $names }
      }
    } catch { }
  }
  # fallback: a cell whose selection flag is set, read fresh
  $cells = @($grid.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Symbol' })
  foreach ($c in $cells) {
    $cs = $null
    if ($c.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$cs)) {
      try { if ($cs.Current.IsSelected) { return @{ ok = $true; how = 'cell-selected'; names = @($c.Current.Name) } } } catch { }
    }
  }
  return @{ ok = $false; why = 'the grid reports no selection' }
}

$rerunHwnd = [IntPtr]::Zero
# If a results window is already open, use it: it was produced by a re-run of this strategy and
# closing it to re-run again throws away a finished run (and doubles the time).
foreach ($cand in (Get-VisibleWindows $procId)) {
  if ((Get-WindowTitle $cand) -eq 'Build Alpha') { continue }
  $crect = Get-WindowRect $cand
  if (($crect.Right - $crect.Left) -lt 300) { continue }
  try {
    $cel = [System.Windows.Automation.AutomationElement]::FromHandle($cand)
    $hasNav = $cel.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'HamburgerMenuNavigationButton')))
    if ($hasNav -and (Test-ResultsWindow $cand)) {
      # Only reuse a results window that belongs to THIS strategy. A leftover from another call
      # shows another row, and its views open for that row - which is how a named tag came back
      # with a stranger's strategy.
      $rowOk = $false
      try {
        $cel2 = [System.Windows.Automation.AutomationElement]::FromHandle($cand)
        $nameCell = @($cel2.FindAll([System.Windows.Automation.TreeScope]::Descendants,
          [System.Windows.Automation.Condition]::TrueCondition) |
          Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Name, ' }) | Select-Object -First 1
        if ($nameCell) {
          $rowText = ($nameCell.Current.Name -split 'Column \d+ of \d+: ', 2)[-1].Trim()
          if ($ExpectName -and $rowText -eq $ExpectName.Trim()) { $rowOk = $true }
          elseif ($ExpectName -and $rowText -like "*$($ExpectName.Trim())*") { $rowOk = $true }
          $result.reuse_row = $rowText
        }
      } catch { }
      if ($rowOk) { $rerunHwnd = $cand; $result.rerun_reused = $true; break }
    }
  } catch { }
}

if ($true) {   # always: the view may only be opened from a re-run's results window
  if ($rerunHwnd -ne [IntPtr]::Zero) {
    # a results window is already in hand - do not close it, and do not re-run
  }
  # Close leftovers first (only when there is nothing to reuse): a stale results window from an earlier call would be picked up as
  # "the" results window, and a stray Re-Run form would be mistaken for this call's. One call =
  # one re-run = one results window.
  foreach ($h in (Get-VisibleWindows $procId)) {
    $staleTitle = Get-WindowTitle $h
    if ($staleTitle -eq '' -and $h -ne $rerunHwnd) {
      # an untitled window that is not the one we are about to use is a leftover
      try { [void](Close-WindowChecked -hwnd $h -ProcessId $procId -Allowed @($mainHwnd)) } catch { }
      continue
    }
    if ($staleTitle -eq 'Build Alpha') { continue }
    $staleRect = Get-WindowRect $h
    if (($staleRect.Right - $staleRect.Left) -lt 300) { continue }
    $isReRunForm = ($staleTitle -eq 'Re-Run')
    $hasNav = $false
    try {
      $staleEl = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $hasNav = [bool]$staleEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'HamburgerMenuNavigationButton')))
    } catch { }
    if ($isReRunForm -or $hasNav) {
      [Console]::Error.WriteLine("closing stale window '$staleTitle'")
      try { [void](Close-WindowChecked -hwnd $h -ProcessId $procId -Allowed @($mainHwnd)) } catch { }
    }
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # With the grid filtered to a single row, let the re-run script find that row itself (Y <= 0
  # means "scan"): maximising the window shifts the rows by a few pixels, and a Y measured before
  # that landed on empty space - "Could not find a data row".
  # Always use the Y of the row that was verified and clicked: scan mode (0) depends on the
  # window layout and failed on a cold app, while this Y comes from the matched cell itself.
  $rerunY = $rowY
  # the x of the proven Symbol cell, so the re-run's menu opens on that cell rather than on
  # whatever column a scan happens to hit
  $rerunX = if ($script:foundRowRect) { [int]([double]$script:foundRowRect.x + [double]$script:foundRowRect.width / 2) } else { 0 }
Stage 're-run'
  $rerunOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'buildalpha_rerun.ps1') `
    -RowY $rerunY -RowX $rerunX -KeepFilter -ExpectSymbol $ExpectSymbol -Target '^\s*re[-\s]?run\s*$' 2>&1 | Out-String
  $ErrorActionPreference = $prevEap
  if ($rerunOut -notmatch 'DONE: activated') {
    [Console]::Error.WriteLine("re-run open failed: $($rerunOut.Trim())")
  }
  # A plain Re-Run does not open a 'Re-Run' settings window - it runs and opens a results window
  # whose title is empty in UI Automation but which contains the navigation panel. That window is
  # the one seeded with this strategy, so the view is opened from there.
Stage 'wait-results-window'
  for ($i = 0; $i -lt 90 -and $rerunHwnd -eq [IntPtr]::Zero; $i++) {   # 45 s: a cold app can take a while
    Start-Sleep -Milliseconds 500
    foreach ($cand in (Get-VisibleWindows $procId)) {
      $ctitle = Get-WindowTitle $cand
      if ($ctitle -eq 'Build Alpha') { continue }
      $crect = Get-WindowRect $cand
      if (($crect.Right - $crect.Left) -lt 400) { continue }
      try {
        $cel = [System.Windows.Automation.AutomationElement]::FromHandle($cand)
        $hit = $cel.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'HamburgerMenuNavigationButton')))
        if ($hit -and (Test-ResultsWindow $cand)) { $rerunHwnd = $cand; break }
      } catch { }
    }
  }
  if ($rerunHwnd -eq [IntPtr]::Zero) {
    Finish 'RERUN_WINDOW_MISSING' ("the Re-Run window for '$rowName' did not open; BuildAlpha binds " +
      "analysis views to a strategy of its own, so the view is opened from a re-run instead")
  }
  $result.rerun_opened = $true
  # every later step (nav button, capture, close) works on this window instead of the portfolio
  # the handle found a moment ago may already be gone: look again, freshly, for the results window
  try {
    $gridWin = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
  } catch {
    $rerunHwnd = Find-ResultsWindow 10
    if ($rerunHwnd -eq [IntPtr]::Zero) { Finish 'RERUN_WINDOW_MISSING' 'the re-run results window disappeared' }
    try { $gridWin = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd) } catch { Finish 'RERUN_WINDOW_MISSING' "unusable results window: $_" }
  }
  if ($false) {
    Finish 'RERUN_WINDOW_MISSING' ("the results window went away before it could be used: $_")
  }
  # the results window must hold the foreground before its grid is clicked
  if (-not (Focus-WindowVerified $rerunHwnd)) {
    Finish 'INPUT_BLOCKED' 'could not bring the re-run results window to the front; not clicking blind'
  }
  Start-Sleep -Milliseconds 300

  # Select the row in the results window BEFORE anything is invoked. A freshly opened window
  # publishes no cells until it is in front and has painted, and invoking a view with no current
  # row makes BuildAlpha answer "No strategy selected" instead of opening the view. So: focus is
  # required, a published row is required, and the row is clicked - in that order.
Stage 'select-results-row'
  $clicked = $false
  for ($try = 0; $try -lt 24 -and -not $clicked; $try++) {
    if (-not (Focus-WindowVerified $rerunHwnd)) {
      Finish 'INPUT_BLOCKED' 'the re-run results window will not take the foreground'
    }
    $el = $null
    try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd) } catch { Start-Sleep -Milliseconds 400; continue }
    $cells = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
      Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Symbol' })
    if ($cells.Count -eq 0) { Start-Sleep -Milliseconds 500; continue }
    $cell = $cells[0]
    $result.results_row = "$($cell.Current.Name)"
    $rect = $cell.Current.BoundingRectangle
    if ($rect.Height -le 4) { Start-Sleep -Milliseconds 500; continue }
    Invoke-LeftClick ([int]($rect.X + 24)) ([int]($rect.Y + $rect.Height / 2))
    Start-Sleep -Milliseconds 500

    # Verify the way the application sees it: ask the grid for its selection set.
    $verdict = Test-RowSelected $rerunHwnd
    $result.selection_how = "$($verdict.how)"
    $result.selection_evidence = if ($verdict.names) { (@($verdict.names) -join ' | ') } else { "$($verdict.why)" }
    if ($verdict.ok) { $clicked = $true; $result.results_row_selected = $true }
    else {
      # one retry, clicking a different column of the same verified row
      Invoke-LeftClick ([int]($rect.X + 60)) ([int]($rect.Y + $rect.Height / 2))
      Start-Sleep -Milliseconds 600
      $verdict = Test-RowSelected $rerunHwnd
      $result.selection_how = "$($verdict.how)"
      $result.selection_evidence = if ($verdict.names) { (@($verdict.names) -join ' | ') } else { "$($verdict.why)" }
      if ($verdict.ok) { $clicked = $true; $result.results_row_selected = $true }
    }
  }
  if (-not $clicked) {
    Finish 'IDENTITY_MISMATCH' ("the strategy row in the results window could not be shown to be " +
      "selected ($($result.selection_evidence)); refusing to open a view that would answer " +
      "'No strategy selected'")
  }
  # Not a hard gate: an element obtained before the click keeps reporting its old state, so
  # IsSelected from a stale reference says False after a click that did select the row. The view's
  # title is the authority.
}

Stage 'open-view'
# --- 2. open the view -----------------------------------------------------
$gridWin = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
# Only the results window may open a view: opening one from the portfolio shows whatever strategy
# the app bound the view to last. There is deliberately no fallback.
if ($rerunHwnd -eq [IntPtr]::Zero) {
  Finish 'RERUN_WINDOW_MISSING' 'no re-run results window to open the view from'
}
[void](Set-AppForeground $rerunHwnd)
# (no portfolio click here: the row was clicked before the re-run, and clicking again could
# select a different row)

$before = @(Get-VisibleWindows $procId)
# The tree is re-read after filtering: DevExpress redraws the whole window when the row set
# changes, and a single snapshot can catch it mid-update with the right-hand panel absent.
$nav = @(Find-NavButton $gridWin $navName $spec.NavId) | Select-Object -First 1
$descendants = 0
for ($i = 0; $i -lt 6 -and -not $nav; $i++) {
  $all = @($gridWin.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
  $descendants = $all.Count
  $nav = @($all | Where-Object {
      $_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' -and $_.Current.Name -eq 'Variance Testing' }) | Select-Object -First 1
  if (-not $nav) { Start-Sleep -Milliseconds 500 }
}
$result.nav_buttons = if ($nav) { 1 } else { 0 }
  # Log what the navigation lookup actually saw: the view asked for, the automation id used, and
  # every nav button present in the window the view is being opened from.
  $result.nav_name = $navName
  $result.nav_id = $spec.NavId
  $result.nav_window = if ($rerunHwnd -ne [IntPtr]::Zero) { 'results' } else { 'portfolio' }
  try {
    $navAll = @($gridWin.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
      Where-Object { $_.Current.AutomationId -in @('HamburgerMenuNavigationButton','metrics','ecurve','vsShift') })
    $result.nav_candidates = @($navAll | ForEach-Object { "$($_.Current.AutomationId):$($_.Current.Name)" })
  } catch { $result.nav_candidates = @() }
$result.descendants = $descendants

$attempts = @()
if ($nav) {
  # Resolve the button at click time, not from an earlier snapshot: the panel re-renders when the
  # grid filter changes, and a stale element's InvokePattern can fire on a *different* button
  # (asking for MC Analysis opened Variance Testing).
  $attempts += @{ How = 'uia-name'; Do = {
      $fresh = @(Find-NavButton $gridWin $navName $spec.NavId) | Select-Object -First 1
      if ($fresh) {
        $fp = $null
        if ($fresh.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$fp)) { $fp.Invoke() }
        else {
          $fr = $fresh.Current.BoundingRectangle
          Invoke-LeftClick ([int]($fr.Left + $fr.Width / 2)) ([int]($fr.Top + $fr.Height / 2))
        }
      }
    } }
  $nr = $nav.Current.BoundingRectangle
  if ($spec.Key) {
    $attempts += @{ How = 'accelerator'; Do = {
        Invoke-LeftClick ([int]($nr.Left + $nr.Width / 2)) ([int]($nr.Top + $nr.Height / 2))
        Start-Sleep -Milliseconds 700
        Send-Keys $spec.Key
      } }
  }
  $attempts += @{ How = 'label-ocr'; Do = {
      $ham = @($gridWin.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
          Where-Object { $_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' }) | Select-Object -First 1
      if ($ham) {
        $hr = $ham.Current.BoundingRectangle
        Invoke-LeftClick ([int]($hr.Left + $hr.Width / 2)) ([int]($hr.Top + $hr.Height / 2))
        Start-Sleep -Milliseconds 900
      }
      $popup = @(Get-VisibleWindows $procId | Where-Object { $before -notcontains $_ -and (Get-WindowTitle $_) -eq '' }) |
        Select-Object -First 1
      if ($popup) {
        $labelPattern = '(?i)' + ([regex]::Escape($navName).Replace('\\ ', '\\s+'))
        $item = @(Get-MenuItems $popup | Where-Object { $_.Text -match $labelPattern }) | Select-Object -First 1
        if ($item) { Invoke-LeftClick $item.X $item.Y }
      }
    } }
} else {
  if ($spec.Key) { $attempts += @{ How = 'accelerator'; Do = { Send-Keys $spec.Key } } }
}

$view = [IntPtr]::Zero
# One way only. The InvokePattern route on a freshly resolved button is the sequence proven five
# times out of five; the accelerator and OCR-label variants clicked around the menu and sometimes
# consumed the action.
$attempts = @($attempts | Where-Object { $_.How -eq 'uia-name' })
foreach ($a in $attempts) {
  if ($sw.ElapsedMilliseconds -gt ($TimeoutSec * 1000)) { break }
  try { & $a.Do } catch { }
  # A view that computes before it draws (MC Analysis) takes far longer than Variance Testing
  # to show its window, so each attempt gets a real share of the budget instead of 6 s.
  $deadline = [Math]::Min($TimeoutSec * 1000, $sw.ElapsedMilliseconds + 15000)
  while ($sw.ElapsedMilliseconds -lt $deadline) {
    Start-Sleep -Milliseconds 300
    # Only a window that did not exist before this action can be ours. Taking the first
    # 'Variance Testing' window found meant a leftover from an earlier call (showing some
    # other strategy) was captured and reported as the target - the title in the reply said
    # so, but nothing compared it with anything.
    $new = @(Get-ViewWindows $procId $mainHwnd $titleRegex |
      Where-Object { (Get-WindowTitle $_) -match $titleRegex -and ($before -notcontains $_) })
    if ($new.Count) { $view = [IntPtr][int64]$new[0]; break }
    # A window with a *different* view title means the click landed on the wrong button. Close it
    # and let the next attempt resolve the button again, rather than capturing the wrong view.
    $wrong = @(Get-ViewWindows $procId $mainHwnd $anyViewRegex |
      Where-Object { (Get-WindowTitle $_) -notmatch $titleRegex -and ($before -notcontains $_) })
    foreach ($w in $wrong) {
      [Console]::Error.WriteLine("attempt '{0}': '$((Get-WindowTitle $w))' opened instead of '{1}'; closing it" -f $a.How, $ViewName)
      [void](Close-WindowChecked -hwnd $w -ProcessId $procId -Allowed @($mainHwnd))
      $result.closed_preexisting++
      $before += $w
    }
  }
  if ($view -ne [IntPtr]::Zero) { $result.accelerator_used = $a.How; $result.view_opened_by = $a.How; break }
  $seen = @(Get-VisibleWindows $procId | ForEach-Object { Get-WindowTitle $_ }) -join ' | '
  [Console]::Error.WriteLine("attempt '{0}': no window yet; on screen: {1}" -f $a.How, $seen)
}

# The title is recorded, not judged. Identity was established on the grid row (its own Trades /
# Sharpe / Net P&L against the cache) and the re-run was executed on that verified row, so the
# results window belongs to that strategy by construction. Comparing the title text to the rule
# string failed for strategies whose rules BuildAlpha reorders in the title - a cosmetic
# difference being treated as an identity failure. Only the view prefix matters, and that is
# already enforced when the window is accepted.
if ($view -ne [IntPtr]::Zero) {
  $result.title = Get-WindowTitle $view
}

if ($view -eq [IntPtr]::Zero) {
  # One deliberate second try: a results window that has only just opened publishes its buttons
  # before it will act on them, so re-select the row, give it a moment, then invoke again.
  Start-Sleep -Seconds 2
  try {
    $el2 = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
    $c2 = @($el2.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
      Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column Symbol' }) | Select-Object -First 1
    if ($c2) {
      $r2 = $c2.Current.BoundingRectangle
      [void](Focus-WindowVerified $rerunHwnd)
      Invoke-LeftClick ([int]($r2.X + 24)) ([int]($r2.Y + $r2.Height / 2))
      Start-Sleep -Milliseconds 800
    }
    $el3 = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
    $n3 = @($el3.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
      Where-Object { $_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' -and $_.Current.Name -eq $navName }) | Select-Object -First 1
    if ($n3) {
      $before2 = @(Get-VisibleWindows $procId)
      $ip3 = $null
      if ($n3.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip3)) {
        $ip3.Invoke()
        for ($k = 0; $k -lt 12 -and $view -eq [IntPtr]::Zero; $k++) {
          Start-Sleep -Seconds 1
          $newW = @(Get-ViewWindows $procId $mainHwnd $titleRegex | Where-Object { (Get-WindowTitle $_) -match $titleRegex -and ($before2 -notcontains $_) })
          if ($newW.Count) { $view = [IntPtr][int64]$newW[0] }
        }
      }
    }
  } catch { }
}

if ($view -eq [IntPtr]::Zero) {
  $now = @(Get-VisibleWindows $procId | ForEach-Object { "'$(Get-WindowTitle $_)'" }) -join ', '
  if ($sw.ElapsedMilliseconds -gt ($TimeoutSec * 1000)) {
    Finish 'TIMEOUT' "budget ${TimeoutSec}s exhausted before the view opened; windows: $now"
  }
  if (-not $nav) {
    Finish 'VIEW_NOT_FOUND' ("nav button '$navName' is not in the menu (" + "$descendants elements scanned after 6 tries); windows: $now")
  }
  Finish 'WINDOW_NOT_FOUND' "the item was found but no '$navName' window appeared; windows: $now"
}
$result.title = Get-WindowTitle $view
$result.dialog_open = $true

Stage 'settle'
# --- 3. settle: two frames of the same size ------------------------------
[void][BA]::ShowWindow($view, 9)   # SW_RESTORE: a minimised dialog has no pixels to read
[void](Set-AppForeground $view)
$last = ''
$same = 0
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 200
  $r = Get-WindowRect $view
  $sig = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
  if ($sig -eq $last) { $same++ } else { $same = 0; $last = $sig }
  if ($same -ge 2) { break }
}
Start-Sleep -Milliseconds 400

# --- 3b. the view's own button (e.g. Resample), if this view has one ----
# Clicked by UIA name first, then by OCR of the button row: some of these views draw the label.
# The capture then waits for the picture to change rather than for a fixed delay - a resample
# redraws the panel, and the post-resample state is the whole point of the call.
if ($Button) {
  $vw = [System.Windows.Automation.AutomationElement]::FromHandle($view)
  $btn = $null
  for ($i = 0; $i -lt 6 -and -not $btn; $i++) {
    $els = @($vw.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
    $btn = @($els | Where-Object { $_.Current.Name -eq $Button -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button }) | Select-Object -First 1
    if (-not $btn) { Start-Sleep -Milliseconds 300 }
  }
  $clicked = $false
  if ($btn) {
    $bip = $null
    if ($btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$bip)) {
      $bip.Invoke()
      $clicked = $true
    } else {
      $br = $btn.Current.BoundingRectangle
      if (-not [double]::IsInfinity($br.X)) {
        Invoke-LeftClick ([int]($br.Left + $br.Width / 2)) ([int]($br.Top + $br.Height / 2))
        $clicked = $true
      }
    }
  }
  if (-not $clicked) {
    $wr0 = Get-WindowRect $view
    foreach ($bandH in @(40, 80, 140)) {
      $words = @(Get-OcrWords ([int]$wr0.Left + 4) ([int]$wr0.Top + 30) ([int]($wr0.Right - $wr0.Left) - 8) $bandH 3)
      $hit = @($words | Where-Object { $_.Text -match "(?i)^$([regex]::Escape($Button))" }) | Select-Object -First 1
      if ($hit) { Invoke-LeftClick $hit.X ($hit.Y + 4); $clicked = $true; break }
    }
  }
  if (-not $clicked) {
    [void](Close-WindowChecked -hwnd $view -ProcessId $procId -Allowed @($mainHwnd))
    Finish 'RESAMPLE_NOT_FOUND' ("the view opened but no '$Button' button was found by name or by OCR; " +
      "the window was closed and no file was written")
  }
  $result.button_clicked = $Button
  function Get-PixelSig([IntPtr]$hwnd) {
    $r = Get-WindowRect $hwnd
    $w = [int]([Math]::Min(200, $r.Right - $r.Left)); $h = [int]([Math]::Min(120, $r.Bottom - $r.Top))
    if ($w -le 8 -or $h -le 8) { return '' }
    $b = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen([int]$r.Left + 20, [int]$r.Top + 60, 0, 0, (New-Object System.Drawing.Size -ArgumentList $w, $h))
    $g.Dispose()
    $sb = New-Object System.Text.StringBuilder
    for ($x = 0; $x -lt $w; $x += 7) { for ($y = 0; $y -lt $h; $y += 7) { [void]$sb.Append($b.GetPixel($x, $y).ToArgb()) } }
    $b.Dispose()
    return $sb.ToString()
  }
  $sigBefore = Get-PixelSig $view
  $changed = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    if ((Get-PixelSig $view) -ne $sigBefore) { $changed = $true; break }
  }
  $result.button_redraw = $changed
  [Console]::Error.WriteLine("button: '$Button' clicked, redraw_detected=$changed")
}

# Size the view before capturing. Maximised, the view is ~1528x918 and the PNG lands around
# 1.1 MB; at 1000x750 it is roughly a third of that with the text still at native pixels. Only the
# view window is resized, and it is closed afterwards, so nothing of the portfolio is altered.
$captureW = 1000
$captureH = 750
try {
  $vw = Get-WindowRect $view
  if ((($vw.Right - $vw.Left) -gt $captureW + 40) -or (($vw.Bottom - $vw.Top) -gt $captureH + 40)) {
    [void][BA]::SetWindowPos($view, [IntPtr]::Zero, [int]$vw.Left, [int]$vw.Top, $captureW, $captureH, 0x0004 -bor 0x0010)
    Start-Sleep -Milliseconds 700
    $result.view_resized = "$captureW`x$captureH"
  }
} catch { }

Stage 'capture'
# --- 4. capture the client area -----------------------------------------
Add-Type -Namespace BASV -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
'@ -ErrorAction SilentlyContinue

$wr = Get-WindowRect $view
$winW = $wr.Right - $wr.Left
$winH = $wr.Bottom - $wr.Top
$full = New-Object System.Drawing.Bitmap -ArgumentList $winW, $winH
$g = [System.Drawing.Graphics]::FromImage($full)
$hdc = $g.GetHdc()
$ok = [BASV.Native]::PrintWindow($view, $hdc, 2)     # PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
$g.Dispose()

function Get-FlatShare($bmp) {
  $w = $bmp.Width; $h = $bmp.Height
  $counts = @{}; $total = 0
  $sx = [Math]::Max(1, [int]($w / 48)); $sy = [Math]::Max(1, [int]($h / 48))
  for ($x = 0; $x -lt $w; $x += $sx) {
    for ($yy = 0; $yy -lt $h; $yy += $sy) {
      $c = $bmp.GetPixel($x, $yy).ToArgb()
      $counts[$c] = 1 + ($counts[$c] -as [int]); $total++
    }
  }
  return [double](($counts.Values | Measure-Object -Maximum).Maximum) / [double]$total
}

$share = if ($ok) { Get-FlatShare $full } else { 1.0 }
if (-not $ok -or $share -gt 0.97) {
  # PrintWindow failed or gave a single flat colour: grab the screen instead
  $full.Dispose()
  [void](Set-AppForeground $view)
  Start-Sleep -Milliseconds 700
  $full = New-Object System.Drawing.Bitmap -ArgumentList $winW, $winH
  $g = [System.Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($wr.Left, $wr.Top, 0, 0, (New-Object System.Drawing.Size -ArgumentList $winW, $winH))
  $g.Dispose()
  $share = Get-FlatShare $full
  $result.capture_area = 'window'
}
if ($share -gt 0.97) {
  $full.Dispose()
  [void](Close-WindowChecked -hwnd $view -ProcessId $procId -Allowed @($mainHwnd))
  Finish 'CAPTURE_FAILED' ("BLANK_SHOT: dominant colour share {0:N3} - refusing to save a flat image" -f $share)
}

# crop to the client area, so the frame and title bar are not part of the image
$cr = New-Object BASV.Native+RECT
$pt = New-Object BASV.Native+POINT
$null = [BASV.Native]::GetClientRect($view, [ref]$cr)
$pt.X = 0; $pt.Y = 0
$null = [BASV.Native]::ClientToScreen($view, [ref]$pt)
$offX = $pt.X - $wr.Left
$offY = $pt.Y - $wr.Top
$cw = $cr.Right - $cr.Left
$ch = $cr.Bottom - $cr.Top
$crop = $full
if ($cw -gt 50 -and $ch -gt 50 -and ($cw + $offX) -le $winW -and ($ch + $offY) -le $winH) {
  $crop = New-Object System.Drawing.Bitmap -ArgumentList $cw, $ch
  $cg = [System.Drawing.Graphics]::FromImage($crop)
  $cg.DrawImage($full, (New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $cw, $ch),
    (New-Object System.Drawing.Rectangle -ArgumentList $offX, $offY, $cw, $ch),
    [System.Drawing.GraphicsUnit]::Pixel)
  $cg.Dispose()
  $full.Dispose()
} else {
  $result.capture_area = 'window'
}

# --- 4b. read the statistics panel ---------------------------------------
# The panel is bottom-left and drawn white-on-black, which is the hard case for OCR: it is
# cropped out of the window rect (never the whole screen) and upscaled before reading. A
# failed read is reported, not fatal - the image and the file are already in hand.
if ($script:EnableOcrSummary) {
  $summary = Read-VarianceSummaryBitmap $crop
  $result.summary = $summary.Fields
  $result.summary_status = $summary.Status
  if ($OcrDump) { $summary.Lines | Set-Content -Encoding utf8 $OcrDump }
}

# --- 4c. crop to one cell (views whose interest is a single panel) -------
# The Metrics window is a 5-column by 4-row grid of plots: the top-left cell holds E-Ratio.
# One fifth of the width by one quarter of the height does NOT land on it, because the window
# draws its own title bar and a toolbar row (68 px) and the column pitch is 156 px, not
# 800/5 = 160. Cropping from (0,0) therefore returned the title, the toolbar and half a plot.
# The rect below is measured from the live window: x=4 y=68 156x132 puts the E-Ratio label and
# both axes inside the frame with no clipping. It is recorded in the reply, so a clip shows up
# as numbers rather than as a picture nobody can correct.
if ($spec.Crop -eq 'cell') {
  $srcW = $crop.Width
  $srcH = $crop.Height
  $cellX = 4; $cellY = 68; $cellW = 156; $cellH = 132
  if (($cellX + $cellW) -gt $srcW -or ($cellY + $cellH) -gt $srcH) {
    Finish 'CAPTURE_FAILED' ("client area {0}x{1} cannot hold the {2}x{3} cell at {4},{5}" -f $srcW, $srcH, $cellW, $cellH, $cellX, $cellY)
  }
  $cell = New-Object System.Drawing.Bitmap -ArgumentList $cellW, $cellH
  $cgc = [System.Drawing.Graphics]::FromImage($cell)
  $cgc.DrawImage($crop, (New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $cellW, $cellH),
    (New-Object System.Drawing.Rectangle -ArgumentList $cellX, $cellY, $cellW, $cellH), [System.Drawing.GraphicsUnit]::Pixel)
  $cgc.Dispose()
  $crop.Dispose()
  $crop = $cell
  $result.crop = [ordered]@{ x = $cellX; y = $cellY; width = $cellW; height = $cellH; source_width = $srcW; source_height = $srcH }
}

Stage 'save'
# --- 5. downscale, save, verify -----------------------------------------
$srcW = $crop.Width
$srcH = $crop.Height
$result.downscaled_from = $srcW
$targetW = [Math]::Min($MaxWidth, $srcW)
$targetH = [int][Math]::Round($srcH * ($targetW / [double]$srcW))
$final = $crop
if ($targetW -lt $srcW) {
  $final = New-Object System.Drawing.Bitmap -ArgumentList $targetW, $targetH
  $fg = [System.Drawing.Graphics]::FromImage($final)
  $fg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $fg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $fg.DrawImage($crop, 0, 0, $targetW, $targetH)
  $fg.Dispose()
  $crop.Dispose()
}

$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
$final.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$result.width = $final.Width
$result.height = $final.Height
$final.Dispose()

$file = Get-Item $Out
$result.path = $file.FullName
$result.bytes = $file.Length
$result.sha256 = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLower()

# The dialog is closed after the capture: an open Variance Testing window holds the
# foreground and the next call (or any other tool) would have to fight it.
$closed = Close-WindowChecked -hwnd $view -ProcessId $procId -Allowed @($mainHwnd)
$result.dialog_open = $false
$result.dialog_closed = [bool]$closed.closed
# Clean up after a successful capture: the view and the re-run results window exist only for this
# call, and leaving them over the portfolio is what made the next call see several untitled
# windows and pick the wrong one.
if ($view -ne [IntPtr]::Zero) {
  try { if (Close-WindowChecked -hwnd $view -ProcessId $procId -Allowed @($mainHwnd)) { $result.dialog_closed = $true } } catch { }
}
if ($rerunHwnd -ne [IntPtr]::Zero) {
  try { if (Close-WindowChecked -hwnd $rerunHwnd -ProcessId $procId -Allowed @($mainHwnd)) { $result.rerun_closed = $true } } catch { }
}
Finish 'OK' 
