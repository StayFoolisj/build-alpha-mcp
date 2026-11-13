<#
.SYNOPSIS
  Re-run a BuildAlpha strategy and diff the before/after metrics.

.DESCRIPTION
  Captures the strategy's full record from the portfolio grid, invokes the
  row's right-click "Re-run strategy" item (OCR-assisted), waits for the
  separate results window BuildAlpha opens, reads it, and writes a
  metric<TAB>before<TAB>after<TAB>delta report.

  STATUS: standalone report script, not exposed as a tool and not called by any code. It is the
  last place that finds its row with Find-Row (a click-scan that only sees the visible screenful and
  matches on name text). Prefer scripts/buildalpha_find_strategy.ps1 with an identify.plan() plan -
  see README, "Finding a strategy row" - before relying on this.

  IMPORTANT: a re-run does NOT update the portfolio grid. The result appears
  in a new top-level window. Never press Escape after the click - that closes
  the results window (this is exactly what makes a re-run look like a no-op).

.PARAMETER Strategy
  Strategy name (the grid's Name column). Rows without a custom name show
  their rule expression here.

.PARAMETER RowY
  Optional screen Y of the row. When set, the row is read by index, so the
  exact name does not need to match.

.PARAMETER DryRun
  Capture the before snapshot and stop (no re-run, no state change).

.PARAMETER KeepResults
  Keep the re-run results window open (default: close it after reading).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_rerun_compare.ps1 -DryRun -RowY 276
  powershell -ExecutionPolicy Bypass -File .\buildalpha_rerun_compare.ps1 -Strategy 'seasonality strategy test'
#>
param(
  [string]$Strategy = '',
  [int]$RowY = 0,
  [int]$NameX = 400,
  [string]$OutFile = 'rerun-comparison.txt',
  [int]$TimeoutSec = 180,
  [switch]$DryRun,
  [switch]$KeepResults
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

function Fail([string]$Message) {
  Write-Output "ERROR: $Message"
  exit 1
}

if (-not $Strategy -and $RowY -le 0) { Fail 'pass -Strategy <name> or -RowY <y>' }

$win = Get-MainWindow
if (-not $win) { Fail 'BuildAlpha window not found (is the app running?)' }
$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$procId = $win.Current.ProcessId

Set-AppForeground $hwnd
Send-Escape 4                      # leave any in-cell edit mode
Park-ResultWindows -ProcessId $procId -MainHwnd $hwnd

# --- resolve the target row ------------------------------------------------
$rowIndex = -1
$y = 0
if ($RowY -gt 0) {
  $y = $RowY
  $cell = Get-ElementAt 200 $y
  if ($cell) {
    $m = [regex]::Match($cell.Current.Name, $script:CellPattern)
    if ($m.Success) { $rowIndex = [int]$m.Groups[2].Value }
  }
  if ($rowIndex -lt 0) { Fail "no grid row at y=$y" }
} else {
  $target = Find-Row -Name $Strategy -NameX $NameX
  if (-not $target) { Fail "strategy '$Strategy' not found in the visible rows (try -RowY)" }
  $y = [int]$target.Y
  $rowIndex = [int]$target.Row
}
if (-not $Strategy) { $Strategy = "(row $rowIndex)" }
Write-Output "target: name='$Strategy' row=$rowIndex y=$y"

# --- before snapshot -------------------------------------------------------
$grid = Get-DataGrid (Get-ElementAt 200 $y)
if (-not $grid) { Fail "portfolio grid not reachable at y=$y" }
$rows = Read-GridAllRows $grid
$before = $rows[$rowIndex]
if (-not $before -and $Strategy -ne "(row $rowIndex)") { $before = Read-Record -Grid $grid -Name $Strategy }
if (-not $before) { Fail "could not read row $rowIndex" }
Write-Output "before: $($before.Keys.Count) columns captured"

if ($DryRun) {
  Write-Output 'dry run: no click performed'
  foreach ($k in ($before.Keys | Sort-Object)) { Write-Output "  $k`t$($before[$k])" }
  exit 0
}

# --- re-run ----------------------------------------------------------------
Invoke-LeftClick 200 $y
Start-Sleep -Milliseconds 250
Invoke-RightClick 200 $y
Start-Sleep -Milliseconds 1200

$beforeHwnds = @(Get-VisibleWindows $procId)
$click = Invoke-MenuItem -ProcessId $procId -MainHwnd $hwnd -Regex '(?i)^re[-\s]?run'
if (-not $click -or -not $click.Clicked) { Fail 'could not find/click "Re-run strategy" in the context menu' }
Write-Output "clicked: '$($click.Clicked)'"

# --- read the new results window (do NOT press Escape) ----------------------
$result = Wait-NewGridWindow -ProcessId $procId -BeforeHwnds $beforeHwnds -TimeoutSec $TimeoutSec
if (-not $result) { Fail 're-run results window not found (was Escape pressed, or did the run fail?)' }
Write-Output "results window: hwnd=$($result.Hwnd)"

$after = Read-Record -Grid $result.Grid -Name $null
if (-not $after) { Fail 'results grid was empty' }
Write-Output "after:  $($after.Keys.Count) columns captured"

# --- diff ------------------------------------------------------------------
$diff = Compare-BARecord -Before $before -After $after

$header = New-Object System.Collections.Generic.List[string]
$header.Add('# BuildAlpha re-run comparison')
$header.Add("# strategy : $Strategy")
$header.Add('# before   : portfolio grid')
$header.Add('# after    : re-run results window')
$header.Add("# changed  : $($diff.Changed) of $($diff.Total) fields")
$header.Add("Metric`tBefore`tAfter`tDelta")
$all = @($header) + $diff.Lines
$all | Out-File -Encoding utf8 $OutFile

Write-Output ''
Write-Output ('RESULT: {0} of {1} fields changed. Report: {2}' -f $diff.Changed, $diff.Total, $OutFile)
$numeric = @($diff.Lines | Where-Object { $_ -match "`t-?[\d.]+$" })
if ($numeric.Count -gt 0) {
  Write-Output 'Changed numeric fields:'
  foreach ($line in $numeric) { Write-Output "  $line" }
}

if (-not $KeepResults) { Close-Window $result.Hwnd }
