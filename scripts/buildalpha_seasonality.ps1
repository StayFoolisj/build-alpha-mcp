<#
.SYNOPSIS
  Open a BuildAlpha strategy's Seasonality (or Monthly Returns) view and
  capture it as a PNG.

.DESCRIPTION
  Right-clicks the strategy row and clicks "Seasonality" (or "Monthly Returns")
  in the custom-drawn context menu, which can only be read with OCR. The
  resulting chart is custom-drawn too, so its values are not exposed through
  UI Automation - this script saves a screenshot of the window for inspection.

.PARAMETER PlanFile
  JSON from strategy_cache.identify.plan(). When given, the row is found by the shared search
  (scripts/buildalpha_find_strategy.ps1): it filters by Net P&L, verifies the row's own metrics,
  clicks it and proves the selection. The right-click then lands on the Symbol cell of that proven
  row. Preferred over -Strategy, which can only match a row that happens to be on screen.

.PARAMETER Strategy
  Legacy: a strategy name to look for among the visible rows (the grid's Name column). Skipped
  when -PlanFile is given.

.PARAMETER Item
  Which view to open: 'Seasonality' (default) or 'Monthly Returns'.

.PARAMETER ListOnly
  Only OCR and print the context-menu items; do not click anything.

.PARAMETER CloseWindow
  Close the view after capturing it (default: leave it open to look at).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_seasonality.ps1 -Strategy 'seasonality strategy test'
#>
param(
  [string]$PlanFile = '',
  # Skip the search's portfolio read/switch when the caller knows the right portfolio is
  # already loaded: that read costs ~2.7 s and changes nothing in the common case.
  [switch]$SkipPortfolio,
  [string]$Strategy = '',
  [ValidateSet('Seasonality', 'Monthly Returns')][string]$Item = 'Seasonality',
  [int]$RowY = 0,
  [int]$NameX = 400,
  [string]$Shot = 'seasonality.png',
  [int]$TimeoutSec = 90,
  [switch]$ListOnly,
  [switch]$CloseWindow
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\buildalpha_uia.ps1"

# One GUI driver at a time (see Enter-UiLock): a second call must not interleave its clicks and
# filters with this one. A child of a lock holder inherits the flag and skips this.
$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }

function Fail([string]$Message) {
  Write-Output "ERROR: $Message"
  exit 1
}

$win = Get-MainWindow
if (-not $win) { Fail 'BuildAlpha window not found (is the app running?)' }
$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$procId = $win.Current.ProcessId

Set-AppForeground $hwnd
Send-Escape 4
Park-ResultWindows -ProcessId $procId -MainHwnd $hwnd

$pattern = if ($Item -eq 'Monthly Returns') { '(?i)^monthly\s*ret' } else { '(?i)^seasonality' }
$y = 0
$rightClickX = 200

if ($PlanFile) {
  # The shared search: Net P&L first, metric verification, click, proven selection. Everything the
  # legacy branch below guesses at - where the row is, whether the row found is the right one,
  # whether it is even on screen - is decided there.
  $prevEapSearch = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # the child narrates on stderr; that must not abort us
  $searchRun = Invoke-ScriptBounded -Script (Join-Path $PSScriptRoot 'buildalpha_find_strategy.ps1') `
    -Arguments (@('-PlanFile', $PlanFile) + $(if ($SkipPortfolio) { @('-SkipPortfolio') } else { @() })) -TimeoutSec 120
  $ErrorActionPreference = $prevEapSearch
  $findLine = @("$($searchRun.Output)" -split "`r?`n") |
    Where-Object { $_ -match 'FIND \{' } | Select-Object -Last 1
  if (-not $findLine) { Fail "search produced no verdict: $("$($searchRun.Output)".Trim())" }
  $find = ($findLine -replace '^.*?FIND \{', '{') | ConvertFrom-Json
  if ($find.status -ne 'OK') { Fail "search refused ($($find.status)): $($find.detail)" }
  $rect = $find.row_rect
  $y = [int]$rect.y + [int]($rect.height / 2)
  # right-click the Symbol cell that was proven, never a fixed x: x=200 sits in the Name column,
  # whose right-click opens the rename editor instead of the strategy menu
  $rightClickX = [int]$rect.x + [int]($rect.width / 2)
  Write-Output ("target: name='{0}' row={1} y={2} matched_by={3} (shared search)" -f
    $find.row_name, $find.row_index, $y, $find.matched_by)
} else {
  if (-not $Strategy) { Fail 'one of -PlanFile or -Strategy is required' }
  $target = $null
  if ($RowY -gt 0) { $target = @{ Row = 0; Y = $RowY } }
  else { $target = Find-Row -Name $Strategy -NameX $NameX }
  if (-not $target) { Fail "strategy '$Strategy' not found in the visible rows (try -RowY or -PlanFile)" }
  $y = [int]$target.Y
  Write-Output "target: name='$Strategy' row=$($target.Row) y=$y (legacy name scan)"
  Invoke-LeftClick 200 $y
  Start-Sleep -Milliseconds 250
}

Invoke-RightClick $rightClickX $y
Start-Sleep -Milliseconds 1200

$beforeHwnds = @(Get-VisibleWindows $procId)
$click = Invoke-MenuItem -ProcessId $procId -MainHwnd $hwnd -Regex $pattern -ListOnly:$ListOnly

if ($ListOnly) {
  if ($click) { Write-Output "menu has $($click.Items.Count) items (list only, nothing clicked)" }
  else { Fail 'context menu did not appear' }
  exit 0
}

if (-not $click -or -not $click.Clicked) { Fail "could not find/click '$Item' in the context menu" }
Write-Output "clicked: '$($click.Clicked)'"

$titleRegex = if ($Item -eq 'Monthly Returns') { '^Monthly Returns' } else { '^Seasonality' }
$view = Wait-NewWindowByTitle -ProcessId $procId -BeforeHwnds $beforeHwnds -TitleRegex $titleRegex -TimeoutSec $TimeoutSec
if ($view -eq [IntPtr]::Zero) { Fail "'$Item' window did not appear" }

Start-Sleep -Milliseconds 1500   # let the chart finish rendering
$shotPath = Save-WindowShot -Hwnd $view -Path $Shot
$r = Get-WindowRect $view
Write-Output "view: '$((Get-WindowTitle $view))' hwnd=$view rect=$($r.Left),$($r.Top),$($r.Right - $r.Left),$($r.Bottom - $r.Top)"
Write-Output "SHOT: $shotPath"

if ($CloseWindow) { Close-Window $view; Write-Output 'window closed' }
