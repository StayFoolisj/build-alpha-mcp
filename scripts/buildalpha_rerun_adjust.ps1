<#
.SYNOPSIS
  Re-run one portfolio strategy with adjustments (currently: the symbol) and
  report the results - or, with -DryRun, just apply and verify the change.

.DESCRIPTION
  End-to-end, no manual steps:
    1. filter the portfolio grid (Ctrl+F) and verify the row's Symbol cell,
    2. open the row's "Run strategy with adjustments" window,
    3. switch to the requested symbol tab and pick the new symbol
       (search -> Find -> expand asset class -> Find -> check -> OK),
    4. read the form back and report what changed (VERIFY lines),
    5. with -DryRun: close the window and stop - nothing is simulated,
       otherwise click "Regular simulation", wait for the results window,
       read its single result row as JSON, then close both windows.

  Deliberately a *closed set*: only the symbol is adjustable today. Other
  fields (dates, costs, type, fitness) each need their own verified
  interaction method before they are exposed - see the README.

  The built-in picker only matches rows inside an *expanded* asset class, and
  the search text must not carry the '@' prefix (verified: 'ZEC' finds the
  Crypto group, '@ZEC' finds nothing).

.PARAMETER Filter
  Text typed into the grid's find panel.

.PARAMETER ExpectSymbol
  Server-side symbol prefix the located row must have (e.g. 'BTC'). Exit 6 on
  mismatch - nothing is clicked in that case.

.PARAMETER ExpectName
  Exact text of the row's Name cell (trimmed). For unnamed strategies that is the
  rule expression, which the caller gets from the cache - never from a guess.
  The grid is walked row by row and the first row whose Symbol matches and whose
  Name is exactly this string is chosen; nothing is clicked before that. Exit 6
  (ROW_NOT_FOUND) when no row matches.

.PARAMETER ExpectedTrades / ExpectedSharpe / ExpectedPnl
  Baseline metrics from the cache. When given, the located row's own metrics must
  match them (tolerance 0.5 trades / 0.02 Sharpe / 0.5 P&L), otherwise the script
  stops with IDENTITY_MISMATCH (exit 20) and clicks nothing. This is what makes a
  wrong row impossible instead of merely reported.

.PARAMETER Portfolio
  Portfolio the strategy lives in. When it differs from the selected one, the
  script switches with buildalpha_switch_portfolio.ps1 and requires SWITCHED.

.PARAMETER SymbolKind
  'builtin' - pick from the Built-in symbols tab (ticker without '@').
  'server'  - pick from the Server-side symbols tab (e.g. 'ETH-USDT').
  'none'    - do not touch the symbol.

.PARAMETER NewSymbol
  Symbol to select: 'BTC' for builtin, 'ETH-USDT' for server.

.PARAMETER Timeframe
  Builtin row timeframe to pick when the ticker exists in several ('1h').
  For server symbols it is the timeframe text of the combo ('1 hour').

.PARAMETER DryRun
  Apply the adjustment, print the read-back, close the Re-Run window, do not
  run anything.

.EXAMPLE
  powershell -File .\scripts\buildalpha_rerun_adjust.ps1 -Filter 'btc-trend-short' `
    -ExpectSymbol 'BTC' -SymbolKind builtin -NewSymbol 'BTC' -Timeframe '1h'

.EXAMPLE
  # validate only
  powershell -File .\scripts\buildalpha_rerun_adjust.ps1 -Filter 'btc-trend-short' `
    -ExpectSymbol 'BTC' -SymbolKind server -NewSymbol 'ETH-USDT' -DryRun

.OUTPUTS
  ADJUST field=symbol server=BTC-USDT_1h -> builtin:BTC_1h
  VERIFY builtin_count=(1)
  RESULT {"filter":..., "server_symbol":..., "builtin":..., "trades":..., "sharpe":...}
  DRY_RUN {...}       when -DryRun
#>
param(
  [Parameter(Mandatory = $true)][string]$Filter,
  [Parameter(Mandatory = $true)][string]$ExpectSymbol,
  [string]$ExpectName = '',
  [string]$Portfolio = '',
  [double]$ExpectedTrades = -1,
  [double]$ExpectedSharpe = -1,
  [double]$ExpectedPnl = -1,
  [ValidateSet('builtin', 'server', 'none')][string]$SymbolKind = 'none',
  [string]$NewSymbol = '',
  [string]$Timeframe = '',
  # Date window overrides. Format 'yyyy-MM-dd' (a time of day may be appended:
  # 'yyyy-MM-dd HH:mm:ss'). Applied to the Re-Run form's own Start/Stop fields and
  # verified by reading the form back; nothing is simulated if they do not stick.
  [string]$StartDate = '',
  [string]$StopDate = '',
  # Capture the trade list while the results window is open ('Show Trades'), writing a TSV
  # to -TradesOut and putting a pointer (not the rows) into RESULT.trades.
  [switch]$IncludeTrades,
  [string]$TradesOut = '',
  [string]$BuiltinSymbol = '',        # legacy alias for -SymbolKind builtin
  [switch]$DryRun,
  # Plan from strategy_cache.identify.plan(). When passed, the row is found by the shared
  # search (scripts/buildalpha_find_strategy.ps1) instead of the filter+scan block below.
  [string]$PlanFile = '',
  [string]$DumpFields = '',        # diagnostic: write the full form read to this path
  [switch]$ProbeOos,               # diagnostic: dump the OOS controls of the form
  [int]$RowTimeoutSec = 300,
  [int]$TimeoutSec = 240
)

$ErrorActionPreference = 'Stop'


# Phase timer: every section prints its own elapsed time, so a slow run says
# which step is slow instead of only how long the whole thing took.
$script:phaseSw = [System.Diagnostics.Stopwatch]::StartNew()
function Phase([string]$name) {
  $script:phaseSw.Stop()
  "PHASE {0} ms={1}" -f $name, $script:phaseSw.ElapsedMilliseconds
  $script:phaseSw.Restart()
}
. "$PSScriptRoot\buildalpha_uia.ps1"

# One GUI driver at a time (see Enter-UiLock): a second call must not interleave its clicks and
# filters with this one. A child of a lock holder inherits the flag and skips this.
$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }
Add-Type -AssemblyName System.Windows.Forms

if ($BuiltinSymbol) { $SymbolKind = 'builtin'; $NewSymbol = $BuiltinSymbol }
# exit 23 is its own status: an unhandled PowerShell exception also exits 1, and
# mapping that to NEW_SYMBOL_REQUIRED hid the real fault from the caller.
if ($SymbolKind -ne 'none' -and -not $NewSymbol) { 'NEW_SYMBOL_REQUIRED'; exit 23 }

Add-Type -Namespace RA -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
'@

$proc = Get-Process BuildAlpha_x64 | Select-Object -First 1
if (-not $proc) { 'NO_BUILDALPHA'; exit 2 }
$mainHwnd = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like 'Build Alpha*' } | Select-Object -First 1

function Close-StaleWindows {
  # Windows this call did not open: a results window left by earlier manual work, or a
  # Re-Run dialog from an aborted call. Closing them up front is what makes the end-of-run
  # check about THIS run instead of blocking because of someone else's window.
  #
  # A results window that is already stuck in 'Results window closing...' accepts neither
  # WM_CLOSE nor SC_CLOSE (measured), and while it is up it swallows the clicks the
  # portfolio switch needs. So: try, verify, and if it survives report it by name and
  # stop immediately - a fast, named failure instead of a puzzling
  # PORTFOLIO_SWITCH_FAILED two minutes later.
  $found = @()
  foreach ($h in (Get-VisibleWindows $proc.Id)) {
    $t = Get-WindowTitle $h
    if ($t -eq 'Re-Run' -or $t -like 'Re-Run results*' -or $t -like 'Results window closing*') {
      $found += [pscustomobject]@{ hwnd = $h; title = $t }
    }
  }
  if (-not $found.Count) { return @() }
  $left = @()
  foreach ($f in $found) {
    "closing stale window '$($f.title)'"
    # closes, and answers the modal "are you sure?" prompt if BuildAlpha raises one
    $r = Close-WindowChecked -hwnd $f.hwnd -ProcessId $proc.Id -Allowed @($mainHwnd)
    if (-not $r.closed) { $left += $f.title }
  }
  if ($left.Count) {
    # Stop-With is defined further down; exit here rather than depend on definition order
    "STALE_WINDOW window='$($left -join "', '")' (this call did not open it and BuildAlpha will not close it; close it by hand, then retry)"
    Write-Output ("WINDOWS " + (@(Get-ObservedWindows $proc.Id) | ConvertTo-Json -Compress))
    exit 27
  }
  return @($found | ForEach-Object { $_.title })
}

