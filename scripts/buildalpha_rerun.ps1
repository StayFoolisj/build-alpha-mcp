<#
.SYNOPSIS
  Re-run a BuildAlpha portfolio strategy via its right-click context menu.

.DESCRIPTION
  BuildAlpha's grid row context menu ("GridContextMenu") is CUSTOM-DRAWN: its
  items have no UI-Automation names, so you cannot click "Re-run strategy" by
  name. This script:
    1. restores/foregrounds the Build Alpha window,
    2. finds a real data row (left-clicks a non-editable Symbol cell, then
       right-clicks it) to open the context menu popup,
    3. screenshots the popup window and OCRs it with the built-in
       Windows.Media.Ocr engine,
    4. clicks the menu item whose text matches -Target (default "Re-run strategy").

  Verified against BuildAlpha v3.22.37 (DevExpress 24.2). The re-run reloads the
  strategy's symbol data and re-reads AdditionalData (visible in app.log).

.PARAMETER Target
  Regex to match the menu item text. Default: 're[-\s]?run'  (matches
  "Re-run strategy"). Use 'adjust' for "Run strategy with adjustments".

.PARAMETER Filter
  Text to type into the grid's find panel (Ctrl+F) before locating the row.
  The row is then verified against -ExpectSymbol, so a stale or missing filter
  can never re-run the wrong strategy.

.PARAMETER KeepFilter
  Do not send the four Escape presses used to clear stray dialogs - they also
  close the find panel and drop the filter.

.PARAMETER ExpectSymbol
  Abort unless the Symbol cell of the located row starts with this text
  (e.g. 'ZEC').

.PARAMETER ListOnly
  Only open the menu, OCR it, and print the items; do not click anything.

.PARAMETER RowX
  The x of the cell to open the menu on - normally the centre of a Symbol cell whose selection the
  shared search already proved. With -RowY it replaces the row hunt entirely (see Find-RowPoint),
  so no coordinates are guessed and the menu cannot open on the checkbox or Name column.

.PARAMETER RowY
  Optional Y coordinate of the row to right-click (default: auto-detect the
  first visible data row between y=125 and y=420 at the Symbol column).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_rerun.ps1 -ListOnly
  powershell -ExecutionPolicy Bypass -File .\buildalpha_rerun.ps1
#>
[CmdletBinding()]
param(
  # Plain 'Re-Run': same inputs, stop date moved to today, no settings window - it runs and
  # opens the results. 'adjust' means 'Run strategy with adjustments', which opens the
  # settings form. Matching is anchored: an unanchored 'run' also matched the adjustments
  # entry, which is how a plain re-run silently became an adjustments dialog.
  [string]$Target = '^\s*re[-\s]?run\s*$',
  [switch]$ListOnly,
  [int]$RowY = 0,
[int]$RowX = 0,
  [string]$Filter = '',
  [switch]$KeepFilter,
  [string]$ExpectSymbol = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class BAR {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

# ---- window helpers ---------------------------------------------------------
$win = $null
$ws = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
  [System.Windows.Automation.TreeScope]::Children,
  [System.Windows.Automation.Condition]::TrueCondition)
foreach ($w in $ws) { if ($w.Current.Name -eq 'Build Alpha') { $win = $w } }
if (-not $win) { Write-Error 'Build Alpha window not found. Is the app running?'; exit 1 }
$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$appPid = $win.Current.ProcessId

function Force-Foreground {
  $fg = [BAR]::GetForegroundWindow()
  # SW_RESTORE un-maximises a maximised window, which moves every row and made the row scan
  # below miss. Only a minimised window is restored; a normal one is maximised (the layout the
  # tools work in), and a maximised one is left alone.
  if ([BAR]::IsIconic($hwnd)) { [void][BAR]::ShowWindow($hwnd, 9) }
  elseif (-not [BAR]::IsZoomed($hwnd)) { [void][BAR]::ShowWindow($hwnd, 3) }
  [void][BAR]::BringWindowToTop($hwnd)
  $fgT = [BAR]::GetWindowThreadProcessId($fg, [ref]([uint32]0))
  $tp = [uint32]0
  $tT = [BAR]::GetWindowThreadProcessId($hwnd, [ref]$tp)
  $myT = [BAR]::GetCurrentThreadId()
  [void][BAR]::AttachThreadInput($myT, $tT, $true)
  [void][BAR]::AttachThreadInput($myT, $fgT, $true)
  [void][BAR]::SetForegroundWindow($hwnd)
  [void][BAR]::AttachThreadInput($myT, $fgT, $false)
  [void][BAR]::AttachThreadInput($myT, $tT, $false)
  Start-Sleep -Milliseconds 350
}
function LeftClick($x, $y) {
  [BAR]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 120
  [BAR]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [BAR]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
}
function RightClickAt($x, $y) {
  [BAR]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 120
  [BAR]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [BAR]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
}
function PressEscape { [BAR]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); [BAR]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 200 }

