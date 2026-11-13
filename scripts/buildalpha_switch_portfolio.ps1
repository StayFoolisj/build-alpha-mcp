<#
.SYNOPSIS
  Switch the BuildAlpha portfolio selector to a named portfolio, and verify it.

.DESCRIPTION
  The selector is a DevExpress ComboBoxEdit in the Portfolio pane header. It is
  usually *not* in the UI Automation tree with a usable rectangle (empty rect,
  IsOffscreen=True) even while it is painted on screen, so it is opened by
  clicking a fixed screen position after the main window is moved to (0,0) and
  made topmost. The popup *does* expose its items, each a ListItem whose child
  Text element carries the real portfolio name; the item rectangle is stable,
  so the switch itself is a real mouse click on that item (Select() only
  highlights - it does not commit).

  Verification: the popup is reopened and the item that reports
  SelectionItemPattern.IsSelected must be the requested portfolio. The combo's
  own ValuePattern is not populated while the portfolio is loading.

.PARAMETER Name
  Portfolio to select, exact (case-insensitive) or an unambiguous prefix.

.PARAMETER List
  Print the portfolios and their selection state, switch nothing.

.PARAMETER TimeoutSec
  How long to wait for the popup / for the switch to be confirmed.

.EXAMPLE
  powershell -File .\buildalpha_switch_portfolio.ps1 -List
  powershell -File .\buildalpha_switch_portfolio.ps1 -Name "Hyperliquid #2"

.OUTPUTS
  -List      : PORTS <name>\t<selected>\t<x>,<y>   (one per line)
  -Name      : SWITCHED name=<portfolio>           exit 0
  errors     : NO_BUILDALPHA / NO_MAIN_WINDOW (2), NO_DROPDOWN (3),
               PORTFOLIO_NOT_FOUND (4), VERIFY_FAILED (5)
#>
param(
  [string]$Name = '',
  [switch]$List,
  [int]$TimeoutSec = 20,
  [int]$ComboX = 120,
  [int]$ComboY = 73,
  [switch]$KeepTopmost
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

Add-Type -Namespace BASW -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@

$proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output 'NO_BUILDALPHA'; exit 2 }
$win = [IntPtr]::Zero
foreach ($h in (Get-VisibleWindows $proc.Id)) {
  if ((Get-WindowTitle $h) -like 'Build Alpha*') { $win = $h; break }
}
if ($win -eq [IntPtr]::Zero) { Write-Output 'NO_MAIN_WINDOW'; exit 2 }

# deterministic geometry: the combo sits at a fixed offset in the Portfolio pane
# SW_RESTORE only if it is really minimised: on a maximised window it un-maximises it and
# the app drops to its previous size.
if ([BASW.W]::IsIconic($win)) { [void][BASW.W]::ShowWindow($win, 9) }
Start-Sleep -Milliseconds 400
if ([BASW.W]::IsIconic($win)) {
  Write-Output 'RESTORE_FAILED window is still minimized'
  exit 2
}
# 0x43 = SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE  (NOT SWP_NOZORDER: that flag
# would ignore hwndInsertAfter and the window would never become topmost)
# Topmost only, no geometry change. This used to also resize the window to 1510x900, which left
# Build Alpha smaller than the operator had it; and an early exit (NO_DROPDOWN, PORTFOLIO_NOT_FOUND)
# returned before the unpin at the bottom, so the pin survived for the rest of the session.
[void][BASW.W]::SetWindowPos($win, [IntPtr](-1), 0, 0, 0, 0, 0x0043 -bor 0x0001 -bor 0x0002)
[void][BASW.W]::SetForegroundWindow($win)
Start-Sleep -Milliseconds 500

function Stop-Unpinned([int]$Code) {
  if (-not $KeepTopmost) {
    [void][BASW.W]::SetWindowPos($win, [IntPtr](-2), 0, 0, 0, 0, 0x0003)   # drop topmost
  }
  exit $Code
}

function Get-PortfolioItems {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)),
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)))
  $out = @()
  foreach ($li in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    $r = $li.Current.BoundingRectangle
    if ($r.Width -le 0) { continue }
    $t = $li.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))
    if (-not $t) { continue }
    $sp = $null
    $sel = $false
    if ($li.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sel = $sp.Current.IsSelected }
    $out += [pscustomobject]@{ Name = $t.Current.Name; Selected = $sel; Rect = $r }
  }
  return $out
}

function Open-PortfolioDropdown {
  Send-Escape
  Start-Sleep -Milliseconds 250
  Invoke-LeftClick $ComboX $ComboY
  for ($i = 0; $i -lt ($TimeoutSec * 4); $i++) {
    Start-Sleep -Milliseconds 250
    $items = @(Get-PortfolioItems)
    if ($items.Count -ge 2) { return $items }
  }
  return @()
}

$items = @(Open-PortfolioDropdown)
if ($items.Count -lt 2) { Send-Escape; Write-Output 'NO_DROPDOWN'; Stop-Unpinned 3 }

if ($List) {
  foreach ($i in $items) {
    Write-Output ("PORTS`t{0}`t{1}`t{2},{3}" -f $i.Name, $i.Selected, [int]$i.Rect.Left, [int]$i.Rect.Top)
  }
  Send-Escape
  exit 0
}

if (-not $Name) { Send-Escape; Write-Output 'NO_NAME'; exit 4 }

$target = $items | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
if (-not $target) {
  $partial = @($items | Where-Object { $_.Name -like "$Name*" })
  if ($partial.Count -eq 1) { $target = $partial[0] }
}
if (-not $target) {
  Send-Escape
  $avail = ($items | ForEach-Object { $_.Name }) -join '; '
  Write-Output ("PORTFOLIO_NOT_FOUND name={0} available={1}" -f $Name, $avail)
  Stop-Unpinned 4
}

# a real click commits; SelectionItemPattern.Select() only highlights the row
Invoke-LeftClick ([int]($target.Rect.Left + $target.Rect.Width / 2)) ([int]($target.Rect.Top + $target.Rect.Height / 2))
Start-Sleep -Seconds 2

$confirmed = $false
$selected = ''
for ($attempt = 0; $attempt -lt 3 -and -not $confirmed; $attempt++) {
  $again = @(Open-PortfolioDropdown)
  if ($again.Count -ge 2) {
    $sel = $again | Where-Object { $_.Selected } | Select-Object -First 1
    if ($sel) { $selected = $sel.Name }
    if ($selected -eq $target.Name) { $confirmed = $true }
  }
  if (-not $confirmed) { Start-Sleep -Seconds 2 }
}
Send-Escape

if ($false) { }

if ($confirmed) {
  Write-Output ("SWITCHED`tname={0}" -f $target.Name)
  Stop-Unpinned 0
}
Write-Output ("VERIFY_FAILED`twanted={0}`tselected={1}" -f $target.Name, $selected)
Stop-Unpinned 5