# ---------------------------------------------------------------- teardown trap
# A PowerShell finally does not run when the process is killed, and the MCP pre-flight
# covers that case; the trap covers everything else (an unhandled exception, Stop-With,
# Ctrl-C). It releases topmost on whatever windows this run touched and prints why.
function Clear-OwnTopmost {
  $wins = @(Get-VisibleWindows $proc.Id)
  Clear-Topmost -Windows $wins -Async
}
function Close-OwnWindows {
  # leave no half-configured dialog behind for the next call, and answer BuildAlpha's
  # "are you sure?" prompt if closing one raises it
  try {
    foreach ($h in (Get-VisibleWindows $proc.Id)) {
      $t = Get-WindowTitle $h
      if ($t -eq 'Re-Run' -or $t -like 'Re-Run results*' -or $t -like 'Results window closing*') {
        [void](Close-WindowChecked -hwnd $h -ProcessId $proc.Id -Allowed @($mainHwnd))
      }
    }
  } catch { }
}
trap {
  $msg = "$($_.Exception.Message)"
  try { Close-OwnWindows } catch { }
  try { Clear-OwnTopmost } catch { }
  if ($msg -match '^(FOREGROUND_HELD_BY_DIALOG|BA_DIALOG_NOT_OURS)') {
    "INPUT_BLOCKED $msg"
  } else {
    "SCRIPT_FAILED $msg"
  }
  # report what is actually on screen, so windows_cleaned reflects reality rather than
  # which branch ran (a failed run used to claim windows_cleaned:false after cleaning up)
  $observed = Get-ObservedWindows $proc.Id
  Write-Output ("WINDOWS " + (@($observed) | ConvertTo-Json -Compress))
  if ($msg -match '^(FOREGROUND_HELD_BY_DIALOG|BA_DIALOG_NOT_OURS)') { exit 25 }
  exit 1
}
# guard is armed with the BuildAlpha pid; windows this run opens are added as it goes
Set-InjectionGuard -ProcessId $proc.Id -Windows @($mainHwnd)

# Windows this call did not open (a results window left by manual work, a Re-Run dialog
# from an aborted call) must go BEFORE the portfolio switch, not after: a stray dialog
# steals the clicks the switch script needs, which is how a call failed with
# PORTFOLIO_SWITCH_FAILED and then blocked the next one with WINDOWS_LEFT_OPEN.
[void](Close-StaleWindows)

function Focus-Main {
  [void][RA.W]::ShowWindow($mainHwnd, 9)
  # Was SetWindowPos(HWND_TOPMOST, ...) here, never undone: the main window stayed above
  # every other program, including other applications' modal dialogs and Task Manager,
  # which made the desktop unusable after an unexpected confirmation dialog appeared.
  # Raising above its own dialogs is what BringWindowToTop is for; it does not affect
  # other processes. This now only *clears* topmost, so a leaked pin from an older run is
  # healed on the next one even if its process was killed before teardown could run.
  Clear-Topmost -Windows @($mainHwnd) -Async
  Set-AppForeground $mainHwnd   # guarded: refuses when a foreign window holds the foreground
  Start-Sleep -Milliseconds 700
}

function Get-Grid {
  $win = [System.Windows.Automation.AutomationElement]::FromHandle($mainHwnd)
  $grid = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
  if (-not $grid) { $grid = Get-DataGrid (Get-ElementAt 400 200) }
  return $grid
}

function Get-Picker {
  # A probe costs seconds of UIA work (the main window tree is large), so re-probing the
  # same unchanged window every pass is what turned "the popup never opened" into a
  # 228 s call. Probe each window at most twice - once when it appears, once a moment
  # later in case it is still being populated - and give the whole wait a hard deadline.
  $probed = @{}
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline) {
    foreach ($h in (Get-VisibleWindows $proc.Id)) {
      if ($h -eq $mainHwnd) { continue }
      $key = [int64]$h
      $seen = if ($probed.ContainsKey($key)) { $probed[$key] } else { 0 }
      if ($seen -ge 2) { continue }
      $t = Get-WindowTitle $h
      if ($t -eq 'Re-Run' -or $t -like 'Build Alpha*' -or $t -like 'Strategy Builder*' -or $t -like '*results*' -or $t -like '*closing*') { $probed[$key] = 2; continue }
      $r = Get-WindowRect $h
      if (($r.Right - $r.Left) -lt 200) { $probed[$key] = $seen + 1; continue }
      $probed[$key] = $seen + 1
      $w = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      if ($w -and $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
          (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_GridControl')))) { return $w }
    }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

function Invoke-Button($root, [string]$name) {
  $b = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
  if (-not $b) { return $false }
  $ip = $null
  if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); return $true }
  $r = $b.Current.BoundingRectangle
  Invoke-LeftClick ([int]($r.Left + $r.Width / 2)) ([int]($r.Top + $r.Height / 2))
  return $true
}

function Select-WindowTab($root, [string]$name) {
  $tab = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and $_.Current.Name -eq $name } | Select-Object -First 1
  if (-not $tab) { return $false }
  $sp = $null
  [void]$tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)
  $sp.Select()
  $tr = $tab.Current.BoundingRectangle
  Invoke-LeftClick ([int]($tr.Left + $tr.Width / 2)) ([int]($tr.Top + $tr.Height / 2))
  Start-Sleep -Milliseconds 900
  return $true
}

function AlmostEqual([string]$a, [string]$b, [double]$tolerance) {
  # missing values are not evidence against a match
  if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $true }
  $x = 0.0; $y = 0.0
  if (-not [double]::TryParse($a.Trim(), [ref]$x)) { return $true }
  if (-not [double]::TryParse($b.Trim(), [ref]$y)) { return $true }
  return ([math]::Abs($x - $y) -le $tolerance)
}

function Get-MetricDelta($before, $after) {
  # every metric the portfolio grid and the results row both expose
  $keys = @('Trades', 'Sharpe', 'Net P&L', 'Drawdown', 'Drawdown MTM', 'P&L / DD',
            'Win Percentage', 'Profit Factor', 'Ratio WL', 'CAGR', 'SQM', 'SQN',
            'T-Test', 'E-Ratio', 'K-Ratio', 'Expectancy Score', 'Avg Trade',
            'Mean W trades', 'Mean L trades', 'Std W trades', 'Std L trades',
            'Corr Coef', 'CPC Ratio', 'Perfect Profit Percentage',
            'Perfect Profit Correlation', 'Custom Fitness', 'Robust Index')
  $delta = [ordered]@{}
  foreach ($key in $keys) {
    $b = 0.0; $a = 0.0
    $btxt = ('' + $before[$key]).Trim()
    $atxt = ('' + $after[$key]).Trim()
    if ([double]::TryParse($btxt, [ref]$b) -and [double]::TryParse($atxt, [ref]$a)) {
      $delta[$key] = [math]::Round($a - $b, 4)
    }
  }
  return $delta
}