# ---- find a data row (via FromPoint on the Symbol column) --------------------
function Get-GridByPointRect {
  # the grid element's rectangle, via the same hit-test + parent walk used elsewhere
  foreach ($pt in @(@(400, 300), @(600, 400))) {
    $el = [System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($pt[0], $pt[1]))
    for ($i = 0; $i -lt 6 -and $el; $i++) {
      if ($el.Current.AutomationId -eq 'stratGrid') { return $el.Current.BoundingRectangle }
      $el = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($el)
    }
  }
  return $null
}

function Find-RowPoint {
  if ($RowY -gt 0 -and $RowX -gt 0) {
    # Both coordinates were handed in: the shared search (or a caller) already proved this cell is
    # the target row's Symbol cell. Probing from here would only re-guess what we were just told -
    # and a wrong x opens the rename editor (Name column) or toggles a checkbox (column 0).
    return @{ x = $RowX; y = $RowY; name = '(given point)' }
  }
  if ($RowY -gt 0) { $ys = @($RowY) } else { $ys = 80..640 | Where-Object { $_ % 7 -eq 0 } }
  # The window layout decides where the columns are, so try several x positions instead of only
  # x=200: on a freshly started, maximised window the first data row can sit below y=420 and the
  # Symbol column can be left of x=200, which made "Could not find a data row" a false negative.
  foreach ($y in $ys) {
    foreach ($x in @(120, 200, 300, 400)) {
      $el = [System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($x, $y))
      if ($el -and $el.Current.Name -match '^(TextEdit)?Row \d+ of \d+, Column') {
        return @{ x = $x; y = $y; name = $el.Current.Name }
      }
    }
  }
  return $null
}

# ---- open the context menu --------------------------------------------------
Force-Foreground
if ($Filter) {
  # apply the grid's search filter so exactly the intended row is on screen
  Add-Type -AssemblyName System.Windows.Forms
  LeftClick 400 200
  Start-Sleep -Milliseconds 400
  [System.Windows.Forms.SendKeys]::SendWait('^f')
  Start-Sleep -Milliseconds 1000
  [System.Windows.Forms.SendKeys]::SendWait($Filter)
  Start-Sleep -Milliseconds 800
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 2
  Write-Host "Filter: '$Filter'"
} elseif (-not $KeepFilter) {
  for ($i = 0; $i -lt 4; $i++) { PressEscape }
}
# No coordinates and no row hunt possible? Then use the keyboard. Measured 2026-11-03: in an app
# instance whose grid publishes no cells (GetItem null, no cell geometry), the row can still be
# selected and its context menu opened with Shift+F10 - the menu then OCRs exactly as before.
# The caller leaves the wanted row selected (the shared search proves the selection), so this only
# has to focus the grid and ask for the menu.
$keyboardMenu = ($RowY -le 0 -and $RowX -le 0)
$row = if ($keyboardMenu) { @{ x = 0; y = 0; name = '(keyboard)' } } else { Find-RowPoint }
if (-not $keyboardMenu -and -not $row) { Write-Error 'Could not find a data row. Is the portfolio grid visible/loaded?'; exit 1 }
Write-Host "Row: $($row.name)"

