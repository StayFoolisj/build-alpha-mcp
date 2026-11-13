# buildalpha_symbol_cell.ps1 - reliably read or write ONE cell in Settings > Symbols.
#
#   .\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Value ''
#   .\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Value 'abc'
#   .\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Get
#   .\buildalpha_symbol_cell.ps1 -Symbol xyz_CL -Column Variation -Value '' -DryRun
#
# Why this works when naive clicking does not (all of it measured, not assumed):
#
#   1. The find panel debounces ~1.2 s, so you must wait for the row count to
#      CHANGE and then settle - waiting for "stable" returns the old count.
#   2. Cells have no reliable geometry in UI Automation, but the column HEADERS
#      do. A cell point is therefore derived from its header rect: the header's
#      horizontal centre, plus the first data row's y (header bottom + 10).
#   3. The in-place editor is only exposed once it is actually open, and its name
#      gains a "TextEdit" prefix. Keys sent before that are delivered to the GRID,
#      which is how earlier attempts silently typed into the wrong cell or
#      appended instead of replacing. So: click, press one throwaway char, then
#      CONFIRM the editor is open before sending anything else.
#   4. With the editor open, Ctrl+A really does select the whole text (it is the
#      grid's own select-all that does not apply inside the editor). Hence
#      Ctrl+A + Delete clears a cell, and Ctrl+A + paste replaces it.
#   5. A commit is verified by reading the cell back, with a short poll because
#      the automation peer can lag a beat behind the commit.
#
# Refuses to run (exit 5) if the filtered grid's row 1 Name is not exactly
# -Symbol, so a stray keystroke can never land on another symbol's row.
#
# Exit codes: 0 OK / 2 setup failed / 3 symbol not found or ambiguous /
#             4 cell not reachable or not writable / 5 write did not verify /
#             6 search panel not restored

param(
  [Parameter(Mandatory = $true)][string]$Symbol,
  [Parameter(Mandatory = $true)][string]$Column,
  [string]$Value = $null,
  # Optional find-panel text, for when the symbol name alone matches several rows:
  # the panel searches every column, so 'ETH' also hits 'TRUETH' and 'HYPE' hits ~25
  # rows. Identity is still verified against -Symbol, never against -Query.
  [string]$Query = '',
  [switch]$Clear,
  [switch]$Get,
  [switch]$DryRun,
  [int]$Attempts = 2,
  [int]$SettleMs = 8000
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
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
  public static List<IntPtr> VisibleTopLevel(uint pid) {
    var res = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) res.Add(h); return true; }, IntPtr.Zero);
    return res;
  }
  public static string Title(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
}
'@
}

function Get-SettingsHwnd($proc) {
  foreach ($h in [BAW]::VisibleTopLevel([uint32]$proc.Id)) {
    if ([BAW]::Title($h) -eq 'Settings') { return $h }
  }
  return [IntPtr]::Zero
}
function Get-SearchEdit([IntPtr]$hwnd) {
  $swx = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $panex = $swx.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, 'SearchPanel')))
  if (-not $panex) { return $null }
  return $panex.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
}
function Get-SearchValue([IntPtr]$hwnd) {
  # read through a freshly acquired element: a cached ValuePattern can keep
  # reporting the old text after the box was cleared
  $ed = Get-SearchEdit $hwnd
  if (-not $ed) { return $null }
  $v = $null
  if ($ed.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$v)) { return $v.Current.Value }
  return $null
}
function Get-Rows([object]$grid) {
  $gp = $null
  if ($grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)) { return [int]$gp.Current.RowCount }
  return -1
}
function Wait-FilterChange([object]$grid, [int]$settleMs) {
  $deadline = (Get-Date).AddMilliseconds($settleMs)
  $changedAt = $null
  $last = Get-Rows $grid
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $now = Get-Rows $grid
    if ($now -ne $last) { $last = $now; $changedAt = Get-Date }
    elseif ($changedAt -and ((Get-Date) - $changedAt).TotalMilliseconds -ge 900) { return $now }
  }
  return $last
}
function Get-HeaderRect([object]$grid, [string]$name) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::HeaderItem)
  foreach ($h in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    if ($h.Current.Name -eq $name) {
      $b = $h.Current.BoundingRectangle
      if (-not [double]::IsNaN($b.X) -and $b.Width -gt 5) { return $b }
    }
  }
  return $null
}
function Read-Cell([object]$grid, [string]$column) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Custom)
  foreach ($c in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    # The read regex must accept the editor prefixes too, otherwise a cell that is
    # still in edit mode reads as "not found" instead of its value.
    $m = [regex]::Match($c.Current.Name, '^(?:TextEdit|ButtonEdit)?Row 1 of \d+, Column (.+?), Column \d+ of \d+: (.*)$')
    if ($m.Success -and $m.Groups[1].Value -eq $column) { return $m.Groups[2].Value }
  }
  return $null
}
function Read-Row1Name([object]$grid) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Custom)
  foreach ($c in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    $m = [regex]::Match($c.Current.Name, '^(?:TextEdit)?Row 1 of \d+, Column Name, Column \d+ of \d+: (.*)$')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}