function Read-RerunForm {
  # In-process read (UI Automation is already loaded here). The nested
  # buildalpha_form_reader.ps1 costs ~10 s per run - a second PowerShell plus a full
  # re-walk of the form - purely to verify values we can read directly. Reliability
  # is unchanged: same reader function, same tab walk; the subprocess stays as a
  # fallback when the in-process pass returns nothing usable.
  $fields = InProcess-RerunFields
  if ($fields -and $fields.Count -ge 3 -and $fields.ContainsKey('Start Date')) {
    # stderr, not stdout: anything written to the output stream would become part of
    # this function's return value and corrupt the field map
    [Console]::Error.WriteLine("form-read inprocess fields=$($fields.Count)")
    return $fields
  }
  $keys = if ($fields) { ($fields.Keys | Select-Object -First 6) -join ',' } else { '(null)' }
  [Console]::Error.WriteLine("form-read fallback inprocess_fields=$(if ($fields) { $fields.Count } else { 0 }) keys=$keys")
  $tmp = Join-Path $env:TEMP ("rerun_form_" + [guid]::NewGuid().ToString('N') + ".txt")
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\buildalpha_form_reader.ps1" -Title 'Re-Run' -OutFile $tmp 2>&1 | Out-Null
  $fields = @{}
  if (Test-Path $tmp) {
    foreach ($line in (Get-Content $tmp)) {
      $parts = $line -split "`t"
      if ($parts.Count -ge 2 -and $parts[0] -notmatch '^(RULE|#|==)') { $fields[$parts[0]] = $parts[1] }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
  return $fields
}

function Set-FormDate($root, [string]$label, [string]$value) {
  # Dates only - no time of day. Accepts 'yyyy-MM-dd', 'yyyy/MM/dd', 'M/d/yyyy' (and
  # anything .NET can parse); writes the form's canonical 'M/d/yyyy' and compares
  # DATES, never raw strings, because the form re-renders with a time component
  # (e.g. '10/22/2026 11:59:59 PM') and may normalise the day.
  $pane = ($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object {
      $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Pane -and
      $_.Current.ClassName -eq 'LayoutItem' -and
      (($_.Current.Name -replace '\s+', ' ').Trim() -eq $label) }) | Select-Object -First 1
  if (-not $pane) { return @{ Ok = $false; Value = ''; Why = 'PANE_NOT_FOUND' } }
  $edit = $pane.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
  if (-not $edit) { return @{ Ok = $false; Value = ''; Why = 'EDIT_NOT_FOUND' } }
  $vp = $null
  if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
    return @{ Ok = $false; Value = ''; Why = 'NO_VALUEPATTERN' }
  }

  # parse the requested date, then send it in the form's own notation
  $target = [datetime]::MinValue
  if (-not [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$target)) {
    return @{ Ok = $false; Value = ''; Why = "UNPARSEABLE_DATE '$value'" }
  }
  $send = $target.ToString('M/d/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)

  $before = $vp.Current.Value
  $vp.SetValue($send)
  Start-Sleep -Milliseconds 400
  Send-Keys '{TAB}' 'date-commit'   # commit by focus change, NOT Enter
  Start-Sleep -Milliseconds 600
  $now = $vp.Current.Value
  if (-not (Test-DateMatches $now $target)) {
    # try once more with an explicit focus then tab
    $edit.SetFocus()
    Start-Sleep -Milliseconds 300
    $vp.SetValue($send)
    Start-Sleep -Milliseconds 400
    Send-Keys '{TAB}' 'date-commit-retry'
    Start-Sleep -Milliseconds 600
    $now = $vp.Current.Value
  }
  $ok = Test-DateMatches $now $target
  return @{ Ok = $ok; Value = $now; Target = $send; Why = $(if ($ok) { '' } else { 'DATE_MISMATCH' }) }
}

function Test-DateMatches([string]$formValue, [datetime]$target) {
  # compare the calendar date only: the form re-renders with a time component and
  # may snap the time to 00:00:00 or 23:59:59 depending on the field
  $parsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($formValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $false }
  return ($parsed.Date -eq $target.Date)
}


function InProcess-RerunFields {
  $regex = [regex]'(?m)^Re-Run$'
  $win = $null
  foreach ($h in (Get-VisibleWindows $proc.Id)) {
    if ((Get-WindowTitle $h) -eq 'Re-Run') { $win = [System.Windows.Automation.AutomationElement]::FromHandle($h); break }
  }
  if (-not $win) { return $null }
  $map = @{}
  $tabs = @(Get-FormTabs $win)
  if ($tabs.Count -eq 0) { $tabs = @($null) }
  foreach ($tab in $tabs) {
    if ($tab) { Select-FormTab $tab }
    foreach ($f in @(Read-FormFields $win)) {
      if ($f.Label) { $map[$f.Label] = $f.Value }
    }
  }
  return $map
}

function Get-ElementTop($el) {
  # Virtualised/offscreen rows report NaN or an infinite bounding rect. Casting that
  # to [int] throws ('Cannot convert value "∞" ...'), which used to abort the picker
  # scan and then surface as the wrong status. Return $null instead and let callers
  # skip the row.
  if (-not $el) { return $null }
  $top = $el.Current.BoundingRectangle.Top
  if ([double]::IsNaN($top) -or [double]::IsInfinity($top)) { return $null }
  return [int]$top
}
function Get-FormSymbolCount($win) {
  # The Re-Run form shows its chosen symbols as "(N)" on two selectors. Measured 2026-11-03: the
  # form can open with (0) on both and "(none)" on the drawn Symbols line, and BuildAlpha then
  # refuses to run - "No symbols chosen for simulation!" - a modal that used to hang the whole call.
  # Returns a map id -> count (-1 when the selector is not on the visible tab).
  $out = [ordered]@{}
  foreach ($id in 'mainBuildinSymbolsSelector', 'mainServerSymbolsSelector') {
    $sel = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)))
    if (-not $sel) { $out[$id] = -1; continue }
    $item = $sel.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_Item')))
    $n = 0
    if ($item -and ("$($item.Current.Name)" -match '\((\d+)\)')) { $n = [int]$Matches[1] }
    $out[$id] = $n
  }
  return $out
}

function Open-AdjustForm {
  # menu -> 'Run strategy with adjustments' -> wait for the form. One place, so the restore path
  # below can simply open it again instead of re-implementing the click.
  foreach ($h in (Get-VisibleWindows $proc.Id)) {
    if ((Get-WindowTitle $h) -eq 'Re-Run') {
      "closing stale Re-Run window"
      [void](Close-WindowChecked -hwnd $h -ProcessId $proc.Id -Allowed @($mainHwnd))
    }
  }
  $prevEapOpen = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $menuOut = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\buildalpha_rerun.ps1" `
    -RowY $rowY -RowX $rowX -KeepFilter -ExpectSymbol $ExpectSymbol -Target 'adjust' 2>&1 | Out-String
  $ErrorActionPreference = $prevEapOpen
  # Keep the child's narration: a bare "the window is missing" hid the real reason three times in a
  # row (a blocked keystroke, a menu that opened but could not be identified, a wrong row).
  $script:menuOut = "$menuOut"
  if ($script:menuOut -notmatch 'DONE: activated') { return [IntPtr]::Zero }
  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 500
    $cand = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Re-Run' } | Select-Object -First 1
    if ($cand) { $hwnd = $cand }
  }
  return $hwnd
}

function Clear-SymbolModal {
  # If BuildAlpha put up "No symbols chosen for simulation!", dismiss it so the desktop is not left
  # behind a modal, and report that it was there.
  foreach ($h in (Get-VisibleWindows $proc.Id)) {
    $t = Get-WindowTitle $h
    if ($t -like '*No symbols chosen*') {
      $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $ok = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.AndCondition(
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)),
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'OK')))))
      if ($ok) { Invoke-Button $el 'OK' | Out-Null } else { Send-Escape }
      return $true
    }
  }
  return $false
}

function Stop-With([string]$message, [int]$code) {
  # every failure after the Re-Run window exists must close it, otherwise the
  # next run types its filter into that window instead of the grid
  foreach ($h in (Get-VisibleWindows $proc.Id)) {
    $t = Get-WindowTitle $h
    if ($t -eq 'Re-Run' -or $t -eq '' -or $t -like 'Re-Run results*' -or $t -like 'Results window closing*') { [void](Close-WindowChecked -hwnd $h -ProcessId $proc.Id -Allowed @($mainHwnd)) }
  }
  # give a closing results window time to actually disappear, otherwise it is reported as
  # left open purely because it was still fading out when we looked
  for ($i = 0; $i -lt 8; $i++) {
    $still = @(Get-VisibleWindows $proc.Id | ForEach-Object { Get-WindowTitle $_ } |
      Where-Object { $_ -eq 'Re-Run' -or $_ -like 'Re-Run results*' -or $_ -like 'Results window closing*' })
    if (-not $still.Count) { break }
    Start-Sleep -Milliseconds 400
  }
  Write-Output $message
  # report the windows actually on screen, not which code path cleaned up
  $observed = Get-ObservedWindows $proc.Id
  Write-Output ("WINDOWS " + (@($observed) | ConvertTo-Json -Compress))
  $left = @($observed | Where-Object { $_ -eq 'Re-Run' -or $_ -like 'Re-Run results*' -or $_ -like 'Results window closing*' })
  if ($left.Count -eq 0) { Write-Output 'CLEANED_UP' } else { Write-Output "WINDOWS_LEFT_OPEN count=$($left.Count)" }
  exit $code
}

# ---------------------------------------------------------------- 0. portfolio
# Note: a "remember the last portfolio" shortcut was tried here and removed - it saved
# ~3 s but a stale hint (someone switched portfolio manually, or an earlier run left
# the selector elsewhere) made the filter find zero rows. Asking is slower but it
# cannot be wrong, so this stays authoritative.
if ($Portfolio) {
  # In-process, and it reads before it acts: one dropdown open (~1.2 s measured) tells us what is
  # loaded, and if that is already the wanted portfolio nothing is clicked. The child-process
  # version cost 3-8 s for the same answer (spawn + the switch script's click-and-verify-again).
  $ens = Set-PortfolioVerified -Name $Portfolio
  if (-not $ens.Ok) { Stop-With "PORTFOLIO_SWITCH_FAILED $Portfolio -> $($ens.Reason)" 5 }
  if ($ens.Switched) { "portfolio: switched to $($ens.Read)" } else { "portfolio: already on $($ens.Read)" }
}

