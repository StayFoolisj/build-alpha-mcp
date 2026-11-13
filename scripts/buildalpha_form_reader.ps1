<#
.SYNOPSIS
  Read every labelled field from a BuildAlpha form window (Re-Run or
  Strategy Builder) into a text record.

.DESCRIPTION
  Targets a visible BuildAlpha window by title, walks each top-level tab
  (e.g. "Main" and "Additional Settings"), and writes label/value lines.
  Handles the two structures used by these forms:
    * GroupBoxes  - checkbox label + unit sub-tabs (ATR / Fixed / %) + spins
    * LayoutItems - a label pane wrapping one value control
  Values are read with UI Automation (ValuePattern / TogglePattern), so no
  OCR or clicking on individual fields is needed - only the tab switch.

.PARAMETER Title
  Window title, e.g. 'Re-Run' or 'Strategy Builder'.

.PARAMETER OutFile
  Output path. Default: '<slug>-fields.txt'.

.PARAMETER ListTabs
  Print the tab names and exit.

.PARAMETER CurrentTabOnly
  Read only the currently selected tab (do not switch tabs).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_form_reader.ps1 -Title 'Re-Run'
#>
param(
  [string]$Title = 'Re-Run',
  [string]$OutFile = '',
  [switch]$ListTabs,
  [switch]$CurrentTabOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

function Fail([string]$Message) {
  Write-Output "ERROR: $Message"
  exit 1
}

$win = Get-BAWindowByTitle $Title
if (-not $win) {
  $main = Get-MainWindow
  $names = @()
  if ($main) {
    foreach ($h in (Get-VisibleWindows $main.Current.ProcessId)) {
      $t = Get-WindowTitle $h
      if ($t) { $names += "'$t'" }
    }
  }
  Fail "window '$Title' not found. Open windows: $($names -join ', ')"
}

$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$rect = $win.Current.BoundingRectangle
if (-not $OutFile) {
  $slug = ($Title.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  $OutFile = "$slug-fields.txt"
}

$tabs = @(Get-FormTabs $win)
if ($ListTabs) {
  Write-Output "tabs: $(($tabs | ForEach-Object { $_.Current.Name }) -join ' | ')"
  exit 0
}
if ($CurrentTabOnly -or $tabs.Count -eq 0) {
  $tabs = @($null)   # single unnamed section
}

# Remember the original tab so we can restore it afterwards.
$original = $tabs[0]
foreach ($t in $tabs) {
  $sip = $null
  if ($t -and $t.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sip)) {
    if ($sip.Current.IsSelected) { $original = $t; break }
  }
}

$out = New-Object System.Collections.Generic.List[string]
$out.Add('# BuildAlpha form record')
$out.Add("# window   : $Title")
$out.Add("# hwnd     : $hwnd")
$out.Add("# rect     : $([int]$rect.X),$([int]$rect.Y),$([int]$rect.Width),$([int]$rect.Height)")
$out.Add("# captured : $(Get-Date -Format o)")
$out.Add('')
$total = 0

foreach ($tab in $tabs) {
  $tabName = 'Main'
  if ($tab) {
    $tabName = $tab.Current.Name
    Select-FormTab $tab
  }
  $fields = @(Read-FormFields $win)
  Write-Output "tab '$tabName': $($fields.Count) fields"

  $out.Add("== TAB: $tabName ==")
  if ($fields.Count -eq 0) { $out.Add('(no labelled fields found)') }
  foreach ($f in $fields) {
    $out.Add(("{0}`t{1}`t[{2}]" -f $f.Label, $f.Value, $f.Kind))
    $total++
  }
  if ($tabName -eq 'Main') {
    $rules = @(Read-FormRules $win)
    if ($rules.Count -gt 0) { $out.Add('== RULES ==') }
    foreach ($r in $rules) {
      $out.Add(("RULE`t{0}`t{1}" -f $r.Flags, $r.Text))
    }
    Write-Output "tab 'Main': $($rules.Count) rules"
  }
  $out.Add('')
}

# Restore the tab the user had open.
if ($original -and -not $CurrentTabOnly -and $tabs.Count -gt 1) { Select-FormTab $original }

$out | Out-File -Encoding utf8 $OutFile
Write-Output "WROTE: $OutFile ($total fields)"