if ($ExpectSymbol) {
  # The symbol check needs a rectangle to look at. With no coordinates (keyboard mode) there is no
  # row to hit-test, and the shared search already proved this row's symbol - re-checking here made
  # every such run die with "Wrong row: symbol ''" before any menu was even asked for.
  if ($keyboardMenu) {
    Write-Host 'Row symbol: not re-checked (no grid coordinates; the search proved the row)'
  } else {
  # read the Symbol cell on the same row; never trust the Y coordinate alone
  # Scan across the row for the Symbol cell instead of assuming x=60: the columns move with the
  # window layout, and at x=60 there is the checkbox column on some layouts, which reads ''.
  $sym = ''
  foreach ($sx in @(20, 60, 100, 140, 180, 220, 260, 300, 340, 380)) {
    $symEl = [System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($sx, $row.y))
    if (-not $symEl) { continue }
    $nm = $symEl.Current.Name
    if ($nm -match 'Column Symbol, Column \d+ of \d+: (.*)$') { $sym = $Matches[1].Trim(); break }
    # on some layouts the cell is published as a Group named after its own value
    if ($nm -like "$ExpectSymbol*") { $sym = $nm.Trim(); break }
  }
  Write-Host "Row symbol: '$sym' (expected '$ExpectSymbol*')"
  if ($sym -notlike "$ExpectSymbol*") { Write-Error "Wrong row: symbol '$sym' does not match '$ExpectSymbol'"; exit 6 }
  }
}
if ($keyboardMenu) {
  # SendKeys needs the assembly loaded; the -Filter branch is the only other place that does it
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
  # Focus. After the shared search the filter box is still open and holds the keyboard, so a bare
  # Shift+F10 goes nowhere (measured: the window, or the find panel's pane, keeps focus and no menu
  # appears). Clicking the row puts the keyboard on the grid and keeps the selection - measured with
  # the window maximised at -8,-8, the first data row's centre is 174 px below the window top and the
  # Symbol column starts ~90 px in; that click then Shift+F10 opened the full row menu (24 items,
  # including 'Re-run strategy'), which is what this path needs. Clicking a *guessed grid* offset was
  # wrong; this offset is from the window, and the row is verified by OCR below.
  Start-Sleep -Milliseconds 200
  $wr = New-Object BAR+RECT
  [void][BAR]::GetWindowRect($hwnd, [ref]$wr)
  $rowClickX = [int]$wr.Left + 90
  $rowClickY = [int]$wr.Top + 174
  LeftClick $rowClickX $rowClickY
  Start-Sleep -Milliseconds 350
  # Narration for the failure case: when no menu appears, the question is always "where did the key
  # go?" - so record who owned the foreground and what had focus at the moment of the keystroke.
  $fgNow = [BAR]::GetForegroundWindow()
  $fgPid = [uint32]0; [void][BAR]::GetWindowThreadProcessId($fgNow, [ref]$fgPid)
  try { $fel = [System.Windows.Automation.AutomationElement]::FocusedElement
        Write-Host "keystroke context: foreground hwnd=$fgNow pid=$fgPid focused='$($fel.Current.ControlType.ProgrammaticName) $($fel.Current.Name)'" }
  catch { Write-Host "keystroke context: foreground hwnd=$fgNow pid=$fgPid focused=unreadable" }
  [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
  Start-Sleep -Milliseconds 1100
} else {
  LeftClick $row.x $row.y
  Start-Sleep -Milliseconds 250
  RightClickAt $row.x $row.y
  Start-Sleep -Milliseconds 1100
}

# Locate the popup window: visible, same pid, not the main window, and either a GridContextMenu in its
# tree or - when the app instance publishes no automation properties at all - a window of menu size.
# Measured 2026-11-03: an instance whose grid answers no GetItem and no cell geometry still HAS
# AutomationId on nothing, so the name test alone reported 'menu did not appear' while the menu was
# on screen (241x553 at the click point). Its IME frame (class CiceroUIWndFrame, 200x200 at 200,200)
# is a visible window of the process too, so size and class are what separate them.
function Get-MenuPopup {
  $script:pop = [IntPtr]::Zero
  $script:popFallback = [IntPtr]::Zero
  $script:candidates = @()
  $cb = [BAR+EnumProc]{
    param($w, $l)
    $p = [uint32]0; [void][BAR]::GetWindowThreadProcessId($w, [ref]$p)
    if ($p -eq $appPid -and [BAR]::IsWindowVisible($w) -and $w -ne $hwnd) {
      try {
        # The IME frame is a visible window of this process too. It is titled CiceroUIWndFrame and
        # must never be mistaken for the menu.
        $tb = New-Object System.Text.StringBuilder 256
        [void][BAR]::GetWindowText($w, $tb, 256)
        $title = $tb.ToString()
        if ($title -like 'CiceroUIWndFrame*') { return $true }
        $r = New-Object BAR+RECT
        [void][BAR]::GetWindowRect($w, [ref]$r)
        $rw = $r.Right - $r.Left; $rh = $r.Bottom - $r.Top
        $plausible = ($rw -ge 100 -and $rh -ge 60 -and $rw -le 900 -and $rh -le 900)
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($w)
        if ($ae) {
          $mc = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'GridContextMenu')
          if ($ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $mc)) {
            $script:pop = $w; return $false
          }
          if ("$($ae.Current.AutomationId)" -eq 'GridContextMenu') { $script:pop = $w; return $false }
        }
        if ($plausible) {
          $script:candidates += "hwnd=$w '$title' ${rw}x${rh} at $($r.Left),$($r.Top)"
          if ($script:popFallback -eq [IntPtr]::Zero) { $script:popFallback = $w }
        }
      } catch { $script:candidates += "hwnd=$w probe failed: $($_.Exception.Message.Split('.')[0])" }
    }
    return $true
  }
  [BAR]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  if ($script:pop -eq [IntPtr]::Zero) { return $script:popFallback }
  return $script:pop
}
# ---- OCR engine, created before the menu is opened -----------------------
# Type loading and TryCreateFromUserProfileLanguages cost a second or two; doing it
# here overlaps that with the right-click/window wait instead of serialising it.
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$engine = $null
try { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() } catch { $engine = $null }

