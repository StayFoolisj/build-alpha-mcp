# buildalpha_settings.ps1 - open / close / inspect the BuildAlpha "Settings" window.
#
#   -Action open     : restore + foreground the main window, press F8, and if the
#                      Settings window does not appear, click a portfolio row cell
#                      (gives the grid focus) and press F8 again. -ClickFirst skips
#                      the bare F8 attempt and clicks first (the reliable order when
#                      the app was just restored).
#   -Action close    : close Settings via its own Close button (fallbacks: WM_CLOSE),
#                      and report any modal that appears instead.
#   -Action status   : report whether Settings is open, plus its grid size.
#
# Output is line based and machine readable:
#   STATE_OPEN hwnd=.. left=.. top=.. width=.. height=.. rows=.. cols=..
#   STATE_CLOSED
#   OPENED hwnd=.. via=f8|f8-after-click ms=..
#   CLOSED ms=..
#   ALREADY_OPEN / ALREADY_CLOSED
#   PROMPT title=..            (an unexpected window appeared instead)
#   ERROR <reason>             (exit 2..9)

param(
  [ValidateSet('open', 'close', 'status')]
  [string]$Action = 'status',
  [int]$TimeoutSec = 20,
  [int]$WorkWidth = 1508,
  [int]$WorkHeight = 900,
  [switch]$ClickFirst,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
. "$PSScriptRoot\buildalpha_uia.ps1"

if (-not ('BAW' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class BAW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<IntPtr> VisibleTopLevel(uint pid) {
    var res = new List<IntPtr>();
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h)) res.Add(h);
      return true;
    }, IntPtr.Zero);
    return res;
  }
  public static string Title(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
}
'@
}

function Get-TargetProcess {
  $p = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { throw 'NO_BUILDALPHA' }
  return $p
}

function Get-MainHwnd($proc) {
  $el = Get-MainWindow
  if (-not $el) { throw 'NO_MAIN_WINDOW' }
  return [IntPtr]$el.Current.NativeWindowHandle
}

function Get-SettingsHwnd($proc) {
  foreach ($h in [BAW]::VisibleTopLevel([uint32]$proc.Id)) {
    if ([BAW]::Title($h) -eq 'Settings') { return $h }
  }
  return [IntPtr]::Zero
}

function Restore-Main([IntPtr]$main) {
  $r = Get-WindowRect $main
  $off = ($r.Left -le -30000)
  $narrow = (($r.Right - $r.Left) -lt 1000)
  if ($off) { [void][BA]::ShowWindow($main, 9); Start-Sleep -Milliseconds 700 }
  if ($off -or $narrow) {
    [void][BA]::SetWindowPos($main, [IntPtr]::Zero, 1, 0, $WorkWidth, $WorkHeight, 0x40)
    Start-Sleep -Milliseconds 500
  }
  Set-AppForeground $main
  Start-Sleep -Milliseconds 400
}

function Focus-PortfolioGrid([IntPtr]$main, $proc) {
  # a data row cell in the Name/State area; only used to give the grid keyboard focus
  $r = Get-WindowRect $main
  $x = $r.Left + 300
  $y = $r.Top + 125
  if ($y -lt ($r.Top + 80) -or $x -gt ($r.Right - 40)) { throw 'ROW_POINT_OUTSIDE_WINDOW' }
  $under = Get-ElementAt $x $y
  if (-not $under -or $under.Current.ProcessId -ne $proc.Id) { throw 'ROW_POINT_NOT_BUILDALPHA' }
  Invoke-LeftClick $x $y
  Start-Sleep -Milliseconds 500
}

function Send-F8 {
  [BA]::keybd_event(0x77, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  [BA]::keybd_event(0x77, 0, 2, [UIntPtr]::Zero)
}

function Wait-Settings($proc, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $h = Get-SettingsHwnd $proc
    if ($h -ne [IntPtr]::Zero) { return $h }
    Start-Sleep -Milliseconds 250
  }
  return [IntPtr]::Zero
}

function Describe-Settings([IntPtr]$hwnd, $proc) {
  $r = Get-WindowRect $hwnd
  $rows = ''
  $cols = ''
  $sw = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $grid = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::DataGrid)))
  if ($grid) {
    $gp = $null
    if ($grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)) {
      $rows = $gp.Current.RowCount
      $cols = $gp.Current.ColumnCount
    }
  }
  "{0} hwnd={1}" -f 'STATE_OPEN', $hwnd
  "  rect=$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
  "  symbol_grid rows=$rows cols=$cols"
}

function Find-Modal($proc, $ignore) {
  foreach ($h in [BAW]::VisibleTopLevel([uint32]$proc.Id)) {
    if ($ignore -contains $h) { continue }
    $t = [BAW]::Title($h)
    if ($t -eq '' ) { continue }
    if ($t -eq 'Build Alpha' -or $t -eq 'Settings') { continue }
    return $h
  }
  return [IntPtr]::Zero
}

try {
  $proc = Get-TargetProcess
  $main = Get-MainHwnd $proc
  $existing = Get-SettingsHwnd $proc

  switch ($Action) {
    'status' {
      if ($existing -ne [IntPtr]::Zero) { Describe-Settings $existing $proc }
      else { 'STATE_CLOSED' }
    }

    'open' {
      if ($existing -ne [IntPtr]::Zero) {
        'ALREADY_OPEN'
        Describe-Settings $existing $proc
        exit 0
      }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      Restore-Main $main
      $via = 'f8'
      if ($ClickFirst) {
        Focus-PortfolioGrid $main $proc
        $via = 'click-then-f8'
      }
      Send-F8
      $hwnd = Wait-Settings $proc 6
      if ($hwnd -eq [IntPtr]::Zero) {
        Focus-PortfolioGrid $main $proc
        Send-F8
        $hwnd = Wait-Settings $proc $TimeoutSec
        $via = 'f8-after-click'
      }
      if ($hwnd -eq [IntPtr]::Zero) { throw 'F8_NOT_REGISTERED' }
      $sw.Stop()
      "OPENED hwnd=$hwnd via=$via ms=$($sw.ElapsedMilliseconds)"
      Describe-Settings $hwnd $proc
    }

    'close' {
      if ($existing -eq [IntPtr]::Zero) { 'ALREADY_CLOSED'; exit 0 }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $swEl = [System.Windows.Automation.AutomationElement]::FromHandle($existing)
      $closeBtn = $swEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.AndCondition(
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)),
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Close')))))
      $usedClose = $false
      if ($closeBtn) {
        $ip = $null
        if ($closeBtn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) {
          # The Close button's peer can go stale ("Unrecognized error") right after grid
          # work; that is not a failure to close, it just needs the WM_CLOSE fallback.
          try { $ip.Invoke(); $usedClose = $true } catch { $usedClose = $false }
        }
      }
      if (-not $usedClose) { [void][BAW]::PostMessage($existing, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }  # WM_CLOSE

      $deadline = (Get-Date).AddSeconds($TimeoutSec)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if ((Get-SettingsHwnd $proc) -eq [IntPtr]::Zero) {
          $sw.Stop()
          "CLOSED ms=$($sw.ElapsedMilliseconds) method=$(if ($usedClose) { 'close-button' } else { 'wm_close' })"
          exit 0
        }
      }
      $modal = Find-Modal $proc @($main, $existing)
      if ($modal -ne [IntPtr]::Zero) { throw "PROMPT title=$([BAW]::Title($modal))" }
      throw 'STILL_OPEN_AFTER_CLOSE'
    }
  }
} catch {
  "ERROR $($_.Exception.Message)"
  exit 9
}
