<#
.SYNOPSIS
  Open BuildAlpha's Variance Testing view from the right-hand navigation menu and save a
  screenshot of that window.

.DESCRIPTION
  The view is not a grid context-menu item. It is a navigation button in the portfolio
  panel's right-hand hamburger menu, exposed to UI Automation as

      ControlType.Button  Name='Variance Testing'  AutomationId='HamburgerMenuNavigationButton'

  so it is opened by invoking that button (no coordinates, no keystroke). If the button
  cannot be found the script falls back to clicking the hamburger button's rectangle, and
  then to opening the menu and sending the item's accelerator key V.

  The capture is PrintWindow with PW_RENDERFULLCONTENT first, so a window that is partly
  behind another still yields its own pixels; if that comes back a flat fill (WPF and
  DevExpress do that sometimes) it raises the window and grabs the screen instead. Either
  way a flat result is reported as BLANK_SHOT rather than saved as if it were the answer,
  and the title is checked so the parent window can never be mistaken for it.

.PARAMETER Out
  PNG path. Default: captures/screens/variance.png

.PARAMETER KeepOpen
  Leave the window open instead of closing it after the capture.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_shot_variance.ps1
#>
param(
  [string]$Out = '',
  [int]$TimeoutSec = 60,
  [switch]$KeepOpen,
  [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

function Fail([string]$Message) {
  Write-Output "ERROR: $Message"
  exit 1
}

if (-not $Out) {
  $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures\screens\variance.png'
}
$outDir = Split-Path $Out -Parent
if (-not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }

$win = Get-MainWindow
if (-not $win) { Fail 'BuildAlpha window not found (is the app running?)' }
$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$procId = $win.Current.ProcessId

function Get-NavButton($root, [string]$name) {
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  return @($all | Where-Object {
      $_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' -and $_.Current.Name -eq $name
    }) | Select-Object -First 1
}

[void](Set-AppForeground $hwnd)
Send-Escape 3
Park-ResultWindows -ProcessId $procId -MainHwnd $hwnd

$nav = Get-NavButton $win 'Variance Testing'
if ($nav) {
  $nr = $nav.Current.BoundingRectangle
  Write-Output "nav button: 'Variance Testing' at $([int]$nr.Left),$([int]$nr.Top) $([int]$nr.Width)x$([int]$nr.Height)"
} else {
  Write-Output 'nav button not found by name; will try the hamburger menu and the V accelerator'
}
if ($ListOnly) {
  $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Output 'navigation buttons:'
  foreach ($b in @($all | Where-Object { $_.Current.AutomationId -eq 'HamburgerMenuNavigationButton' })) {
    Write-Output "  '$($b.Current.Name)' offscreen=$($b.Current.IsOffscreen)"
  }
  exit 0
}

# A window with this title may already be parked from an earlier attempt; that is fine, it
# is still the right window, but only report the one we open if a new one appears.
$beforeWindows = @(Get-VisibleWindows $procId)
$opened = $false
if ($nav) {
  $ip = $null
  if ($nav.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) {
    $ip.Invoke()                       # no coordinates, no injection
  } else {
    $nr = $nav.Current.BoundingRectangle
    Invoke-LeftClick ([int]($nr.Left + $nr.Width / 2)) ([int]($nr.Top + $nr.Height / 2))
  }
  $opened = $true
}

$view = [IntPtr]::Zero
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt ($TimeoutSec * 1000)) {
  Start-Sleep -Milliseconds 400
  $cands = @(Get-VisibleWindows $procId | Where-Object { (Get-WindowTitle $_) -match '^Variance Testing' })
  # a real view, not a 1x1 helper window
  $cands = @($cands | Where-Object { $r = Get-WindowRect $_; ($r.Right - $r.Left) -gt 300 -and ($r.Bottom - $r.Top) -gt 200 })
  if ($cands.Count) {
    $view = @($cands | Where-Object { $beforeWindows -notcontains $_ }) | Select-Object -First 1
    if (-not $view) { $view = $cands[0] }    # already open before we asked
    break
  }
}

if ($view -eq [IntPtr]::Zero -and -not $opened) {
  # fallback: open the hamburger menu and send the accelerator
  Write-Output 'fallback: hamburger menu + accelerator V'
  $ham = Get-NavButton $win 'Variance Testing'
  if ($ham) {
    $hr = $ham.Current.BoundingRectangle
    Invoke-LeftClick ([int]($hr.Left + $hr.Width / 2)) ([int]($hr.Top + $hr.Height / 2))
    Start-Sleep -Milliseconds 900
    Send-Keys 'v'
    Start-Sleep -Milliseconds 1500
    $cands = @(Get-VisibleWindows $procId | Where-Object { (Get-WindowTitle $_) -match '^Variance Testing' })
    if ($cands.Count) { $view = $cands[0] }
  }
}

if ($view -eq [IntPtr]::Zero) {
  $now = @(Get-VisibleWindows $procId | ForEach-Object { "'$(Get-WindowTitle $_)'" }) -join ', '
  Fail "no 'Variance Testing' window appeared within ${TimeoutSec}s; open windows: $now"
}
$title = Get-WindowTitle $view
Write-Output "window: '$title' hwnd=$view"

# let it lay out and draw
$last = ''
$stable = 0
for ($i = 0; $i -lt 48; $i++) {
  Start-Sleep -Milliseconds 250
  $r = Get-WindowRect $view
  $sig = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
  if ($sig -eq $last) { $stable++ } else { $stable = 0; $last = $sig }
  if ($stable -ge 4) { break }
}
Start-Sleep -Milliseconds 900
$r = Get-WindowRect $view
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
Write-Output "rect: $($r.Left),$($r.Top) ${w}x${h}"

Add-Type -Namespace BASHOT -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
'@ -ErrorAction SilentlyContinue

function Get-BlankShare($bmp) {
  # share of sampled pixels equal to the most common colour: 1.0 is a single flat fill
  $w = $bmp.Width; $h = $bmp.Height
  $counts = @{}
  $total = 0
  $stepX = [Math]::Max(1, [int]($w / 48))
  $stepY = [Math]::Max(1, [int]($h / 48))
  for ($x = 0; $x -lt $w; $x += $stepX) {
    for ($yy = 0; $yy -lt $h; $yy += $stepY) {
      $c = $bmp.GetPixel($x, $yy).ToArgb()
      $counts[$c] = 1 + ($counts[$c] -as [int])
      $total++
    }
  }
  $max = ($counts.Values | Measure-Object -Maximum).Maximum
  return [double]$max / [double]$total
}

$bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [BASHOT.Native]::PrintWindow($view, $hdc, 2)      # PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
$g.Dispose()
$share = if ($ok) { Get-BlankShare $bmp } else { 1.0 }
Write-Output ("printwindow: ok={0} dominant_share={1:N3}" -f $ok, $share)

if (-not $ok -or $share -gt 0.97) {
  Write-Output 'printwindow gave a flat fill; raising the window and grabbing the screen'
  $bmp.Dispose()
  [void](Set-AppForeground $view)
  Start-Sleep -Milliseconds 800
  $r = Get-WindowRect $view
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size -ArgumentList $w, $h))
  $g.Dispose()
  $share = Get-BlankShare $bmp
  Write-Output ("screen grab: dominant_share={0:N3}" -f $share)
}

if ($share -gt 0.97) {
  $bmp.Dispose()
  Fail 'BLANK_SHOT: every capture of the window came back a flat fill'
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$bytes = (Get-Item $Out).Length
Write-Output "SAVED $Out bytes=$bytes title='$title'"
if (-not $KeepOpen) {
  $closed = Close-WindowChecked -hwnd $view -ProcessId $procId -Allowed @($hwnd)
  Write-Output "closed: $($closed.closed)"
}
exit 0
