# buildalpha_symbol_lookup.ps1 - find a symbol in Settings > Symbols, reliably.
#
#   .\buildalpha_symbol_lookup.ps1 -Symbol xyz_CL
#   .\buildalpha_symbol_lookup.ps1 -Symbol ZEC -Close
#
# What it does (all of it verified, nothing assumed):
#   1. ensures the Settings window is open  (delegates to buildalpha_settings.ps1)
#   2. records the search panel value and the total row count (baseline)
#   3. sets the search value via ValuePattern - no keystrokes, so characters like
#      '@', '(', '[' cannot be mangled - and waits for the row count to settle
#   4. reads row 1 of the filtered grid via UI Automation (Name, Time, Unit, Type,
#      Point Value, Tick Data File, Filename) and compares Name for an EXACT match
#   5. restores the original search value and the baseline row count
#
# Status values (exit code):
#   FOUND_EXACT (0)  exactly one row, and its Name equals -Symbol
#   AMBIGUOUS  (4)   more than one row matched; re-run with the full symbol name
#   NAME_MISMATCH (5) one row matched but its Name is different (a substring hit
#                     in some other column, e.g. the Description)
#   NOT_FOUND  (3)   no rows matched
#   NO_SETTINGS (2)  the Settings window could not be opened
#
# The search panel matches substrings across ALL columns, so a query is only
# conclusive when the row count is 1 and the Name column equals it exactly. Note
# that queries like 'e' or 'C' match every row (the Time Zone string contains
# "Coordinated"), which is why this script reports the count instead of trusting
# a single hit.

param(
  [Parameter(Mandatory = $true)][string]$Symbol,
  [int]$SettleMs = 6000,
  [switch]$Close,
  [switch]$Json
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

$COLUMNS = 'Name', 'Time', 'Unit', 'Variation', 'Description', 'Time Zone', 'Is DST',
  'Point Value', 'Margin', 'Session End', 'Currency', 'Type', 'Min Tick', 'Min size',
  'Swap', 'Slippage File', 'Tick Data File', 'Filename'

function Get-SettingsHwnd($proc) {
  foreach ($h in [BAW]::VisibleTopLevel([uint32]$proc.Id)) {
    if ([BAW]::Title($h) -eq 'Settings') { return $h }
  }
  return [IntPtr]::Zero
}

function Get-Part($sw, [string]$name) {
  return $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, $name)))
}

function Get-GridRows([object]$grid) {
  $gp = $null
  if ($grid -and $grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)) {
    return [int]$gp.Current.RowCount
  }
  return -1
}

function Wait-RowCount([object]$grid, [int]$target, [int]$settleMs, [switch]$AtMost) {
  $deadline = (Get-Date).AddMilliseconds($settleMs)
  $last = Get-GridRows $grid
  $stable = 0
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $now = Get-GridRows $grid
    if ($now -eq $last) { $stable++ } else { $stable = 0; $last = $now }
    if ($AtMost) { if ($now -le $target) { return $now } }
    elseif ($stable -ge 2) { return $now }
  }
  return $last
}

# The find panel filters ~1.2 s after the text changes (debounce), so "wait until
# the count stops changing" would return the OLD baseline. Wait for a CHANGE first,
# then for the count to settle for ~1 s. If the query matches everything the count
# legitimately never changes, in which case the baseline is the answer.
function Wait-FilterChange([object]$grid, [int]$baseline, [int]$settleMs) {
  $deadline = (Get-Date).AddMilliseconds($settleMs)
  $changedAt = $null
  $last = Get-GridRows $grid
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $now = Get-GridRows $grid
    if ($now -ne $last) { $last = $now; $changedAt = Get-Date }
    elseif ($changedAt -and ((Get-Date) - $changedAt).TotalMilliseconds -ge 900) { return $now }
  }
  return $last
}

function Read-Row1([object]$grid) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Custom)
  $values = @{}
  foreach ($c in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    $m = [regex]::Match($c.Current.Name, '^Row 1 of \d+, Column (.+?), Column (\d+) of \d+: (.*)$')
    if (-not $m.Success) { continue }
    $col = $m.Groups[1].Value
    if (-not $values.ContainsKey($col)) { $values[$col] = $m.Groups[3].Value }
  }
  return $values
}