Phase 'portfolio'
# ---------------------------------------------------------------- 1. the row
# Two ways to reach it, and only one of them should survive:
#   -PlanFile  -> the shared search (Net P&L first, metric verification, click, proven selection).
#                 This is what the MCP tool passes; everything that used to happen here (filter
#                 text, debounce poll, cell scan, tolerance comparison, ExpectSymbol/ExpectName)
#                 now lives in scripts/buildalpha_find_strategy.ps1.
#   no plan    -> the original filter+scan, kept for a caller with no cache to plan from.
function Get-CellAt($gp, [int]$r, [int]$c) {
  $cell = $null
  try { $cell = $gp.GetItem($r, $c) } catch { return $null }
  return $cell
}

function Read-RowCells($gp, [int]$r, [int]$from, [int]$to) {
  $cellsRow = [ordered]@{}
  $top = 0
  for ($c = $from; $c -lt $to; $c++) {
    $cell = $null
    try { $cell = $gp.GetItem($r, $c) } catch { continue }
    if (-not $cell) { continue }
    if ($cell.Current.Name -match 'Column (.*?), Column \d+ of \d+: (.*)$') {
      $col = $Matches[1]
      if ($col -in @('ECurve', 'X')) { continue }
      $cellsRow[$col] = $Matches[2]
      if ($col -eq 'Name') {
        $t = Get-ElementTop $cell
        if ($null -ne $t) { $top = $t }
      }
    }
  }
  return @{ Cells = $cellsRow; Top = $top }
}

$baseline = [ordered]@{}
$rowY = 0
$rowX = 0
$script:menuOut = ''
$picked = -1
$pickedName = ''
$serverSymbol = ''

