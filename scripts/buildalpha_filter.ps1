param(
  [ValidateSet('apply', 'show', 'open')]
  [string]$Action = 'apply',

  # saved filter group to apply to the *existing* results
  [string]$Filter = 'RobustAll',

  # results window to operate on (title substring)
  [string]$Results = 'Continuous Simulation results',

  [int]$TimeoutSec = 120
)

# Post-test filtering for a finished continuous run.
#
#   powershell -File .\buildalpha_filter.ps1 -Action open  -Results XRP-USDT
#   powershell -File .\buildalpha_filter.ps1 -Action show  -Results XRP-USDT
#   powershell -File .\buildalpha_filter.ps1 -Action apply -Filter RobustAll -Results XRP-USDT
#
# Notes learned the hard way:
#  * the results grid peer only exists while the window is foreground (Focus);
#  * 'Test Filters' opens reliably via SetFocus + Space (~0.5 s); a synthetic
#    click often does nothing and InvokePattern can block for a minute;
#  * the 'Test Filters' dialog is custom-drawn (no UIA children) so the group
#    row and Apply are found by OCR and clicked;
#  * the dialog is always closed again, even on failure.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace BFG -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

$script:ProcessId = (Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if (-not $script:ProcessId) { Write-Output 'NO_BUILDALPHA'; exit 2 }

function Focus([IntPtr]$h) {
  [void][BFG.W]::ShowWindow($h, 9)
  $fg = [BFG.W]::GetForegroundWindow()
  $tfg = [BFG.W]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  [void][BFG.W]::AttachThreadInput([BFG.W]::GetCurrentThreadId(), $tfg, $true)
  [void][BFG.W]::SetForegroundWindow($h)
  [void][BFG.W]::AttachThreadInput([BFG.W]::GetCurrentThreadId(), $tfg, $false)
  Start-Sleep -Milliseconds 400
}

function Get-TestFiltersHwnd {
  Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -eq 'Test Filters' } | Select-Object -First 1
}

function Get-ResultsWindow {
  $h = Get-VisibleWindows $script:ProcessId |
    Where-Object { (Get-WindowTitle $_) -like '*Continuous Simulation results*' -and (Get-WindowTitle $_) -like "*$Results*" } |
    Select-Object -First 1
  if (-not $h) { return $null }
  Focus $h
  return [System.Windows.Automation.AutomationElement]::FromHandle($h)
}

function All($win) {
  $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}

function Test-GridVisible($win) {
  if (-not $win) { return $false }
  [bool]($win.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataGrid))))
}

function Get-RowTotal($win) {
  if (-not $win) { return -1 }
  $grid = $win.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataGrid)))
  if ($grid) {
    $gp = $null
    if ($grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp) -and $gp.Current.RowCount -gt 0) { return $gp.Current.RowCount }
  }
  $max = 0
  foreach ($e in (All $win)) {
    $m = [regex]::Match($e.Current.Name, '^Row \d+ of (\d+), Column ')
    if ($m.Success) { $n = [int]$m.Groups[1].Value; if ($n -gt $max) { $max = $n } }
  }
  if ($max -gt 0) { return $max }
  # The accessibility tree sometimes stops exposing the results grid entirely
  # (rows still painted on screen). Counts are then simply unknown - see the
  # 'Known limitations' section of the README. No OCR, no CSV export hacks.
  return -1
}



function Get-FilterExpression($win) {
  if (-not $win) { return '' }
  $panel = (All $win) | Where-Object { $_.Current.AutomationId -eq 'FilteringPanel' } | Select-Object -First 1
  if (-not $panel) { return '' }
  $vp = $null
  if ($panel.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return $vp.Current.Value }
  return ''
}

function Test-Busy($win) {
  if (-not $win) { return $true }
  @((All $win) | Where-Object { $_.Current.Name -match '(?i)metrics calculation|preparing results' }).Count -gt 0
}

function Get-RunState {
  # The results toolbar keeps Pause/Stop/'strat/sec' after a run ends, so the
  # authoritative signal is the Strategy Builder's STOP button.
  $builder = Get-BAWindowByTitle 'Strategy Builder'
  if (-not $builder) { return 'unknown' }
  $stop = (All $builder) | Where-Object {
    $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^STOP continuous simulation'
  } | Select-Object -First 1
  if ($stop) { return 'running' }
  return 'stopped'
}

function Close-TestFiltersDialog {
  for ($i = 0; $i -lt 3; $i++) {
    $h = Get-TestFiltersHwnd
    if (-not $h) { return }
    Close-Window $h
    Start-Sleep -Milliseconds 600
  }
}