function Get-Row1Y([object]$grid) {
  foreach ($hn in @('Name', 'Time', 'Unit', 'Type', 'Description', 'Point Value')) {
    $h = Get-HeaderRect $grid $hn
    if ($h) { return [int]($h.Y + $h.Height + 10) }
  }
  return $null
}

# A write leaves the in-place editor open, which then swallows the next run's clicks
# (and the search panel's). Path columns use a ButtonEdit that does NOT commit on
# Enter - focus change does - so try another cell, then Tab, then Enter.
function Leave-CellEditor([object]$grid, [int]$cellX, [int]$cellY) {
  $inEdit = (Get-ElementAt $cellX $cellY).Current.Name -match '^(TextEdit|ButtonEdit)'
  if (-not $inEdit) { return $true }
  # click the leftmost VISIBLE cell: named columns like 'Time' may be scrolled away,
  # which is how this used to silently do nothing
  $gridRect = $grid.Current.BoundingRectangle
  $rowY = Get-Row1Y $grid
  if ($rowY) {
    Invoke-LeftClick ([int]($gridRect.X + 60)) $rowY
    Start-Sleep -Milliseconds 800
    if (-not ((Get-ElementAt $cellX $cellY).Current.Name -match '^(TextEdit|ButtonEdit)')) { return $true }
  }
  foreach ($k in @('{TAB}', '{ENTER}', '{TAB}')) {
    [System.Windows.Forms.SendKeys]::SendWait($k)
    Start-Sleep -Milliseconds 700
    if (-not ((Get-ElementAt $cellX $cellY).Current.Name -match '^(TextEdit|ButtonEdit)')) { return $true }
  }
  # last resort: Escape cancels the in-place edit. It also clears the find panel, so
  # this is only used after the search text has been restored (it is here).
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Start-Sleep -Milliseconds 700
  return (-not ((Get-ElementAt $cellX $cellY).Current.Name -match '^(TextEdit|ButtonEdit)'))
}

function Get-CellPoint([object]$grid, [string]$column) {
  # Headers scroll with the columns and have usable geometry, unlike cells. Only the
  # visible headers are realised (offscreen ones report infinite rects), so scroll
  # until the wanted header has a sane rect - but the keys only reach the grid when
  # it has focus, which is why we click a data cell first.
  $gridRect = $grid.Current.BoundingRectangle
  # give the grid keyboard focus by clicking a data cell - NOT a header (that would
  # sort). Any realised header gives the row band's y; 'Name' may be scrolled away.
  $anyH = $null
  foreach ($hn in @('Name', 'Time', 'Unit', 'Type', 'Description')) {
    $anyH = Get-HeaderRect $grid $hn
    if ($anyH) { break }
  }
  if (-not $anyH) {
    $hdrCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::HeaderItem)
    foreach ($h in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $hdrCond)) {
      $b = $h.Current.BoundingRectangle
      if (-not [double]::IsNaN($b.X) -and $b.Width -gt 5 -and $b.Width -lt 2000) { $anyH = $b; break }
    }
  }
  if ($anyH) {
    Invoke-LeftClick ([int]($gridRect.X + 60)) ([int]($anyH.Y + $anyH.Height + 10))
    Start-Sleep -Milliseconds 450
  }
  $sane = {
    param($b)
    if (-not $b) { return $false }
    if ([double]::IsNaN($b.X) -or [double]::IsNaN($b.Width)) { return $false }
    if ($b.Width -lt 5 -or $b.Width -gt 2000) { return $false }
    if ($b.X -lt ($gridRect.X - 50) -or ($b.X + $b.Width) -gt ($gridRect.X + $gridRect.Width + 50)) { return $false }
    return $true
  }
  foreach ($dir in @('{RIGHT}', '{LEFT}')) {
    for ($i = 0; $i -lt 25; $i++) {
      $h = Get-HeaderRect $grid $column
      if (& $sane $h) {
        # aim at the LEFT part of the cell: the centre/right edge can be covered by a
        # ButtonEdit's browse button, which reports itself as 'ButtonEdit' instead of
        # the cell, and would make the wrong-cell guard trip.
        $off = [Math]::Min(20, [int]($h.Width / 4))
        return @{ X = [int]($h.X + $off); Y = [int]($h.Y + $h.Height + 10) }
      }
      [System.Windows.Forms.SendKeys]::SendWait($dir)
      Start-Sleep -Milliseconds 220
    }
  }
  return $null
}