if ($PlanFile) {
  # The child narrates on stderr, and a native command's stderr arrives as an error record:
  # under $ErrorActionPreference = 'Stop' the first STAGE line would kill this script.
  $prevEapSearch = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # Bounded: a blocked UI Automation call inside the search must not hold this script forever.
  $searchRun = Invoke-ScriptBounded -Script (Join-Path $PSScriptRoot 'buildalpha_find_strategy.ps1') `
    -Arguments @('-PlanFile', $PlanFile, '-SkipPortfolio') -TimeoutSec 120
  $ErrorActionPreference = $prevEapSearch
  $findLine = @("$($searchRun.Output)" -split "`r?`n") |
    Where-Object { $_ -match 'FIND \{' } | Select-Object -Last 1
  if (-not $findLine) {
    "SEARCH_FAILED $("$($searchRun.Output)".Trim())"
    exit 6
  }
  $find = ($findLine -replace '^.*?FIND \{', '{') | ConvertFrom-Json
  if ($find.status -ne 'OK') {
    # A refusal is an answer: the search never guesses, and neither does this script.
    # Report the search's own status. Flattening them all into ROW_NOT_FOUND made a selection
    # failure, an ambiguity and a stale-cache mismatch look identical to the caller.
    "$($find.status): $($find.detail)"
    switch ("$($find.status)") {
      'AMBIGUOUS'        { exit 20 }
      'IDENTITY_MISMATCH' { exit 20 }
      'SELECTION_FAILED' { exit 27 }
      'GRID_NOT_VISIBLE' { exit 30 }
      'PORTFOLIO_SWITCH_FAILED' { exit 5 }
      'INPUT_BLOCKED'    { exit 25 }
      default            { exit 6 }
    }
  }
  $picked = [int]$find.row_index
  $rowY = [int]$find.row_rect.y + [int]([double]$find.row_rect.height / 2)
  $rowX = [int]([double]$find.row_rect.x + [double]$find.row_rect.width / 2)
  $pickedName = "$($find.row_name)"
  $serverSymbol = "$($find.row_symbol)"
  "row ${picked}: symbol='$serverSymbol' name='$($pickedName.Substring(0, [Math]::Min(70, $pickedName.Length)))'"

  # The re-run comparison needs the row as it stands before the change: read its own cells at the
  # row the search proved, the same way the legacy block below reads them.
  $grid = Get-Grid
  if (-not $grid) { 'GRID_MISSING'; exit 3 }
  $gp = $null
  [void]$grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)
  if (-not $gp) { 'GRID_MISSING'; exit 3 }
  # Prefer the cells the search verified. Re-reading the row by its position afterwards was
  # measured landing on a different row (the grid re-sorts while the filter settles): a consumer
  # saw trades 182 where the search had verified 179, and reported it as IDENTITY_MISMATCH.
  if ($find.row_cells) {
    $baseline = [ordered]@{}
    foreach ($prop in $find.row_cells.PSObject.Properties) { $baseline[$prop.Name] = "$($prop.Value)" }
  }
  if (-not $baseline['Trades']) {
    $tail = Read-RowCells $gp $picked 0 40
    $baseline = $tail.Cells
    if ($rowY -le 0 -and $tail.Top) { $rowY = $tail.Top }
  }
} else {
  # ---------------------------------------------------------------- 1. filter row
  Focus-Main
  Invoke-LeftClick 400 200
  Start-Sleep -Milliseconds 300
  Send-Keys '^f' 'grid-filter'
  Start-Sleep -Milliseconds 600
  Send-Keys $Filter 'grid-filter-text'
  Start-Sleep -Milliseconds 400
  Send-Keys '{ENTER}' 'grid-filter-apply'

  $grid = Get-Grid
  if (-not $grid) { 'GRID_MISSING'; exit 3 }
  $gp = $null
  [void]$grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)
  # The find panel filters ~1.2 s after the last keystroke: poll for the row count to
  # change instead of sleeping a fixed 2 s (faster in the common case, and no longer
  # wrong when the filter needs longer).
  $rowsSeen = $gp.Current.RowCount
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 200
    $now = $gp.Current.RowCount
    if ($now -lt $rowsSeen) { $rowsSeen = $now; if ($now -le 5) { break } }
  }
  "filter '$Filter' -> $($gp.Current.RowCount) row(s)"
  if ($gp.Current.RowCount -lt 1) { 'FILTER_EMPTY'; exit 4 }

  # GridPattern.GetItem is the only way to see this grid's cells: they are not in the
  # control-view tree (a FindAll snapshot returns none). Symbol and Name are the only
  # columns needed to *identify* a row, so read those two first (their indexes are
  # verified by the returned column names, with a full scan as fallback) and read the
  # rest of the row only once it matches.
  $SYMBOL_COL = 1
  $NAME_COL = 5
  $KEY_COLUMNS = 8

  $rowCount = $gp.Current.RowCount
  $pickedName = ''
  for ($r = 0; $r -lt $rowCount; $r++) {
    # identity first: two cells, not eight
    $symCell = Get-CellAt $gp $r $SYMBOL_COL
    $nmCell = Get-CellAt $gp $r $NAME_COL
    $fastOk = ($symCell -and $nmCell -and
               $symCell.Current.Name -match 'Column Symbol, ' -and
               $nmCell.Current.Name -match 'Column Name, ')
    if ($fastOk) {
      $sym = ($symCell.Current.Name -split ': ', 2)[1]
      $nm = ($nmCell.Current.Name -split ': ', 2)[1]
      if ($ExpectSymbol -and ($sym -notlike "$ExpectSymbol*")) { continue }
      if ($ExpectName -and ($nm.Trim() -ne $ExpectName.Trim())) { continue }
      $cellsRow = [ordered]@{ Symbol = $sym; Name = $nm }
      $head = @{ Top = (Get-ElementTop $nmCell) }
    } else {
      # unexpected layout: fall back to scanning the key columns for the mapping
      $head = Read-RowCells $gp $r 0 $KEY_COLUMNS
      $cellsRow = $head.Cells
      if (-not $cellsRow.Count) { continue }
      $sym = "$($cellsRow['Symbol'])"
      $nm = "$($cellsRow['Name'])"
      if ($ExpectSymbol -and ($sym -notlike "$ExpectSymbol*")) { continue }
      if ($ExpectName -and ($nm.Trim() -ne $ExpectName.Trim())) { continue }
    }
    # matched: now read the rest of the row for the baseline picture
    $tail = Read-RowCells $gp $r 0 40
    foreach ($k in $tail.Cells.Keys) { $cellsRow[$k] = $tail.Cells[$k] }
    $picked = $r
    $baseline = $cellsRow
    $rowY = if ($head.Top) { $head.Top } else { $tail.Top }
    $pickedName = $nm
    break
  }
}

if ($picked -lt 0) {
  "ROW_NOT_FOUND symbol=$ExpectSymbol name=$ExpectName rows=$rowCount"
  exit 6
}
$serverSymbol = "$($baseline['Symbol'])"
"row $picked/$($rowCount-1): symbol='$serverSymbol' name='$($pickedName.Substring(0,[Math]::Min(70,$pickedName.Length)))'"
if ($rowY -le 0) {
  # A grid that publishes no cells gives the search no rectangle: it reads the rows from the
  # application's own copy and selects the proven row with the keyboard instead, reporting
  # selection_how 'keyboard' and row_rect null. buildalpha_rerun.ps1 has a keyboard path for that
  # (focus the grid, Shift+F10 - the menu OCRs the same as a right-click). Refusing here made every
  # such re-run die with ROW_NOT_ON_SCREEN before it started; the caller saw WRONG_ROW and no trades.
  $provenKeyboard = ($PlanFile -and $find -and "$($find.selection_how)" -eq 'keyboard')
  if (-not $provenKeyboard) { 'ROW_NOT_ON_SCREEN (scroll it into view first)'; exit 6 }
  $rowY = 0
  $rowX = 0
  'row location: none published by the grid; the row was selected by keyboard - asking for its menu with Shift+F10'
}

# identity: the row's own metrics must be the ones the cache predicted
if ($ExpectedTrades -ge 0 -and -not (AlmostEqual "$($baseline['Trades'])" "$ExpectedTrades" 0.5)) {
  Stop-With "IDENTITY_MISMATCH trades expected=$ExpectedTrades actual=$($baseline['Trades'])" 20
}
if ($ExpectedSharpe -ge 0 -and -not (AlmostEqual "$($baseline['Sharpe'])" "$ExpectedSharpe" 0.02)) {
  Stop-With "IDENTITY_MISMATCH sharpe expected=$ExpectedSharpe actual=$($baseline['Sharpe'])" 20
}
if ($ExpectedPnl -ge 0 -and -not (AlmostEqual "$($baseline['Net P&L'])" "$ExpectedPnl" 0.5)) {
  Stop-With "IDENTITY_MISMATCH net_pnl expected=$ExpectedPnl actual=$($baseline['Net P&L'])" 20
}
# the grid row is the 'before' picture; hand it back so callers do not have to
# look it up in the cache just to compare
'BASELINE ' + ($baseline | ConvertTo-Json -Compress)

Phase 'filter+row'
# ------------------------------------------------- 2. run with adjustments
# A Re-Run window left behind by an aborted run would be mistaken for the new one
# (the wait below matches any 'Re-Run' window), so close strays first.
foreach ($h in (Get-VisibleWindows $proc.Id)) {
  if ((Get-WindowTitle $h) -eq 'Re-Run') { "closing stale Re-Run window"; [void](Close-WindowChecked -hwnd $h -ProcessId $proc.Id -Allowed @($mainHwnd)) }
}
# Open the form through the one helper, so the restore path can open it again the same way.
$rerunHwnd = Open-AdjustForm
if ($rerunHwnd -eq [IntPtr]::Zero) {
  # Say what the menu step actually hit. INPUT_BLOCKED here is not a missing window: the desktop is
  # locked or another window owns the foreground, so no keystroke reached Build Alpha at all.
  $why = @("$($script:menuOut)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
  if ("$($script:menuOut)" -match 'INPUT_BLOCKED') { Stop-With "INPUT_BLOCKED opening the row menu: $why" 25 }
  if ("$($script:menuOut)" -match 'Wrong row') { Stop-With "WRONG_ROW opening the row menu: $why" 6 }
  'RERUN_WINDOW_MISSING'
  "menu step: $why"
  exit 8
}
[void][RA.W]::SetWindowPos($rerunHwnd, [IntPtr]0, 60, 40, 1000, 780, 0x40)
Add-InjectionWindow $rerunHwnd
# guarded wrapper: the check runs immediately before the focus change, not once per run
Set-AppForeground $rerunHwnd
Start-Sleep -Milliseconds 800
$rerun = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)

Phase 'open-rerun'
# The form can open with no symbols at all - measured 2026-11-03: (0) on both selectors and
# "(none)" on the drawn Symbols line, and it does the same when the operator opens it by hand, so
# it is the strategy's state, not this script's doing. BuildAlpha then refuses to run
# ("No symbols chosen for simulation!"), which used to hang the call behind a modal.
#
# So: if the caller asked for no symbol change, put the strategy's OWN symbol back through the
# picker that is already proven below. The grid names the symbol 'LTC_1h' - instrument, then
# timeframe - and the picker wants the instrument alone ('LTC') plus the timeframe row ('1h').
$symbolCounts = Get-FormSymbolCount $rerun
$haveSymbols = (($symbolCounts.Values | Where-Object { $_ -gt 0 }).Count -gt 0)
"form symbols: " + (($symbolCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
if (-not $haveSymbols -and $SymbolKind -eq 'none') {
  $ownBase = ($serverSymbol -split '_')[0]
  $ownTf = if ($serverSymbol -match '_(\d+[mhd])$') { $Matches[1] } else { '' }
  if (-not $ownBase) {
    Stop-With ("SYMBOLS_MISSING the form opened with no symbols and the row's symbol is empty, " +
      "so there is nothing to restore; nothing was simulated") 28
  }
  $NewSymbol = $ownBase
  if ($ownTf) { $Timeframe = $ownTf }
  # Which list holds it is not knowable from the grid: 'LTC_1h' is a BUILT-IN symbol, while
  # 'HYPE-USDT_1h' is a server-side one, and both wear the same shape. So try both - built-in
  # first (measured: this was the wrong guess with a server-first heuristic) - and let the picker
  # decide. $SymbolKind stays 'builtin'/'server' for one attempt at a time.
  $script:restoreKinds = @('builtin', 'server')
  $script:restoringOwn = $true
  $SymbolKind = 'builtin'
  "symbol: the form opened with none; restoring the strategy's own '$NewSymbol' (timeframe '$Timeframe') - trying the built-in list first"
}

# ------------------------------------------------------- 3. apply the symbol
$applied = 'none'
if ($SymbolKind -ne 'none') {
  $symbolApplied = $false
  while (-not $symbolApplied) {
   $symbolApplied = $true
  $tabName = if ($SymbolKind -eq 'builtin') { 'Built-in symbols' } else { 'Server-side symbols' }
  $selectorId = if ($SymbolKind -eq 'builtin') { 'mainBuildinSymbolsSelector' } else { 'mainServerSymbolsSelector' }
  # If the dialog reopened on the right tab, the selector is already present: confirm
  # that (~0.5 s) instead of switching tabs unconditionally (~2.3 s).
  # Note: skipping the tab switch when the selector looked present was tried here and
  # removed - the dialog then sometimes did not open its picker at all, and the popup
  # probe (a cross-process UIA call) blocked instead of timing out. Switching
  # unconditionally is ~2 s but always leaves the tab in a known state.
  if (-not (Select-WindowTab $rerun $tabName)) { Stop-With "TAB_MISSING $tabName" 9 }
  Phase 'p-tab'

  $els = $rerun.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $sel = $els | Where-Object { $_.Current.AutomationId -eq $selectorId } | Select-Object -First 1
  if (-not $sel) { Stop-With "SELECTOR_MISSING $selectorId" 10 }
  Phase 'p-selector'
  $sr = $sel.Current.BoundingRectangle
  Invoke-LeftClick ([int]($sr.Left + 20)) ([int]($sr.Top + 10))
  Start-Sleep -Milliseconds 300

  # poll for the dropdown; Get-Picker has its own deadline now
  $popup = Get-Picker
  if (-not $popup) { Stop-With "PICKER_NOT_OPENED selector='$selectorId' (no popup window appeared within 12 s; the click did not open the list)" 11 }
  # register the popup: it is a separate top-level window, and the input guard only types
  # into windows this run registered
  $popupHwnd = [IntPtr]$popup.Current.NativeWindowHandle
  Add-InjectionWindow $popupHwnd
  Phase 'p-popup'
  $cells = { $script:pickerWalks++; $popup.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
  $script:pickerWalks = 0
  $combo = $popup.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchComboBox')))
  $find = $popup.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchFindButton')))
  $vp = $null; [void]$combo.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)
  $query = if ($SymbolKind -eq 'builtin') { ($NewSymbol -split '[-_]')[0] } else { $NewSymbol }
  $vp.SetValue($query); Start-Sleep -Milliseconds 300
  Invoke-Button $popup 'Find' | Out-Null
  # poll for a result row rather than sleeping a flat 2 s
  $rowPattern = "Column Name, Column \d+ of \d+: $([regex]::Escape($NewSymbol))`$"
  for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 200
    if ((& $cells) | Where-Object { $_.Current.Name -match $rowPattern }) { break }
  }

  $found = $false
  Phase 'p-find'
  $groups = @('Crypto', 'Futures', 'ETF', 'FOREX', 'Custom')
  foreach ($g in $groups) {
    if ((& $cells) | Where-Object { $_.Current.Name -match $rowPattern }) { $found = $true; break }
    $grow = (& $cells) | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $_.Current.Name -eq $g } | Select-Object -First 1
    if (-not $grow) { continue }
    $gTop = Get-ElementTop $grow
    $toggle = (& $cells) | Where-Object { $_.Current.AutomationId -eq 'PART_ToggleButton' -and (Get-ElementTop $_) -ne $null -and [math]::Abs((Get-ElementTop $_) - $gTop) -le 4 } | Select-Object -First 1
    if ($toggle) {
      $tb = $toggle.Current.BoundingRectangle
      if ([double]::IsInfinity($tb.Left) -or [double]::IsInfinity($tb.Top) -or $tb.Left -lt -1000) { continue }
      Invoke-LeftClick ([int]($tb.Left + $tb.Width / 2)) ([int]($tb.Top + $tb.Height / 2))
    } else {
      # A virtualised row reports an infinite rect; [int] on that throws
      # "Cannot convert value "i" to type System.Int32" (that "i" is mojibake for
      # infinity). Read the row as absent instead of computing a point from it.
      $gr = $grow.Current.BoundingRectangle
      if ([double]::IsInfinity($gr.Left) -or $gr.Left -lt -1000 -or $null -eq $gTop) {
        "picker: group '$g' has no usable geometry, skipped"
        continue
      }
      Invoke-LeftClick ([int]($gr.Left - 33)) ([int]($gTop + 8))
    }
    # poll for the group's rows to materialise (was: two fixed 2 s sleeps)
    for ($i = 0; $i -lt 15; $i++) {
      Start-Sleep -Milliseconds 200
      if ((& $cells) | Where-Object { $_.Current.Name -match $rowPattern }) { break }
    }
    Invoke-Button $popup 'Find' | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 200
      if ((& $cells) | Where-Object { $_.Current.Name -match $rowPattern }) { $found = $true; break }
    }
    if ($found) { break }
  }
  if (-not $found) {
    Send-Escape
    if ($script:restoringOwn -and $script:restoreKinds.Count -gt 1) {
      # try the other list before giving up
      $script:restoreKinds = @($script:restoreKinds | Where-Object { $_ -ne $SymbolKind })
      $SymbolKind = $script:restoreKinds[0]
      $symbolApplied = $false          # re-enter the attempt loop with the other list
      $whichList = if ($script:restoreKinds.Count -eq 1) { 'last' } else { 'first' }
      "symbol: '$NewSymbol' is not in the $whichList list tried; retrying as $SymbolKind"
      Send-Escape
      continue
    }
    Stop-With "SYMBOL_NOT_FOUND $NewSymbol (kind $SymbolKind)" 12
  }

  $target = (& $cells) | Where-Object { $_.Current.Name -match $rowPattern } | Select-Object -First 1
  $targetY = -1
  # choose the row whose TF matches when the timeframe is given
  try {
    foreach ($cand in ((& $cells) | Where-Object { $_.Current.Name -match $rowPattern })) {
      $y = Get-ElementTop $cand
      if ($null -eq $y) { continue }
      $tfRow = (& $cells) | Where-Object { $_.Current.Name -match 'Column TF, Column \d+ of \d+: ' -and (Get-ElementTop $_) -ne $null -and [math]::Abs((Get-ElementTop $_) - $y) -le 3 } | Select-Object -First 1
      if (-not $Timeframe -or (-not $tfRow) -or ($tfRow.Current.Name -match "Column TF, Column \d+ of \d+: $([regex]::Escape($Timeframe))`$")) { $targetY = $y; break }
    }
  } catch {
    Send-Escape
    Stop-With "FORM_READ_FAILED picker scan: $($_.Exception.Message)" 22
  }
  if ($targetY -lt 0) { Send-Escape; Stop-With "TIMEFRAME_NOT_FOUND $NewSymbol $Timeframe" 13 }

  $selCell = (& $cells) | Where-Object { $_.Current.Name -match 'Column Selection, Column \d+ of \d+: ' -and (Get-ElementTop $_) -ne $null -and [math]::Abs((Get-ElementTop $_) - $targetY) -le 3 } | Select-Object -First 1
  if (-not $selCell) { Send-Escape; Stop-With 'SELECTION_CELL_MISSING' 14 }
  if ($selCell.Current.Name -match 'Unchecked') {
    # Tick the row's OWN checkbox element, not a point computed from a row Top: the
    # grid re-materialises rows, and a coordinate click can land on the neighbouring
    # row (builtin:XRP once ticked IXRP that way while the name regex had matched XRP).
    $toggled = $false
    $box = $selCell.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::CheckBox)))
    foreach ($el in @($box, $selCell)) {
      if (-not $el -or $toggled) { continue }
      $tp = $null
      if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp) -and $tp) {
        $tp.Toggle()
        $toggled = $true
        "picker: toggled '$($selCell.Current.Name)' via UIA TogglePattern"
      }
    }
    if (-not $toggled) {
      $anchor = if ($box) { $box } else { $selCell }
      $c = $anchor.Current.BoundingRectangle
      Invoke-LeftClick ([int]($c.Left + $c.Width / 2)) ([int]($c.Top + $c.Height / 2))
      "picker: toggled via click (no TogglePattern)"
    }
    Start-Sleep -Milliseconds 900
    $selCell = (& $cells) | Where-Object { $_.Current.Name -match 'Column Selection, Column \d+ of \d+: ' -and (Get-ElementTop $_) -ne $null -and [math]::Abs((Get-ElementTop $_) - $targetY) -le 3 } | Select-Object -First 1
  }
  if ($selCell.Current.Name -notmatch 'Checked') { Send-Escape; Stop-With 'SELECTION_DID_NOT_STICK' 15 }
  # The ticked row must be the row we meant: report what the picker selected so an
  # adjacency mistake can never pass as success.
  $selName = ((& $cells) | Where-Object { $_.Current.Name -match 'Column Name, Column \d+ of \d+: ' -and (Get-ElementTop $_) -ne $null -and [math]::Abs((Get-ElementTop $_) - $targetY) -le 3 } | Select-Object -First 1)
  $selectedName = if ($selName) { ($selName.Current.Name -split ': ', 2)[1] } else { '' }
  "picker: target='$NewSymbol' row_under_selection='$selectedName'"
  Phase 'p-select'
  # Note: polling for the picker window to close was tried here and removed - the
  # probe itself is a slow cross-process UIA call (~2 s), so polling cost 10 s where
  # the flat sleep cost 1.5 s.
  Invoke-Button $popup 'OK' | Out-Null
  Start-Sleep -Milliseconds 1500
  Phase 'p-ok'
  [Console]::Error.WriteLine("picker cell walks=$script:pickerWalks")
  $applied = if ($SymbolKind -eq 'builtin') { "builtin:$NewSymbol" } else { "server:$NewSymbol" }
   if ($script:restoringOwn) { "symbol: restored '$NewSymbol' from the $SymbolKind list" }
   break
  }
}