# Opens the filter editor. Order matters: SetFocus + Space is fast and does not
# depend on coordinates or a blocking UIA call.
function Open-TestFilters($win) {
  Close-TestFiltersDialog
  $script:openVia = ''
  $script:openSw = [Diagnostics.Stopwatch]::StartNew()

  $btn = (All $win) | Where-Object {
    $_.Current.Name -eq 'Test Filters' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button
  } | Select-Object -First 1
  if (-not $btn) { return $null }

  $waitForDialog = {
    param([int]$ms)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
      Start-Sleep -Milliseconds 100
      $h = Get-TestFiltersHwnd
      if ($h) { return $h }
    }
    return $null
  }

  $script:openVia = 'focus+space'
  try {
    $btn.SetFocus()
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait(' ')
  } catch { }
  $h = & $waitForDialog 8000
  if ($h) { return [pscustomobject]@{ Hwnd = $h; Window = [System.Windows.Automation.AutomationElement]::FromHandle($h) } }

  $script:openVia = 'default-action'
  $legacy = $null
  if ($btn.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$legacy)) {
    try { $legacy.DoDefaultAction() } catch { }
    $h = & $waitForDialog 5000
    if ($h) { return [pscustomobject]@{ Hwnd = $h; Window = [System.Windows.Automation.AutomationElement]::FromHandle($h) } }
  }

  $script:openVia = 'click'
  $r = $btn.Current.BoundingRectangle
  Invoke-LeftClick ([int]($r.Left + $r.Width / 2)) ([int]($r.Top + $r.Height / 2))
  $h = & $waitForDialog 8000
  if ($h) { return [pscustomobject]@{ Hwnd = $h; Window = [System.Windows.Automation.AutomationElement]::FromHandle($h) } }

  $script:openVia = 'invoke'
  $ip = $null
  if ($btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) {
    try { $ip.Invoke() } catch { }
  }
  $h = & $waitForDialog 20000
  if ($h) { return [pscustomobject]@{ Hwnd = $h; Window = [System.Windows.Automation.AutomationElement]::FromHandle($h) } }
  return $null
}

function Find-Word($words, [string]$Text) {
  $words | Where-Object { $_.Text -eq $Text } | Select-Object -First 1
}

# ---- capture + OCR that do not depend on z-order -------------------------
Add-Type -Namespace TFW -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