try {
  $proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { throw 'NO_BUILDALPHA' }
  $hwnd = Get-SettingsHwnd $proc
  if ($hwnd -eq [IntPtr]::Zero) {
    $out = & "$PSScriptRoot\buildalpha_settings.ps1" -Action open
    $hwnd = Get-SettingsHwnd $proc
    if ($hwnd -eq [IntPtr]::Zero) { throw "SETTINGS_OPEN_FAILED: $($out -join ' ')" }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw 'NO_SETTINGS' }

  Set-AppForeground $hwnd
  Start-Sleep -Milliseconds 400
  $sw = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $grid = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::DataGrid)))
  if (-not $grid) { throw 'NO_SYMBOL_GRID' }

  $pane = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, 'SearchPanel')))
  $edit = $pane.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
  $vp = $null
  if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { throw 'NO_SEARCH_VALUEPATTERN' }
  $original = $vp.Current.Value
  # A previously filtered panel would make the "baseline" meaningless: reset it. The
  # restored state is then "empty/unfiltered", not whatever filter was left behind -
  # restoring the leftover text would simply re-apply the old filter.
  if ($original -ne '') {
    $vp.SetValue('')
    [void](Wait-FilterChange $grid $SettleMs)
    $original = ''
  }
  $baseline = Get-Rows $grid

  if ($Clear) { $Value = '' }
  if ($null -eq $Value) { throw 'VALUE_REQUIRED (use -Value <text> or -Clear)' }
  $findText = if ($Query) { $Query } else { $Symbol }

  $vp.SetValue($findText)
  $rows = Wait-FilterChange $grid $SettleMs
  if ($rows -eq 0) { "CELL status=SYMBOL_NOT_FOUND symbol='$Symbol' query='$findText'"; exit 3 }
  if ($rows -gt 1) { "CELL status=AMBIGUOUS symbol='$Symbol' query='$findText' rows=$rows"; exit 3 }

  $rowName = Read-Row1Name $grid
  if ($rowName -ne $Symbol) {
    "CELL status=ROW_MISMATCH symbol='$Symbol' row1='$rowName'"
    exit 3
  }

  $before = Read-Cell $grid $Column
  if ($Get) {
    "CELL_READ symbol='$Symbol' column='$Column' value='$before' status=OK"
    $vp.SetValue($original)
    Start-Sleep -Milliseconds 2400
    exit 0
  }
  if ($before -eq $null) { "CELL status=NO_SUCH_COLUMN column='$Column'"; exit 4 }

  if ($DryRun) {
    "CELL status=DRY_RUN symbol='$Symbol' column='$Column' before='$before' target='$Value'"
    $vp.SetValue($original)
    Start-Sleep -Milliseconds 2400
    exit 0
  }

  $pt = Get-CellPoint $grid $Column
  if (-not $pt) { "CELL status=COLUMN_NOT_VISIBLE column='$Column'"; exit 4 }
  # clear any editor left open by an earlier run (best effort - a bare
  # 'TextEdit'/'ButtonEdit' element can also be a persistent child widget, so this is
  # reported but not fatal: the point came from the requested column's own header and
  # the row was verified to be -Symbol, which is what actually prevents a wrong write)
  $leftBefore = Leave-CellEditor $grid $pt.X $pt.Y
  $under = (Get-ElementAt $pt.X $pt.Y).Current.Name
  # A focused path cell exposes its inner control ('ButtonEdit'/'TextEdit') or plain
  # cell text instead of the cell name. That is acceptable: the point came from the
  # requested column's header rect, the grid is filtered to exactly one row, and the
  # write is read back, so a mis-aimed write shows up as VERIFY_MISMATCH rather than
  # as success. A name that cites a *different* column is still refused outright.
  $cellOk = ($under -match "Column $([regex]::Escape($Column)), ") -or
            ($under -match '^(TextEdit|ButtonEdit)') -or
            (-not ($under -match 'Column [A-Za-z]'))
  if (-not $cellOk) {
    "CELL status=WRONG_CELL column='$Column' under='$under' editor_preopen=$(-not $leftBefore)"
    exit 4
  }

  $attempt = 0
  $after = $before
  while ($attempt -lt $Attempts -and $after -ne $Value) {
    $attempt++
    Invoke-LeftClick $pt.X $pt.Y
    Start-Sleep -Milliseconds 500
    # open the in-place editor and confirm it, because keys before this hit the grid.
    # Plain text columns expose 'TextEditRow ...', path columns expose
    # 'ButtonEditRow ...' (a text box with a browse button) - both mean "editor open".
    [System.Windows.Forms.SendKeys]::SendWait('Z')
    Start-Sleep -Milliseconds 700
    $editorOpen = (Get-ElementAt $pt.X $pt.Y).Current.Name -match '^(TextEdit|ButtonEdit)'
    if (-not $editorOpen) {
      Start-Sleep -Milliseconds 500
      [System.Windows.Forms.SendKeys]::SendWait('Z')
      Start-Sleep -Milliseconds 700
      $editorOpen = (Get-ElementAt $pt.X $pt.Y).Current.Name -match '^(TextEdit|ButtonEdit)'
    }
    if (-not $editorOpen) { continue }
    [System.Windows.Forms.SendKeys]::SendWait('^a')      # select-all *inside* the editor
    Start-Sleep -Milliseconds 300
    if ($Value -eq '') {
      [System.Windows.Forms.SendKeys]::SendWait('{DELETE}')
    } else {
      Set-Clipboard -Value $Value
      Start-Sleep -Milliseconds 200
      [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 1200
    for ($i = 0; $i -lt 6; $i++) {
      $after = Read-Cell $grid $Column
      if ($after -eq $Value) { break }
      Start-Sleep -Milliseconds 400
    }
  }

  # Focus the search box before clearing it: with focus still in the grid cell the
  # ValuePattern write can be ignored, which leaves the grid filtered. The element is
  # re-acquired here because the cached one can carry a stale rect after filtering.
  $sw2 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $pane2 = $sw2.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, 'SearchPanel')))
  $edit2 = $pane2.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
  $vp2 = $null
  [void]$edit2.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp2)
  $sb = $edit2.Current.BoundingRectangle
  Invoke-LeftClick ([int]($sb.X + $sb.Width / 2)) ([int]($sb.Y + $sb.Height / 2))
  Start-Sleep -Milliseconds 400
  $vp2.SetValue($original)
  Start-Sleep -Milliseconds 1200
  # Bring the window back to the front: clicks land nowhere if another app took focus
  # while the cell editor was open. Commit the editor first, otherwise the clicks that
  # focus the search box are consumed by it.
  Set-AppForeground $hwnd
  Start-Sleep -Milliseconds 300
  $leftEditor = Leave-CellEditor $grid $pt.X $pt.Y
  $searchNow = Get-SearchValue $hwnd
  for ($k = 0; $k -lt 4 -and $searchNow -ne $original; $k++) {
    # A click that lands on a stale rect, or a ValuePattern write while the grid holds
    # focus, both leave the filter in place - so retry with a fresh rect and a
    # focused clear as the fallback.
    $edit3 = Get-SearchEdit $hwnd
    $b3 = $edit3.Current.BoundingRectangle
    # the first click can be consumed by committing the cell editor; click twice
    Invoke-LeftClick ([int]($b3.X + $b3.Width / 2)) ([int]($b3.Y + $b3.Height / 2))
    Start-Sleep -Milliseconds 250
    Invoke-LeftClick ([int]($b3.X + $b3.Width / 2)) ([int]($b3.Y + $b3.Height / 2))
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 200
    if ($original -eq '') { [System.Windows.Forms.SendKeys]::SendWait('{DELETE}') }
    else { Set-Clipboard -Value $original; [System.Windows.Forms.SendKeys]::SendWait('^v') }
    Start-Sleep -Milliseconds 1000
    $vp3 = $null
    [void](Get-SearchEdit $hwnd).TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp3)
    if ($vp3) { $vp3.SetValue($original) }
    Start-Sleep -Milliseconds 900
    $searchNow = Get-SearchValue $hwnd
  }
  Start-Sleep -Milliseconds 1600
  # RowCount can stay cached on a stale automation element after a filter change,
  # so re-acquire the grid before comparing.
  $grid2 = $sw2.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::DataGrid)))
  $restored = Get-Rows $grid2
  if ($restored -ne $baseline) {
    Start-Sleep -Milliseconds 2000
    $sw2 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $grid2 = $sw2.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataGrid)))
    $restored = Get-Rows $grid2
  }
  $restoredOk = ($restored -eq $baseline -and $searchNow -eq $original)

  "CELL_WRITE symbol='$Symbol' column='$Column' before='$before' target='$Value' after='$after' attempts=$attempt status=$(if ($after -eq $Value) { 'OK' } else { 'VERIFY_MISMATCH' })"
  "SEARCH_RESTORED rows=$restored baseline=$baseline search='$searchNow' editor_left=$leftEditor ok=$restoredOk"
  if ($after -ne $Value) { exit 5 }
  if (-not $restoredOk) { exit 6 }
  exit 0
} catch {
  "ERROR $($_.Exception.Message)"
  exit 2
}