Phase 'symbol'
# ----------------------------------------------------- 3b. date window
$dateResults = @{}
if ($StartDate -or $StopDate) {
  $rerunEl = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
  if ($StartDate) {
    $r = Set-FormDate $rerunEl 'Start Date' $StartDate
    $dateResults['Start Date'] = $r
    "ADJUST field=start target='$StartDate' now='$($r.Value)' sent='$($r.Target)' ok=$($r.Ok) $($r.Why)"
    if (-not $r.Ok) { Stop-With "DATE_NOT_APPLIED start target='$StartDate' now='$($r.Value)'" 21 }
  }
  if ($StopDate) {
    $r = Set-FormDate $rerunEl 'Stop Date' $StopDate
    $dateResults['Stop Date'] = $r
    "ADJUST field=stop target='$StopDate' now='$($r.Value)' sent='$($r.Target)' ok=$($r.Ok) $($r.Why)"
    if (-not $r.Ok) { Stop-With "DATE_NOT_APPLIED stop target='$StopDate' now='$($r.Value)'" 21 }
  }
}

Phase 'dates'
# ----------------------------------------------------- 4. read the form back
$rerun = [System.Windows.Automation.AutomationElement]::FromHandle($rerunHwnd)
$kindLabel = if ($SymbolKind -eq 'builtin') { 'builtin' } else { 'server' }
$selectorId = if ($SymbolKind -eq 'builtin') { 'mainBuildinSymbolsSelector' } else { 'mainServerSymbolsSelector' }
$countText = ''
if ($SymbolKind -ne 'none') {
  $sel = ($rerun.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.AutomationId -eq $selectorId }) | Select-Object -First 1
  if ($sel) {
    $item = $sel.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_Item')))
    if ($item) { $countText = $item.Current.Name }
  }
}
$fields = Read-RerunForm
$oos = Get-OosSplit $fields
# Diagnostic: the whole form read, so a field that never reaches the caller can be named
# from evidence instead of guessed. Off unless -DumpFields is given.
if ($DumpFields) {
  $keys = @($fields.Keys)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Re-Run form read: $($keys.Count) fields")
  foreach ($k in $keys) { $lines.Add(("{0}`t{1}" -f $k, $fields[$k])) }
  $lines | Out-File -Encoding utf8 $DumpFields
  [Console]::Error.WriteLine("form-dump fields=$($keys.Count) -> $DumpFields")
}
if ($ProbeOos) {
  # Evidence for TS-BUILD-53: what the OOS area of the form really contains. Read-only.
  $all = $rerun.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($el in $all) {
    $n = "$($el.Current.Name)"
    if ($n -notmatch '(?i)sample') { continue }
    $r = $el.Current.BoundingRectangle
    if ([double]::IsInfinity($r.X)) { continue }
    "OOS_PROBE label='$n' type=$($el.Current.ControlType.ProgrammaticName) id='$($el.Current.AutomationId)'" +
      " rect=$([int]$r.X),$([int]$r.Y),$([int]$r.Width),$([int]$r.Height)"
    foreach ($k in $el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) {
      $tp = $null
      $state = if ($k.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) {
        $tp.Current.ToggleState.ToString() } else { '-' }
      $vp = $null
      $val = if ($k.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        $vp.Current.Value } else { '-' }
      $kr = $k.Current.BoundingRectangle
      $kx = if ([double]::IsInfinity($kr.X)) { '-' } else { [int]$kr.X }
      "OOS_PROBE   child type=$($k.Current.ControlType.ProgrammaticName) name='$($k.Current.Name)' id='$($k.Current.AutomationId)' toggle=$state value='$val' x=$kx"
    }
    $words = @(Get-OcrWords ([int]$r.X) ([int]$r.Y) ([int]$r.Width) ([int]$r.Height))
    "OOS_PROBE   ocr='$(($words | ForEach-Object { $_.Text }) -join ' ')'"
  }
}
$symbolsLine = "$($fields['Symbols'])"
# Costs belong in the result: a rerun cannot be judged without them, and the form already
# carries them (the keys vary by column label, so collect by name rather than hard-coding).
$costKeys = [ordered]@{}
foreach ($k in $fields.Keys) {
  if ($k -match 'Commission|Slippage') { $costKeys[$k] = "$($fields[$k])".Trim() }
}
"ADJUST field=symbol server=$serverSymbol -> $applied"
"VERIFY symbols_line='$symbolsLine' selector_count='$countText'"
$patternLine = "VERIFY start='$($fields['Start Date'])' stop='$($fields['Stop Date'])' type='$($fields['Strategy Type'])' commission='$($fields['Commission (market currency)']) '"
if ($DryRun) {
  # In-sample / out-of-sample settings sit in the same form read and are needed by the
  # strategy wiki pages. Appended only on the dry-run path: the real run's stdout and
  # payload are left exactly as they were.
  $pctText = if ($null -eq $oos.percentage) { '' } else { "$($oos.percent_raw)" }
  $patternLine += " oos_mode='$($oos.mode)' oos_percent='$pctText' oos_split_date='$($oos.split_date)'" +
                  " oos_split_basis='$($oos.basis)' oos_percent_as_shown='$($oos.percent_raw)'"
}
$patternLine
$verified = $true
$formLabelNoisy = $false
foreach ($k in $dateResults.Keys) {
  $want = if ($k -eq 'Start Date') { $StartDate } else { $StopDate }
  $got = $fields[$k]
  $wantDate = [datetime]::MinValue
  [void][datetime]::TryParse($want, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$wantDate)
  # date-only comparison: the form re-renders with a time component and may normalise
  # the day, so comparing the raw strings never matches an ISO input
  $ok = Test-DateMatches $got $wantDate
  "VERIFY date_$($k -replace ' ','_')='$got' target='$want' ok=$ok"
  if (-not $ok) { $verified = $false }
}

