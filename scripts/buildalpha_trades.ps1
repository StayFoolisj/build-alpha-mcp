<#
.SYNOPSIS
  Extract a strategy's trade list from BuildAlpha as TSV (thin CLI over Get-TradeTable).

.DESCRIPTION
  Right-clicks a row in the given grid window, chooses 'Show Trades', copies the table and
  writes it to a TSV. The work is done in-process by Get-TradeTable in buildalpha_uia.ps1,
  which is also called directly from buildalpha_rerun_adjust.ps1 - spawning a second
  PowerShell just for this cost ~2 s.

  Verification: parsed rows must equal the grid's RowCount, the header must be the 10
  expected columns, and with -ExpectNetPnl the 'Result' column must sum to that value.
  The clipboard is saved and restored.

.PARAMETER RowX
  A plain column (default 120 = Symbol). The Name cell is interactive (rename) and opens a
  different context menu, so right-clicking there never shows 'Show Trades'.

.EXAMPLE
  powershell -File scripts\buildalpha_trades.ps1 -WindowTitle 'Re-Run results*' -Json
#>
[CmdletBinding()]
param(
  [string]$WindowTitle = 'Build Alpha',
  [int]$RowX = 120,
  [int]$RowY = 0,
  [string]$OutFile = '',
  [double]$ExpectNetPnl = [double]::NaN,
  [string]$ExpectName = '',
  [double]$Tolerance = 0.5,
  [int]$TimeoutSec = 25,
  [switch]$KeepWindow,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Runtime.WindowsRuntime
. "$PSScriptRoot\buildalpha_uia.ps1"

$r = Get-TradeTable -WindowTitle $WindowTitle -RowX $RowX -RowY $RowY -OutFile $OutFile `
  -ExpectNetPnl $ExpectNetPnl -ExpectName $ExpectName -Tolerance $Tolerance `
  -TimeoutSec $TimeoutSec -KeepWindow:$KeepWindow

foreach ($m in $script:TradeMarks) { "TRADES_PHASE $m" }
if ($Json) { $r | ConvertTo-Json -Compress }
else {
  "TRADES status=$($r.status) rows=$($r.rows)/$($r.grid_rows) header_ok=$($r.header_ok) " +
  "pnl_ok=$($r.pnl_ok) sum=$($r.result_sum) path=$($r.path)"
}

switch ($r.status) {
  'TRADES_OK' { exit 0 }
  'TRADES_SUSPECT' { exit 10 }
  'NO_BUILDALPHA' { exit 2 }
  'WINDOW_MISSING' { exit 3 }
  'GRID_MISSING' { exit 4 }
  'ROW0_MISSING' { exit 4 }
  'CONTEXT_MENU_MISSING' { exit 5 }
  'ROWY_REQUIRED' { exit 4 }
  'MENU_ITEM_MISSING' { exit 6 }
  'TRADES_WINDOW_TIMEOUT' { exit 7 }
  'TRADES_GRID_MISSING' { exit 8 }
  'COPY_FAILED' { exit 9 }
  'NAME_MISMATCH' { exit 11 }
  default { exit 1 }
}
