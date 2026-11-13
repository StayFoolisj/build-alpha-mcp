# Make sure one named portfolio is loaded, in-process, with the UI guard. Prints a one-line verdict.
# Used by portfolio_sweep instead of buildalpha_switch_portfolio.ps1 (which resized and pinned the
# window and could leave it pinned when it exited early).
param(
  [string]$Name = '',
  [int]$ComboX = 120,
  [int]$ComboY = 73,
  [switch]$List,
  # accepted for compatibility with portfolio_sweep; this script never pins the window
  [switch]$KeepTopmost
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }

if ($List) {
  # read-only: which portfolio is loaded, and what the list holds
  $state = Get-PortfolioState -ComboX $ComboX -ComboY $ComboY
  if (-not $state.Ok) { 'NO_DROPDOWN'; exit 3 }
  foreach ($it in $state.Items) {
    Write-Output ("PORTS`t{0}`t{1}" -f $it.Name, $(if ($it.Selected) { 'True' } else { 'False' }))
  }
  exit 0
}

if (-not $Name) { 'NO_NAME'; exit 4 }
$ens = Set-PortfolioVerified -Name $Name -ComboX $ComboX -ComboY $ComboY
if ($ens.Ok) {
  Write-Output ("SWITCHED`tname={0}`tswitched={1}" -f $ens.Read, $ens.Switched)
  exit 0
}
Write-Output ("SWITCH_FAILED`twanted={0}`tread={1}`treason={2}" -f $Name, $ens.Read, $ens.Reason)
exit 5