if ($SymbolKind -eq 'builtin') {
  if ($countText -notmatch '\(1\)') { $verified = $false }
  # The count says "one symbol is selected", not *which*. Report a name mismatch but do
  # not fail on it: the picker row we tick is known to be right (it is read back by
  # name at tick time), while the meaning of this field is not. builtin:XRP reads back
  # 'IXRP' here while the ticked row is 'XRP' - so the field cannot be trusted as a
  # verdict. The real check is on the results grid after a run (below).
  if ($symbolsLine -and $symbolsLine -notmatch '^\(none\)$') {
    # symbols_line is OCR of the drawn selector, not a UIA value (see Read-RerunForm in
    # buildalpha_uia.ps1): a leading count/separator glyph can be glued onto the text,
    # which is how builtin:XRP read back as 'IXRP'. So compare with punctuation and
    # stray leading characters tolerated, and never turn OCR noise into a claim about
    # symbol codes. Anything that still differs is reported as unreadable, not as an alias.
    $wantBare = ($NewSymbol -replace '[^A-Za-z0-9]', '')
    $gotBare = ($symbolsLine -replace '[^A-Za-z0-9]', '')
    if ($gotBare -notlike "*$wantBare*") {
      $formLabelNoisy = $true
      "FORM_LABEL_OCR_MISMATCH requested='$NewSymbol' ocr='$($symbolsLine.Trim())' row='$selectedName'"
    }
  }
} elseif ($SymbolKind -eq 'server') {
  if ($symbolsLine -and $symbolsLine -notmatch [regex]::Escape($NewSymbol)) { $verified = $false }
}
if (-not $verified) { "VERIFY_FAILED expected $NewSymbol"; exit 24 }

if ($DryRun) {
  [void](Close-WindowChecked -hwnd $rerunHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
  Start-Sleep -Milliseconds 1200
  $observed = Get-ObservedWindows $proc.Id
  Write-Output ("WINDOWS " + (@($observed) | ConvertTo-Json -Compress))
  $left = @($observed | Where-Object { $_ -eq 'Re-Run' -or $_ -like 'Re-Run results*' -or $_ -like 'Results window closing*' })
  if ($left.Count) { 'WINDOWS_LEFT_OPEN'; exit 19 }
  'CLEANED_UP'
  # verified says "the symbol asked for is the symbol in play"; symbol_evidence says on
  # what basis. symbols_line is OCR, so it is reported with its own provenance.
  'DRY_RUN ' + (@{ filter = $Filter; server_symbol = $serverSymbol; applied = $applied; symbols_line = $symbolsLine; symbols_line_source = 'ocr'; selector_count = $countText; verified = $verified; form_label_ocr_differs = $formLabelNoisy; symbol_evidence = 'picker_row';
    start = "$($fields['Start Date'])"; stop = "$($fields['Stop Date'])"; strategy_type = "$($fields['Strategy Type'])";
    commission = "$($fields['Commission (market currency)'])".Trim();
    oos = @{ mode = $oos.mode; percent_raw = $oos.percent_raw; percentage = $oos.percentage;
             fraction = $oos.fraction; split_date = $oos.split_date; split_basis = $oos.basis } } | ConvertTo-Json -Compress)
  exit 0
}

Phase 'form-read'
# ---------------------------------------------------------- 5. run + read
# guarded immediately before the click on 'Regular simulation'
Set-AppForeground $rerunHwnd
if (-not (Invoke-Button $rerun 'Regular simulation')) { Stop-With 'RUN_BUTTON_MISSING' 16 }
Start-Sleep -Milliseconds 900
if (Clear-SymbolModal) {
  Stop-With ("SYMBOLS_MISSING BuildAlpha answered 'No symbols chosen for simulation!'; the dialog was " +
    "dismissed and nothing was simulated") 28
}
"running..."

$resHwnd = [IntPtr]::Zero
for ($i = 0; $i -lt ($RowTimeoutSec * 2) -and $resHwnd -eq [IntPtr]::Zero; $i++) {
  Start-Sleep -Milliseconds 500
  $cand = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like 'Re-Run results*' } | Select-Object -First 1
  if ($cand) { $resHwnd = $cand }
}
if ($resHwnd -eq [IntPtr]::Zero) { Stop-With 'RESULTS_WINDOW_TIMEOUT' 17 }
$resTitle = Get-WindowTitle $resHwnd

$resWin = [System.Windows.Automation.AutomationElement]::FromHandle($resHwnd)
$rgrid = $null
for ($i = 0; $i -lt 20 -and -not $rgrid; $i++) {
  $rgrid = $resWin.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataGrid } | Select-Object -First 1
  if (-not $rgrid) { Start-Sleep -Milliseconds 500 }
}
if (-not $rgrid) { Stop-With 'RESULTS_GRID_MISSING' 18 }
$rgp = $null
[void]$rgrid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$rgp)

