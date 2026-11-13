<#
.SYNOPSIS
  Start / query / stop BuildAlpha with the correct working directory.

.DESCRIPTION
  BuildAlpha resolves its data folders RELATIVE to the current working
  directory: the log shows downloads to bare relative paths such as
  `Data\SMHRaw.txt`, and no config file in the install directory carries a data
  path (checked AppConfig.config, HavAppConfig.config, BuildAlpha_x64.exe.config).
  Launching the exe while the working directory is this repository therefore
  creates `Data\`, `DataCache\` and friends *here* - 994 MB in the case that
  prompted this script.

  This launcher always sets -WorkingDirectory to the install directory, so all
  data stays under `C:\Users\sam\BuildAlpha\BuildAlpha\`. Every other script in
  this repository only *attaches* to the running app; none of them start it.

.PARAMETER Action
  status (default) - report pid, start time, window state and where data is
                     currently being written
  start            - launch if not running, wait for the main window
  stop             - close the main window (WM_CLOSE); -Force kills the process

.PARAMETER InstallDir
  Install directory. Defaults to the uninstall registry entry, then to
  C:\Users\sam\BuildAlpha\BuildAlpha.

.PARAMETER TimeoutSec
  How long `start` waits for the 'Build Alpha' window (default 90).

.EXAMPLE
  powershell -File .\buildalpha_start.ps1
  powershell -File .\buildalpha_start.ps1 -Action start
  powershell -File .\buildalpha_start.ps1 -Action stop

.OUTPUTS
  status:  STATUS running=True pid=... started=... window='Build Alpha' data_dir=...
  start :  STARTED pid=... window='Build Alpha' (12s) data_dir=...
           ALREADY_RUNNING pid=...
  stop  :  STOPPED
  errors: INSTALL_NOT_FOUND (2), START_FAILED (3), NO_PROCESS (4), STOP_FAILED (5)
#>
param(
  [ValidateSet('status', 'start', 'stop')]
  [string]$Action = 'status',
  [string]$InstallDir = '',
  [int]$TimeoutSec = 90,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

Add-Type -Namespace BASU -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
'@

function Resolve-InstallDir {
  param([string]$Hint)
  if ($Hint -and (Test-Path (Join-Path $Hint 'BuildAlpha_x64.exe'))) { return (Resolve-Path $Hint).Path }

  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    foreach ($entry in (Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
      if ($entry.DisplayName -like '*Build*Alpha*' -and $entry.InstallLocation) {
        $candidate = $entry.InstallLocation.Trim('"')
        if (Test-Path (Join-Path $candidate 'BuildAlpha_x64.exe')) { return (Resolve-Path $candidate).Path }
      }
      # some installers only record an uninstall/icon path
      if ($entry.DisplayName -like '*Build*Alpha*') {
        foreach ($raw in @($entry.DisplayIcon, $entry.UninstallString)) {
          if (-not $raw) { continue }
          $path = ($raw -replace '^"([^"]+)".*$', '$1' -replace ',?\d+$', '').Trim('"')
          if ($path -like '*BuildAlpha_x64.exe') { return (Resolve-Path (Split-Path $path -Parent)).Path }
        }
      }
    }
  }

  foreach ($candidate in @('C:\Users\sam\BuildAlpha\BuildAlpha', 'C:\BuildAlpha', 'C:\Program Files\BuildAlpha')) {
    if (Test-Path (Join-Path $candidate 'BuildAlpha_x64.exe')) { return (Resolve-Path $candidate).Path }
  }
  return $null
}

function Get-BAProcess {
  Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-DataDir {
  param([string]$Dir)
  foreach ($name in 'Data', 'DataCache') {
    $p = Join-Path $Dir $name
    if (Test-Path $p) {
      $newest = Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $stamp = if ($newest) { $newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
      return "$p (newest file $stamp)"
    }
  }
  return "$Dir (no Data/ yet)"
}

$install = Resolve-InstallDir $InstallDir
if (-not $install) { Write-Output 'INSTALL_NOT_FOUND'; exit 2 }
$exe = Join-Path $install 'BuildAlpha_x64.exe'

switch ($Action) {
  'status' {
    $p = Get-BAProcess
    if (-not $p) { Write-Output "STATUS running=False install=$install"; exit 0 }
    $h = [IntPtr]::Zero
    $title = ''
    foreach ($w in (Get-VisibleWindows $p.Id)) {
      $t = Get-WindowTitle $w
      if ($t -like 'Build Alpha*') { $h = $w; $title = $t; break }
    }
    $iconic = if ($h -ne [IntPtr]::Zero) { [BASU.W]::IsIconic($h) } else { 'n/a' }
    Write-Output ("STATUS running=True pid={0} started={1} window='{2}' minimized={3} data_dir={4}" -f `
        $p.Id, $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss'), $title, $iconic, (Get-DataDir $install))
    exit 0
  }

  'start' {
    $p = Get-BAProcess
    if ($p) {
      Write-Output ("ALREADY_RUNNING pid={0} started={1}" -f $p.Id, $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
      exit 0
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # the whole point: WorkingDirectory must be the install dir, never the repo
    Start-Process -FilePath $exe -WorkingDirectory $install | Out-Null
    for ($i = 0; $i -lt ($TimeoutSec * 2); $i++) {
      Start-Sleep -Milliseconds 500
      $p = Get-BAProcess
      if ($p) {
        foreach ($w in (Get-VisibleWindows $p.Id)) {
          if ((Get-WindowTitle $w) -like 'Build Alpha*') {
            Write-Output ("STARTED pid={0} window='Build Alpha' ({1}s) data_dir={2}" -f `
                $p.Id, [int]$sw.Elapsed.TotalSeconds, (Get-DataDir $install))
            exit 0
          }
        }
      }
    }
    Write-Output ("START_FAILED no window after {0}s" -f $TimeoutSec)
    exit 3
  }

  'stop' {
    $p = Get-BAProcess
    if (-not $p) { Write-Output 'NO_PROCESS'; exit 4 }
    if ($Force) {
      Stop-Process -Id $p.Id -Force
      Write-Output 'STOPPED (killed)'
      exit 0
    }
    $h = [IntPtr]::Zero
    foreach ($w in (Get-VisibleWindows $p.Id)) {
      if ((Get-WindowTitle $w) -like 'Build Alpha*') { $h = $w; break }
    }
    if ($h -eq [IntPtr]::Zero) { Write-Output 'STOP_FAILED main window not found'; exit 5 }
    [void][BASU.W]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    for ($i = 0; $i -lt 40; $i++) {
      Start-Sleep -Milliseconds 500
      if (-not (Get-BAProcess)) { Write-Output 'STOPPED'; exit 0 }
    }
    Write-Output 'STOP_FAILED still running (use -Force to kill)'
    exit 5
  }
}