function Save-WindowPng([IntPtr]$hwnd, [string]$path) {
  Add-Type -AssemblyName System.Drawing
  $r = New-Object TFW.N+RECT
  [void][TFW.N]::GetWindowRect($hwnd, [ref]$r)
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [void][TFW.N]::PrintWindow($hwnd, $hdc, 2)
  $g.ReleaseHdc($hdc); $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

function Get-OcrWordsFromPng([string]$path) {
  Add-Type -AssemblyName System.Drawing
  $src = [System.Drawing.Bitmap]::FromFile($path)
  $scale = 3
  $scaled = New-Object System.Drawing.Bitmap(($src.Width * $scale), ($src.Height * $scale))
  $sg = [System.Drawing.Graphics]::FromImage($scaled)
  $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $sg.DrawImage($src, 0, 0, ($src.Width * $scale), ($src.Height * $scale))
  $sg.Dispose(); $src.Dispose()
  $tmp = Join-Path $env:TEMP ('ba_ocr_' + [guid]::NewGuid().ToString('N') + '.png')
  $scaled.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $scaled.Dispose()

  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $file = Await-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
  $stream = Await-Result ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $dec = Await-Result ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await-Result ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  $res = Await-Result ($eng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
  $out = @()
  foreach ($line in $res.Lines) {
    foreach ($wd in $line.Words) {
      $b = $wd.BoundingRect
      $out += [pscustomobject]@{ Text = $wd.Text; X = [int]($b.X / $scale); Y = [int]($b.Y / $scale) }
    }
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return $out
}

function Raise-Window([IntPtr]$hwnd) {
  Add-Type -Namespace BFGT -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@ -ErrorAction SilentlyContinue
  [void][BFGT.W]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 3)   # TOPMOST
  Start-Sleep -Milliseconds 250
}

# The dialog opens low enough that Apply lands under the taskbar / window-preview
# strip, where clicks and screen OCR both fail. Move it up first.
function Move-WindowIntoView([IntPtr]$hwnd) {
  Add-Type -Namespace BFGT -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@ -ErrorAction SilentlyContinue
  $r = New-Object TFW.N+RECT
  [void][TFW.N]::GetWindowRect($hwnd, [ref]$r)
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  [void][BFGT.W]::SetWindowPos($hwnd, [IntPtr]::Zero, 380, 20, $w, $h, 0x0002 -bor 0x0004)   # NOMOVE off, NOSIZE off, NOZORDER
  Start-Sleep -Milliseconds 500
}

$win = Get-ResultsWindow
if (-not $win) { Write-Output 'NO_RESULTS_WINDOW'; exit 3 }

if ($Action -eq 'open') {
  $dialog = Open-TestFilters $win
  $ms = $script:openSw.ElapsedMilliseconds
  if (-not $dialog) { Write-Output "OPEN_FAILED after ${ms}ms (via=$($script:openVia))"; exit 11 }
  Write-Output "OPEN ok in ${ms}ms (via=$($script:openVia))"
  Close-TestFiltersDialog
  exit 0
}

$before = Get-RowTotal $win
$expressionBefore = Get-FilterExpression $win

if ($Action -eq 'show') {
  if ($before -lt 0) {
    Write-Output 'UNREADABLE results grid is not exposed to UI Automation right now (window shows rows but the grid peer is missing)'
    exit 10
  }
  $busy = Test-Busy $win
  Write-Output "RESULTS total=$before running=$((Get-RunState) -eq 'running') busy=$($busy.ToString().ToLower()) expression='$expressionBefore'"
  exit 0
}

if ((Get-RunState) -eq 'running') {
  Write-Output 'RUNNING the simulation is still generating; stop it before post-filtering'
  exit 9
}

$dialog = Open-TestFilters $win
if (-not $dialog) {
  Close-TestFiltersDialog
  Write-Output "TEST_FILTERS_NOT_OPENED (via=$($script:openVia))"
  exit 4
}

try {
  Move-WindowIntoView $dialog.Hwnd
  Raise-Window $dialog.Hwnd
  Focus $dialog.Hwnd
  $rect = $dialog.Window.Current.BoundingRectangle
  $x = [int]$rect.Left; $y = [int]$rect.Top; $w = [int]$rect.Width; $ht = [int]$rect.Height

  # OCR the window bitmap (PrintWindow), not the screen: the dialog can sit
  # behind another window even when it is the foreground per UIA
  $png = Join-Path $env:TEMP ('ba_tf_' + [guid]::NewGuid().ToString('N') + '.png')
  Save-WindowPng $dialog.Hwnd $png
  $words = @(Get-OcrWordsFromPng $png)
  Remove-Item $png -Force -ErrorAction SilentlyContinue

  # the group list is the left column; ignore the 'Filter Name' field
  $row = $words | Where-Object { $_.Text -eq $Filter -and $_.X -lt 250 -and $_.Y -gt 25 } | Select-Object -First 1
  if (-not $row) {
    $seen = ($words | Where-Object { $_.X -lt 250 } | ForEach-Object { $_.Text }) -join ' '
    Write-Output "FILTER_NOT_FOUND '$Filter' (list words: $seen)"
    exit 5
  }
  Invoke-LeftClick ($x + $row.X - 8) ($y + $row.Y + 8)
  Start-Sleep -Milliseconds 700

  # confirm through the 'Filter Name:' field
  Save-WindowPng $dialog.Hwnd $png
  $field = @(Get-OcrWordsFromPng $png) | Where-Object { $_.Y -gt 25 -and $_.Y -lt 60 -and $_.X -gt 200 }
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  if (-not ($field | Where-Object { $_.Text -eq $Filter })) {
    Write-Output "FILTER_NOT_SELECTED '$Filter' (field shows: $(($field | ForEach-Object { $_.Text }) -join ' '))"
    exit 6
  }

  Save-WindowPng $dialog.Hwnd $png
  $all = @(Get-OcrWordsFromPng $png)
  $apply = $all | Where-Object { $_.Text -match '^Appl' } | Select-Object -First 1
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  if ($apply) {
    Invoke-LeftClick ($x + $apply.X + 12) ($y + $apply.Y + 8)
  } else {
    # OCR does not read this small button; use the measured geometry of the
    # 750x700 dialog (Apply centre at 550,672 -> 0.733 / 0.96 of the window)
    Invoke-LeftClick ($x + [int]($w * 0.733)) ($y + [int]($ht * 0.96))
  }
  Start-Sleep -Seconds 2

  # settle on the row count (the status label never clears). When the grid is not
  # exposed, counting needs a CSV export (~seconds), so do that once, not per poll.
  $after = $before
  if (Test-GridVisible (Get-ResultsWindow)) {
    $stable = 0; $last = -2
    $limit = [math]::Min($TimeoutSec, 90)
    for ($i = 0; $i -lt $limit; $i++) {
      Start-Sleep -Milliseconds 800
      $win = Get-ResultsWindow
      if (-not $win) { break }
      $after = Get-RowTotal $win
      if ($after -eq $last) { $stable++ } else { $stable = 0; $last = $after }
      if ($stable -ge 3) { break }
    }
  } else {
    Start-Sleep -Seconds 6
    $after = Get-RowTotal (Get-ResultsWindow)
  }
  $expression = Get-FilterExpression (Get-ResultsWindow)
  Write-Output "FILTERED filter='$Filter' before=$before after=$after expression='$expression'"
  exit 0
}
finally {
  Close-TestFiltersDialog
}