# Best effort list of the filtered rows: select all + copy yields a TSV with the
# header line, which is the only channel that returns every row (UI Automation
# only materialises row 1 of a filtered grid). Returns @() when the copy fails.
function Copy-FilteredRows([object]$grid) {
  $dbg = $env:BA_LOOKUP_DEBUG -eq '1'
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Custom)
  $anchor = $null
  foreach ($c in $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    if ($c.Current.Name -notmatch '^Row 1 of \d+, Column Name, ') { continue }
    $b = $c.Current.BoundingRectangle
    if (-not [double]::IsNaN($b.X) -and $b.Width -gt 10) { $anchor = $b; break }
  }
  if ($anchor) {
    $px = [int]($anchor.X + $anchor.Width / 2)
    $py = [int]($anchor.Y + $anchor.Height / 2)
    if ($dbg) { Write-Host "DEBUG anchor=$($anchor.X),$($anchor.Y) click=$px,$py" }
    Invoke-LeftClick $px $py
  } else {
    $g = $grid.Current.BoundingRectangle
    if ($dbg) { Write-Host "DEBUG no anchor; grid rect=$g" }
    Invoke-LeftClick ([int]($g.X + 60)) ([int]($g.Y + 60))
  }
  Start-Sleep -Milliseconds 400
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 400
  Set-Clipboard -Value 'BA_COPY_PROBE'
  Start-Sleep -Milliseconds 150
  [System.Windows.Forms.SendKeys]::SendWait('^c')
  Start-Sleep -Milliseconds 1400
  $tsv = Get-Clipboard -Raw
  if ($dbg) { Write-Host "DEBUG clipboardLen=$(if ($tsv) { $tsv.Length } else { 0 }) isProbe=$($tsv -eq 'BA_COPY_PROBE')" }
  if (-not $tsv -or $tsv -eq 'BA_COPY_PROBE') { return @() }
  $lines = @($tsv -split "`r?`n" | Where-Object { $_ -ne '' })
  if ($lines.Count -lt 2) { return @() }
  $headers = $lines[0].Split("`t")
  $out = @()
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    $fields = $line.Split("`t")
    $row = @{}
    for ($i = 0; $i -lt $headers.Count -and $i -lt $fields.Count; $i++) { $row[$headers[$i]] = $fields[$i] }
    $out += $row
  }
  return $out
}

try {
  $proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { throw 'NO_BUILDALPHA' }

  $hwnd = Get-SettingsHwnd $proc
  if ($hwnd -eq [IntPtr]::Zero) {
    $out = & "$PSScriptRoot\buildalpha_settings.ps1" -Action open
    if ($LASTEXITCODE -ne 0) { throw "SETTINGS_OPEN_FAILED: $($out -join ' ')" }
    $hwnd = Get-SettingsHwnd $proc
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

  $pane = Get-Part $sw 'SearchPanel'
  if (-not $pane) { throw 'NO_SEARCH_PANEL' }
  $edit = $pane.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
  if (-not $edit) { throw 'NO_SEARCH_BOX' }
  $vp = $null
  if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { throw 'SEARCH_BOX_NO_VALUEPATTERN' }

  $original = $vp.Current.Value
  $baseline = Get-GridRows $grid

  # start from a clean panel: an empty query must reproduce the baseline count
  if ($original -ne '') {
    $vp.SetValue('')
    [void](Wait-FilterChange $grid $baseline $SettleMs)
    $baseline = Get-GridRows $grid
  }

  $vp.SetValue($Symbol)
  $rows = Wait-FilterChange $grid $baseline $SettleMs
  # the search box must echo what we asked for; otherwise nothing was applied
  $echo = $vp.Current.Value
  if ($echo -ne $Symbol) { throw "SEARCH_NOT_APPLIED echo='$echo'" }

  $values = @{}
  if ($rows -ge 1) { $values = Read-Row1 $grid }

  # for an ambiguous query, list what actually matched (best effort)
  $candidates = @()
  if ($rows -gt 1) {
    try { $candidates = @(Copy-FilteredRows $grid) } catch { $candidates = @() }
    if ($candidates.Count -ne $rows) {
      if ($candidates.Count -gt 0) { "WARN candidates=$($candidates.Count) rows=$rows (partial copy discarded)" }
      $candidates = @()
    }
  }

  $name = $values['Name']
  $status = 'NOT_FOUND'
  $code = 3
  if ($rows -eq 1 -and $name -eq $Symbol) { $status = 'FOUND_EXACT'; $code = 0 }
  elseif ($rows -eq 1 -and $name) { $status = 'NAME_MISMATCH'; $code = 5 }
  elseif ($rows -gt 1) { $status = 'AMBIGUOUS'; $code = 4 }
  elseif ($rows -eq 0) { $status = 'NOT_FOUND'; $code = 3 }

  $tf = ''
  if ($values['Time'] -or $values['Unit']) { $tf = "$($values['Time'])$($values['Unit'])" }

  # put the search box back the way we found it, and prove the grid is restored
  $vp.SetValue($original)
  $restored = Wait-FilterChange $grid $rows $SettleMs
  $restoredOk = ($restored -eq $baseline)

  $result = [ordered]@{
    symbol        = $Symbol
    status        = $status
    rows_matched  = $rows
    name          = $name
    description   = $values['Description']
    timeframe     = $tf
    type          = $values['Type']
    point_value   = $values['Point Value']
    margin        = $values['Margin']
    currency      = $values['Currency']
    time_zone     = $values['Time Zone']
    tick_data_file = $values['Tick Data File']
    filename      = $values['Filename']
    rows_baseline = $baseline
    rows_restored = $restored
    search_restored = $restoredOk
    candidates    = @($candidates | ForEach-Object { $_['Name'] })
  }

  if ($Json) {
    $result | ConvertTo-Json -Depth 4
  } else {
    "LOOKUP status=$status rows=$rows code=$code"
    foreach ($k in $result.Keys) { "  $k=$($result[$k])" }
    foreach ($c in $candidates) {
      "  candidate: $($c['Name'])  [$($c['Type'])] $($c['Description'])"
    }
  }

  if ($Close) { & "$PSScriptRoot\buildalpha_settings.ps1" -Action close | Out-Null }

  if (-not $restoredOk) {
    "WARN search panel not restored (rows=$restored baseline=$baseline)"
    exit 6
  }
  exit $code
} catch {
  "ERROR $($_.Exception.Message)"
  exit 2
}
