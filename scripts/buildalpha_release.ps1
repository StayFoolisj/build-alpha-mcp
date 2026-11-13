<#
.SYNOPSIS
  Clear WS_EX_TOPMOST from every window of a process - the recovery path for a pinned
  window (after a killed run, a reboot, an RDP loss, or any script that died before it
  could release topmost).

.DESCRIPTION
  Uses SetWindowPos(hwnd, HWND_NOTOPMOST, ...) with SWP_ASYNCWINDOWPOS (0x4000). That
  flag matters: SetWindowPos sends WM_WINDOWPOSCHANGING synchronously, so against a hung
  BuildAlpha window the call blocks and the release is useless exactly when it is most
  needed. With SWP_ASYNCWINDOWPOS the request is queued and this script always returns.

  Reports what it changed; -Json for machine reading. Exit 0 even when nothing was
  pinned (idempotent). Exit 2 when the process is not running.

.EXAMPLE
  powershell -File scripts\buildalpha_release.ps1
  powershell -File scripts\buildalpha_release.ps1 -Json
#>
[CmdletBinding()]
param(
  [string]$ProcessName = 'BuildAlpha_x64',
  [long]$Hwnd = 0,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace RelW -Name Api -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
'@

$WS_EX_TOPMOST = 0x8
$HWND_NOTOPMOST = [IntPtr](-2)
# 0x43 = SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE  (no SWP_NOZORDER: that would ignore
# the insert-after argument and the window would keep its z-order)
# 0x4000 = SWP_ASYNCWINDOWPOS: never block on a hung window
$flags = 0x43 -bor 0x4000

function Get-Title([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 256
  [void][RelW.Api]::GetWindowText($h, $sb, 256)
  return $sb.ToString()
}

$targets = @()
if ($Hwnd -ne 0) {
  $h = [IntPtr]$Hwnd
  if ([RelW.Api]::IsWindow($h)) { $targets = @($h) }
} else {
  $p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) {
    if ($Json) { '{"status":"NO_PROCESS","process":"' + $ProcessName + '"}' } else { "NO_PROCESS $ProcessName" }
    exit 2
  }
  $script:found = @()
  $cb = [RelW.Api+EnumProc]{
    param($h, $l)
    $pid2 = [uint32]0
    [void][RelW.Api]::GetWindowThreadProcessId($h, [ref]$pid2)
    if ($pid2 -eq $p.Id) { $script:found += $h }
    return $true
  }
  [void][RelW.Api]::EnumWindows($cb, [IntPtr]::Zero)
  $targets = @($script:found)
}

$cleared = @()
$already = @()
foreach ($h in $targets) {
  $ex = [RelW.Api]::GetWindowLong($h, -20)
  $wasTopmost = [bool]($ex -band $WS_EX_TOPMOST)
  if ($wasTopmost) {
    [void][RelW.Api]::SetWindowPos($h, $HWND_NOTOPMOST, 0, 0, 0, 0, $flags)
    $cleared += [pscustomobject]@{ hwnd = [int64]$h; title = (Get-Title $h) }
  } else {
    $already += [pscustomobject]@{ hwnd = [int64]$h; title = (Get-Title $h) }
  }
}

# read back rather than trust the call: this is the whole point of the tool
Start-Sleep -Milliseconds 250
$still = @()
foreach ($h in $targets) {
  if ([RelW.Api]::GetWindowLong($h, -20) -band $WS_EX_TOPMOST) { $still += [int64]$h }
}

$status = if ($still.Count) { 'STILL_TOPMOST' } else { 'RELEASED' }
if ($Json) {
  [pscustomobject]@{
    status     = $status
    windows    = $targets.Count
    cleared    = @($cleared)
    was_clear  = @($already)
    still_topmost = @($still)
  } | ConvertTo-Json -Compress -Depth 4
} else {
  "RELEASE $status windows=$($targets.Count) cleared=$($cleared.Count) already_clear=$($already.Count)"
  foreach ($c in $cleared) { "  cleared hwnd=$($c.hwnd) '$($c.title)'" }
  foreach ($s in $still) { "  STILL topmost hwnd=$s" }
}
if ($status -eq 'STILL_TOPMOST') { exit 3 }
exit 0