$pop = [IntPtr]::Zero
# The popup is transient: a right-click issued while the grid is not focused, or
# while another window takes focus, silently does nothing. Retry with a fresh
# focus + click instead of failing the whole run on the first miss.
for ($attempt = 1; $attempt -le 3 -and $pop -eq [IntPtr]::Zero; $attempt++) {
  for ($i = 0; $i -lt 6 -and $pop -eq [IntPtr]::Zero; $i++) {
    $pop = Get-MenuPopup
    if ($pop -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 400 }
  }
  if ($pop -eq [IntPtr]::Zero -and $attempt -lt 3) {
    Write-Host "context menu attempt $attempt failed; refocusing"
    Force-Foreground
    Start-Sleep -Milliseconds 600
    if ($keyboardMenu) {
      [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
      Start-Sleep -Milliseconds 800
    } else {
      # a left-click on the row re-establishes grid focus without changing it
      LeftClick 400 $row.y
      Start-Sleep -Milliseconds 500
      RightClickAt $row.x $row.y
      Start-Sleep -Milliseconds 800
    }
  }
}
if ($pop -eq [IntPtr]::Zero) {
  Write-Host ("candidate popups: " + (($script:candidates | Select-Object -Last 6) -join ' | '))
  Write-Error 'Context menu (GridContextMenu) did not appear.'; exit 1
}

# ---- OCR the popup window ---------------------------------------------------
$r = New-Object BAR+RECT
[void][BAR]::GetWindowRect($pop, [ref]$r)
$L = $r.Left; $T = $r.Top; $W = ($r.Right - $r.Left); $H = ($r.Bottom - $r.Top)
if ($W -le 0 -or $H -le 0) { Write-Error "Bad popup rect: $W x $H"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($L, $T, 0, 0, (New-Object System.Drawing.Size($W, $H)))
$g.Dispose()
$png = Join-Path $env:TEMP ('ba_menu_' + [guid]::NewGuid().ToString('N') + '.png')
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, $t) {
  $m = $asTaskGeneric.MakeGenericMethod($t); $task = $m.Invoke($null, @($op))
  $task.Wait(-1) | Out-Null; return $task.Result
}
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$sbmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
if (-not $engine) { Write-Error 'Windows.Media.Ocr unavailable on this machine.'; exit 1 }
$ocr = Await ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])

$hit = $null
Write-Host 'Menu items (OCR):'
foreach ($line in $ocr.Lines) {
  Write-Host ("  {0}" -f $line.Text)
  if (-not $hit -and $line.Text -match $Target) {
    $x0 = 1e9; $y0 = 1e9; $x1 = -1e9; $y1 = -1e9
    foreach ($wd in $line.Words) {
      $br = $wd.BoundingRect
      if ($br.X -lt $x0) { $x0 = $br.X }
      if ($br.Y -lt $y0) { $y0 = $br.Y }
      if (($br.X + $br.Width) -gt $x1) { $x1 = $br.X + $br.Width }
      if (($br.Y + $br.Height) -gt $y1) { $y1 = $br.Y + $br.Height }
    }
    $hit = [pscustomobject]@{ Text = $line.Text; X = [int]($L + ($x0 + $x1) / 2); Y = [int]($T + ($y0 + $y1) / 2) }
  }
}

if ($ListOnly) { PressEscape; Write-Host 'ListOnly: menu closed, nothing clicked.'; return }

if (-not $hit -and $Target -ne 'adjust') {
  # OCR sometimes drops the hyphen or adds noise: retry loosely, but never for an entry that
  # mentions adjustments
  foreach ($line in $ocr.Lines) {
    if ($line.Text -match '(?i)adjust') { continue }
    if ($line.Text -match 're[-\s]?run') {
      $x0 = 1e9; $y0 = 1e9; $x1 = -1e9; $y1 = -1e9
      foreach ($wd in $line.Words) {
        $br = $wd.BoundingRect
        if ($br.X -lt $x0) { $x0 = $br.X }
        if ($br.Y -lt $y0) { $y0 = $br.Y }
        if (($br.X + $br.Width) -gt $x1) { $x1 = $br.X + $br.Width }
        if (($br.Y + $br.Height) -gt $y1) { $y1 = $br.Y + $br.Height }
      }
      $hit = [pscustomobject]@{ Text = $line.Text; X = [int]($L + ($x0 + $x1) / 2); Y = [int]($T + ($y0 + $y1) / 2) }
      break
    }
  }
}

if (-not $hit) { PressEscape; Write-Error "Menu item matching '$Target' not found in OCR."; exit 1 }
Write-Host "Clicking '$($hit.Text)' at ($($hit.X),$($hit.Y))"
[BAR]::SetCursorPos($hit.X, $hit.Y); Start-Sleep -Milliseconds 180
[BAR]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[BAR]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1500
Write-Host ("DONE: activated '{0}' for row '{1}'." -f $hit.Text, $row.name)