function Read-ResultMetrics($rgp) {
  $row = [ordered]@{}
  for ($c = 0; $c -lt $rgp.Current.ColumnCount; $c++) {
    $cell = $null
    try { $cell = $rgp.GetItem(0, $c) } catch { continue }
    if (-not $cell) { continue }
    if ($cell.Current.Name -match 'Column (.*?), Column \d+ of \d+: (.*)$') { $row[$Matches[1]] = $Matches[2] }
  }
  return $row
}

$metrics = [ordered]@{}
# The grid reports its columns immediately but the row materialises later: reading once
# produced a COMPLETED run with every metric null. Poll until Symbol and Trades are there.
for ($i = 0; $i -lt 12; $i++) {
  $metrics = Read-ResultMetrics $rgp
  if ("$($metrics['Symbol'])" -and "$($metrics['Trades'])") { break }
  Start-Sleep -Milliseconds 500
}
# A grid with no row is not a read failure: BuildAlpha renders no data row when the run
# produced no trades, and "this strategy takes no trades on this symbol" is a real answer.
# Report it as such - with trades 0 and no_trades true - instead of a blank success or a
# bogus unreadable-grid failure.
if (-not "$($metrics['Symbol'])" -or -not "$($metrics['Trades'])") {
  [void](Close-WindowChecked -hwnd $resHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
  # and the Re-Run dialog itself, otherwise the next call inherits it
  [void](Close-WindowChecked -hwnd $rerunHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
  $observed = Get-ObservedWindows $proc.Id
  "NO_TRADES window='$resTitle' columns=$($rgp.Current.ColumnCount) (grid has no data row: no trades on '$applied')"
  Write-Output ("WINDOWS " + (@($observed) | ConvertTo-Json -Compress))
  'NO_TRADES ' + (@{
    filter = $Filter; server_symbol = $serverSymbol; applied = $applied
    costs = $costKeys; result_symbol = ''; trades = '0'; no_trades = $true
    symbol_evidence = 'no_results'; form_label_ocr_differs = $formLabelNoisy
  } | ConvertTo-Json -Compress)
  exit 0
}

# The results grid is the authoritative record of what was simulated: it names the
# series the run actually used. If it is not the symbol we asked for, stop before
# reporting metrics - a wrong series must never look like a successful rerun.
$resultSymbol = "$($metrics['Symbol'])"
$wantSymbol = if ($SymbolKind -eq 'builtin') { $NewSymbol } elseif ($SymbolKind -eq 'server') { $NewSymbol } else { '' }
if ($wantSymbol -and $resultSymbol) {
  $gotBase = ($resultSymbol -split '_')[0]
  if ($gotBase -ne $wantSymbol -and $gotBase -ne ($wantSymbol -split '[-_]')[0]) {
  [void](Close-WindowChecked -hwnd $resHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
    Stop-With "SYMBOL_MISMATCH requested='$wantSymbol' results='$resultSymbol'" 24
  }
  "VERIFY result_symbol='$resultSymbol' matches request '$wantSymbol'"
}
# --------------------------------------------------------------- 4b. trades
# The trade list is only reachable while the results window is open ('Show Trades' on its
# row), so it has to be captured here - before any close below. The TSV is written to
# -TradesOut and the result carries a pointer, not the rows: 1,000+ trades would bloat the
# MCP response and the journal, and a remote caller cannot read a local path anyway.
$tradesInfo = $null
if ($IncludeTrades) {
  $tradesFile = if ($TradesOut) { $TradesOut } else { Join-Path $env:TEMP ('trades-' + $Filter + '.tsv') }
  # Bounded on purpose. Calling the extractor in-process is ~2 s faster, but an in-process
  # Win32/UIA call that blocks against a busy BuildAlpha cannot be interrupted: one run
  # spent 162 s inside the activation step and 5 minutes in total, so the caller timed out
  # and the work was lost. A child process costs ~2 s and can be killed at a deadline.
  $tradesTimeoutSec = 45
  $tt = [System.Diagnostics.Stopwatch]::StartNew()
  $targs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\buildalpha_trades.ps1",
             '-WindowTitle', '"Re-Run results*"', '-OutFile', "`"$tradesFile`"", '-Json')
  $tproc = Start-Process powershell -ArgumentList $targs -RedirectStandardOutput "$env:TEMP\ba_trades_out.txt" `
    -RedirectStandardError "$env:TEMP\ba_trades_err.txt" -WindowStyle Hidden -PassThru
  if (-not $tproc.WaitForExit($tradesTimeoutSec * 1000)) {
    Stop-Process -Id $tproc.Id -Force -ErrorAction SilentlyContinue
    $tradesInfo = [pscustomobject]@{ status = 'TRADES_TIMEOUT'; rows = 0; rows_ok = $false
                                     grid_rows = -1; reason = "blocked for ${tradesTimeoutSec}s; killed" }
    "TRADES_TIMEOUT after ${tradesTimeoutSec}s (child killed)"
  } else {
    $tradesText = Get-Content "$env:TEMP\ba_trades_out.txt" -Raw -ErrorAction SilentlyContinue
    foreach ($l in ($tradesText -split "`r?`n")) { if ($l.Trim().StartsWith('TRADES_PHASE')) { $l.Trim() } }
    $jsonLine = ($tradesText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($jsonLine) { try { $tradesInfo = $jsonLine | ConvertFrom-Json } catch { $tradesInfo = $null } }
  }
  $tt.Stop()
  if (-not $tradesInfo) {
    $tradesInfo = [pscustomobject]@{ status = 'TRADES_FAILED'; rows = 0; rows_ok = $false; grid_rows = -1 }
  }
  Phase 'trades'
}
$result = [ordered]@{
  filter        = $Filter
  server_symbol = $serverSymbol
  applied       = $applied
  costs         = $costKeys          # commission/slippage the run actually used
  trades_detail = $tradesInfo        # pointer to the TSV + verification, when requested
  result_symbol = "$($metrics['Symbol'])"
  symbols_line    = $symbolsLine
  symbols_line_source = 'ocr'
  form_label_ocr_differs = $formLabelNoisy
  symbol_evidence = 'results_grid'
  result_title  = $resTitle
  trades        = $metrics['Trades']
  sharpe        = $metrics['Sharpe']
  net_pnl       = $metrics['Net P&L']
  drawdown      = $metrics['Drawdown']
  drawdown_mtm  = $metrics['Drawdown MTM']
  pnl_dd        = $metrics['P&L / DD']
  win_pct       = $metrics['Win Percentage']
  profit_factor = $metrics['Profit Factor']
  robust_index  = $metrics['Robust Index']
  cagr          = $metrics['CAGR']
  sqn           = $metrics['SQN']
  delta         = (Get-MetricDelta $baseline $metrics)
}
# 'baseline' is reported once, at the top level of the tool response - do not
# duplicate it inside the results payload
'RESULT ' + ($result | ConvertTo-Json -Compress -Depth 5)

Phase 'simulate+read'
# ---------------------------------------------------------- 6. close windows
[void](Close-WindowChecked -hwnd $resHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 500
  $modal = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like 'Results window closing*' } | Select-Object -First 1
  if ($modal) {
    $mw = [System.Windows.Automation.AutomationElement]::FromHandle($modal)
    $els = $mw.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $text = ($els | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text } | ForEach-Object { $_.Current.Name }) -join ' '
    if ($text -notmatch 'close the results window') { "MODAL_NOT_RESULTS: $text"; break }
    $yes = $els | Where-Object { $_.Current.Name -eq 'Yes' } | Select-Object -First 1
    if ($yes) {
      $yip = $null
      if ($yes.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$yip)) { $yip.Invoke() } else { Invoke-Button $mw 'Yes' | Out-Null }
      Start-Sleep -Milliseconds 1500
    }
  }
  if (-not (Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like 'Re-Run results*' })) { break }
}
for ($i = 0; $i -lt 10; $i++) {
  $still = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Re-Run' } | Select-Object -First 1
  if (-not $still) { break }
  [void](Close-WindowChecked -hwnd $still -ProcessId $proc.Id -Allowed @($mainHwnd))
  Start-Sleep -Milliseconds 700
}
$observed = Get-ObservedWindows $proc.Id
Write-Output ("WINDOWS " + (@($observed) | ConvertTo-Json -Compress))
$left = @($observed | Where-Object { $_ -eq 'Re-Run' -or $_ -like 'Re-Run results*' -or $_ -like 'Results window closing*' })
if ($left.Count) { 'WINDOWS_LEFT_OPEN'; exit 19 }
'CLEANED_UP'
exit 0

Phase 'cleanup'