param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('prepare', 'show', 'start', 'cancel', 'filters', 'stop')]
  [string]$Action,

  [string]$Symbol = '@S',
  [string]$Timeframe = '1 hour',
  [string]$Start = '',
  [string]$Stop = '',

  # picker group for the symbol (server-side lists group by asset class)
  [string]$Group = 'Crypto',

  # skip the symbol picker (select symbols by hand once, then prepare still sets
  # timeframe/dates, reads everything back and can be started)
  [switch]$SkipSymbol,

  # saved filter group to activate (see -Action filters)
  [string]$Filter = '',

  [string]$PendingFile = 'continuous-pending.json',
  [switch]$Force,
  [switch]$DryRun
)

# Two-phase continuous simulation over BOTH symbol tabs.
#
# Built-in tickers (@ES, @GC, ...) live on the 'Built-in symbols' tab, whose
# picker exposes the same Selection/Name/TF/Description cells as the server-side
# one - the rows are only materialised once the asset-class group (Futures, ETF,
# FOREX, Crypto, Custom) is expanded, which is why they looked 'unreadable'.
# `-Group` defaults to 'Futures' for @-symbols.
#
#   prepare : configure the Strategy Builder (symbol/timeframe/dates) and read
#             every setting back. Does NOT start anything.
#   start   : re-read the form, refuse if it drifted, then click
#             'Continuous simulation' and wait for the run.
#   show    : read the form again (no changes).
#   cancel  : close the builder window and forget the pending request.
#
#   powershell -File .\buildalpha_continuous.ps1 -Action prepare `
#       -Symbol @S -Timeframe '1 hour' -Start 10/18/2024 -Stop 10/18/2026
#   powershell -File .\buildalpha_continuous.ps1 -Action start

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace BAG -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

$script:ProcessId = (Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if (-not $script:ProcessId) { Write-Output 'NO_BUILDALPHA'; exit 2 }

function Focus-Window([IntPtr]$h) {
  [void][BAG.W]::ShowWindow($h, 9)
  $fg = [BAG.W]::GetForegroundWindow()
  $tfg = [BAG.W]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  [void][BAG.W]::AttachThreadInput([BAG.W]::GetCurrentThreadId(), $tfg, $true)
  [void][BAG.W]::SetForegroundWindow($h)
  [void][BAG.W]::AttachThreadInput([BAG.W]::GetCurrentThreadId(), $tfg, $false)
  Start-Sleep -Milliseconds 450
}

function Get-BuilderHwnd {
  Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -eq 'Strategy Builder' } | Select-Object -First 1
}

function Ensure-Builder {
  $h = Get-BuilderHwnd
  if ($h) { Focus-Window $h; return (Get-BAWindowByTitle 'Strategy Builder') }
  $main = Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -like 'Build Alpha*' } | Select-Object -First 1
  if (-not $main) { Write-Output 'NO_MAIN_WINDOW'; exit 2 }
  Focus-Window $main
  [System.Windows.Forms.SendKeys]::SendWait('^n')
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $h = Get-BuilderHwnd
    if ($h) { Start-Sleep -Milliseconds 800; return (Get-BAWindowByTitle 'Strategy Builder') }
  }
  Write-Output 'BUILDER_NOT_OPENED'
  exit 3
}

function Select-Tab($builder, [string]$Name) {
  $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $tab = $all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and $_.Current.Name -eq $Name } | Select-Object -First 1
  if (-not $tab) { return $false }
  $sel = $null
  if ($tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) {
    $sel.Select(); Start-Sleep -Milliseconds 600; return $true
  }
  return $false
}

function Get-PickerWindow([IntPtr]$BuilderHwnd, [int]$TimeoutSec = 8) {
  $mainHwnd = Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -like 'Build Alpha*' } | Select-Object -First 1
  for ($i = 0; $i -lt ($TimeoutSec * 2); $i++) {
    foreach ($h in (Get-VisibleWindows $script:ProcessId)) {
      if ($h -eq $BuilderHwnd -or $h -eq $mainHwnd) { continue }
      $w = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      if (-not $w) { continue }
      $grid = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_GridControl')))
      if ($grid) { return $w }
    }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

function Open-Picker($builder, [string]$SelectorId) {
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    # a leftover picker would be toggled closed by the click below
    $stale = Get-PickerWindow (Get-BuilderHwnd) 2
    if ($stale) { Send-Escape; Start-Sleep -Milliseconds 500 }
    $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $sel = $all | Where-Object { $_.Current.AutomationId -eq $SelectorId } | Select-Object -First 1
    if (-not $sel) { return $null }
    $r = $sel.Current.BoundingRectangle
    Invoke-LeftClick ([int]($r.Left + 20)) ([int]($r.Top + 10))
    $popup = Get-PickerWindow (Get-BuilderHwnd)
    if ($popup) { return $popup }
    Start-Sleep -Milliseconds 800
  }
  return $null
}

function Invoke-Or-Click($el, [int]$x, [int]$y) {
  if ($el) {
    $ip = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); return }
  }
  Invoke-LeftClick $x $y
}

# Selects a symbol in the server-side picker.
#
# The picker is a virtualised group tree, and two behaviours matter:
#  * the search box only matches inside *expanded* nodes, and expanding does not
#    re-run the filter - so the reliable order is search -> Find -> expand ->
#    Find again (measured: 4/4, where expand-then-search was 0/3);
#  * the Selection cell is a TOGGLE: clicking an already-checked row unchecks it,
#    so read the state and only click when it says Unchecked.
# PART_ToggleButton has no InvokePattern, so expansion is a plain click at the
# toggle's coordinates, and the state shift is handled by retrying once.
function Select-PickerSymbol($popup, [string]$GroupName, [string]$SymbolName) {
  $cells = { $popup.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
  $combo = $popup.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchComboBox')))
  if (-not $combo) { return 'search box missing' }
  $vp = $null
  if (-not $combo.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return 'search box not writable' }
  $find = $popup.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchFindButton')))

  $vp.SetValue($SymbolName)
  Start-Sleep -Milliseconds 400
  Invoke-Or-Click $find 0 0            # filter while the tree is still collapsed
  Start-Sleep -Seconds 2

  $cell = $null
  $path = $GroupName -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  for ($attempt = 0; $attempt -lt 2 -and -not $cell; $attempt++) {
    foreach ($level in $path) {
      $els = & $cells
      $row = $els | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $_.Current.Name -eq $level } | Select-Object -First 1
      if (-not $row) { continue }
      # the toggle sits immediately left of the label on the same row
      $toggle = $els | Where-Object {
        $_.Current.AutomationId -eq 'PART_ToggleButton' -and
        [math]::Abs([int]$_.Current.BoundingRectangle.Top - [int]$row.Current.BoundingRectangle.Top) -le 4
      } | Sort-Object { $_.Current.BoundingRectangle.Left } -Descending | Select-Object -First 1
      if ($toggle) {
        $tr = $toggle.Current.BoundingRectangle
        Invoke-LeftClick ([int]($tr.Left + $tr.Width / 2)) ([int]($tr.Top + $tr.Height / 2))
      } else {
        Invoke-LeftClick ([int]($row.Current.BoundingRectangle.Left - 33)) ([int]($row.Current.BoundingRectangle.Top + 8))
      }
      Start-Sleep -Seconds 2
      Invoke-Or-Click $find 0 0        # re-apply the filter to the materialised rows
      Start-Sleep -Seconds 2
      $els = & $cells
      $cell = $els | Where-Object { $_.Current.Name -match ('Column Name, Column \d+ of \d+: ' + [regex]::Escape($SymbolName) + '$') } | Select-Object -First 1
      if ($cell) { break }
    }
  }
  if (-not $cell) { Send-Escape; return "symbol '$SymbolName' not found under '$GroupName'" }

  $rowY = [int]$cell.Current.BoundingRectangle.Top
  $selCell = $els | Where-Object {
    $_.Current.Name -match 'Column Selection, Column \d+ of \d+: ' -and [math]::Abs([int]$_.Current.BoundingRectangle.Top - $rowY) -le 3
  } | Select-Object -First 1
  if (-not $selCell) { return "selection cell for '$SymbolName' not found" }

  if ($selCell.Current.Name -match 'Unchecked') {
    $sr = $selCell.Current.BoundingRectangle
    Invoke-LeftClick ([int]($sr.Left + $sr.Width / 2)) ([int]($sr.Top + $sr.Height / 2))
    Start-Sleep -Milliseconds 700
    $state = ((& $cells) | Where-Object { $_.Current.Name -match 'Column Selection' -and [math]::Abs([int]$_.Current.BoundingRectangle.Top - $rowY) -le 3 } | Select-Object -First 1).Current.Name
    if ($state -notmatch 'Checked') { return "selection did not stick (state '$($state -replace '^.*: ', ''))" }
  }

  $script:LastPickedTF = ''
  $tfCell = $els | Where-Object {
    $_.Current.Name -match 'Column TF, Column \d+ of \d+: ' -and [math]::Abs([int]$_.Current.BoundingRectangle.Top - $rowY) -le 3
  } | Select-Object -First 1
  if ($tfCell) { $script:LastPickedTF = ($tfCell.Current.Name -replace '^.*Column TF, Column \d+ of \d+: ', '') }

  $ok = $popup.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'OK')))
  Invoke-Or-Click $ok 0 0
  Start-Sleep -Milliseconds 900
  return $null
}

function Get-SelectorSymbolCount($builder, [string]$SelectorId) {
  # Both symbol selectors are a LookUpEdit whose PART_Item button carries the
  # number of chosen symbols, e.g. '(1)'. The built-in tab has no ValuePattern
  # and its audit line stays empty, so this is the only readable confirmation.
  $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $sel = $all | Where-Object { $_.Current.AutomationId -eq $SelectorId } | Select-Object -First 1
  if (-not $sel) { return -1 }
  $item = $sel.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PART_Item')))
  if (-not $item) { return -1 }
  $m = [regex]::Match($item.Current.Name, '\((\d+)\)')
  if (-not $m.Success) { return -1 }
  return [int]$m.Groups[1].Value
}

function Set-Timeframe($builder, [string]$SelectorId, [string]$Value) {
  $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $selector = $all | Where-Object { $_.Current.AutomationId -eq $SelectorId } | Select-Object -First 1
  if (-not $selector) { return 'selector missing' }
  $sr = $selector.Current.BoundingRectangle
  $combo = $all | Where-Object {
    $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -and -not $_.Current.AutomationId
  } | Where-Object {
    $c = $_.Current.BoundingRectangle
    (-not $c.IsEmpty) -and [math]::Abs($c.Top - $sr.Top) -le 4 -and $c.Left -gt $sr.Right
  } | Select-Object -First 1
  if (-not $combo) { return 'timeframe combo missing' }
  $vp = $null
  if ($combo.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and $vp.Current.Value -eq $Value) {
    return $null   # already set
  }
  $cr = $combo.Current.BoundingRectangle
  Invoke-LeftClick ([int]($cr.Right - 8)) ([int]($cr.Top + $cr.Height / 2))
  Start-Sleep -Milliseconds 900
  $items = @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)))
  )
  $item = $items | Where-Object { $_.Current.Name -eq $Value } | Select-Object -First 1
  if (-not $item) {
    Send-Escape
    return "timeframe '$Value' not in list: " + (($items | ForEach-Object { $_.Current.Name }) -join ', ')
  }
  $ir = $item.Current.BoundingRectangle
  Invoke-LeftClick ([int]($ir.Left + $ir.Width / 2)) ([int]($ir.Top + $ir.Height / 2))
  Start-Sleep -Milliseconds 700
  $got = if ($combo.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $vp.Current.Value } else { '' }
  if ($got -ne $Value) { return "timeframe did not commit (got '$got')" }
  return $null
}

function Set-DateEdit($builder, [string]$Which, [string]$Value) {
  $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $edits = @($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit } | Where-Object {
    # date editors are 184x22 wrappers; their inner text editors are 162x16
    $r = $_.Current.BoundingRectangle; (-not $r.IsEmpty) -and $r.Width -ge 180 -and $r.Height -ge 20
  })
  $anchor = $all | Where-Object { $_.Current.AutomationId -eq 'startDate' } | Select-Object -First 1
  if (-not $anchor) { return 'startDate edit missing' }
  $ay = [int]$anchor.Current.BoundingRectangle.Top
  $target = if ($Which -eq 'start') {
    $anchor
  } else {
    $edits | Where-Object { [int]$_.Current.BoundingRectangle.Top -gt $ay } | Sort-Object { $_.Current.BoundingRectangle.Top } | Select-Object -First 1
  }
  if (-not $target) { return "$Which date edit missing" }
  $vp = $null
  if (-not $target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return "$Which date not editable" }
  $wanted = $Value.Split(' ')[0]
  $clock = if ($Which -eq 'start') { '12:00:00 AM' } else { '11:59:59 PM' }
  $target.SetFocus()
  Start-Sleep -Milliseconds 200
  $target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) | Out-Null
  $vp.SetValue("$wanted $clock")
  Start-Sleep -Milliseconds 300
  $target.SetFocus()
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')   # Tab alone does not commit the DateEdit
  Start-Sleep -Milliseconds 800
  $got = if ($target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $vp.Current.Value } else { '' }
  if ($got -match [regex]::Escape($wanted)) { return $null }
  return "$Which date did not commit (got '$got')"
}

function Get-ResultsTotal {
  # counts candidates in the results window: cell names carry 'Row n of N'
  $win = Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -like 'Continuous Simulation results*' } | Select-Object -First 1
  if (-not $win) { return -1 }
  $w = [System.Windows.Automation.AutomationElement]::FromHandle($win)
  $max = 0
  foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    $m = [regex]::Match($e.Current.Name, '^Row \d+ of (\d+), Column ')
    if ($m.Success) { $n = [int]$m.Groups[1].Value; if ($n -gt $max) { $max = $n } }
  }
  return $max
}

function Get-StopButton($builder) {
  $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  return $all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^STOP continuous simulation' } | Select-Object -First 1
}

function Read-Form([string]$Title = 'Strategy Builder') {
  $out = Join-Path $env:TEMP ("ba_form_{0}.txt" -f [guid]::NewGuid().ToString('N'))
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\buildalpha_form_reader.ps1" -Title $Title -OutFile $out | Out-Null
  $lines = if (Test-Path $out) { Get-Content $out } else { @() }
  Remove-Item $out -Force -ErrorAction SilentlyContinue
  return $lines
}

# ---------------------------------------------------------------- filter groups
# Saved filters live behind Ctrl+F ('Edit Filters'). Selecting a ListItem there is
# the whole switch: it persists across dialog open/close, and the dialog reopens
# with that item pre-selected, which is how we verify it.
function Open-FilterDialog {
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $bh = Get-BuilderHwnd
    if (-not $bh) { return $null }
    Focus-Window $bh
    [System.Windows.Forms.SendKeys]::SendWait('^f')
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 500
      $h = Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -eq 'Edit Filters' } | Select-Object -First 1
      if ($h) { return [pscustomobject]@{ Hwnd = $h; Window = [System.Windows.Automation.AutomationElement]::FromHandle($h) } }
    }
  }
  return $null
}

function Get-FilterItems($dialog) {
  $els = $dialog.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $items = @()
  foreach ($it in @($els | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem })) {
    $text = ($it.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name } | Select-Object -First 1)
    $sel = $null
    $isSelected = if ($it.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) { $sel.Current.IsSelected } else { $false }
    $items += [pscustomobject]@{ Name = $(if ($text) { $text.Current.Name } else { '' }); Element = $it; Selected = $isSelected }
  }
  return $items
}

function Close-FilterDialog($dialog) {
  Close-Window $dialog.Hwnd
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 300
    if (-not (Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -eq 'Edit Filters' })) { return $true }
  }
  return $false
}

function Set-FilterGroup([string]$Name) {
  $dialog = Open-FilterDialog
  if (-not $dialog) { return 'filter dialog did not open' }
  $items = Get-FilterItems $dialog
  $target = $items | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if (-not $target) {
    $names = ($items | ForEach-Object { $_.Name }) -join ', '
    Close-FilterDialog $dialog | Out-Null
    return "filter '$Name' not found; available: $names"
  }
  if (-not $target.Selected) {
    $sel = $null
    if ($target.Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) {
      $sel.Select()
      Start-Sleep -Milliseconds 700
    }
  }
  Close-FilterDialog $dialog | Out-Null

  # verify: the dialog reopens with the chosen group selected
  $again = Open-FilterDialog
  if (-not $again) { return 'filter dialog did not reopen for verification' }
  $now = (Get-FilterItems $again) | Where-Object { $_.Selected } | Select-Object -First 1
  Close-FilterDialog $again | Out-Null
  if (-not $now -or $now.Name -ne $Name) {
    return "filter did not stick (dialog shows '$(if ($now) { $now.Name } else { '<none>' })')"
  }
  return $null
}

function Show-Audit($lines) {
  $wanted = 'Symbols', 'Start Date', 'Stop Date', 'Strategy Type', 'In Sample minimum trades',
  'Out of Sample minimum trades', 'Out of Sample percent', 'Commission', 'Slippage', 'Fitness function'
  foreach ($line in $lines) {
    $parts = $line -split "`t"
    if ($parts.Count -lt 2) { continue }
    foreach ($w in $wanted) {
      if ($parts[0] -like "*$w*") { "  {0} = {1}" -f $parts[0], $parts[1]; break }
    }
  }
}

$pendingPath = Join-Path $PSScriptRoot $PendingFile

switch ($Action) {
  'prepare' {
    $builtin = $Symbol -like '@*'
    $tabName = if ($builtin) { 'Built-in symbols' } else { 'Server-side symbols' }
    $selectorId = if ($builtin) { 'mainBuildinSymbolsSelector' } else { 'mainServerSymbolsSelector' }
    if ($builtin -and -not $Group) { $Group = 'Futures' }

    $builder = Ensure-Builder
    if (-not $builder) { 'BUILDER_NOT_OPENED'; exit 3 }
    Focus-Window (Get-BuilderHwnd)

    if (-not (Select-Tab $builder $tabName)) { "TAB_NOT_FOUND $tabName"; exit 4 }

    $popup = Open-Picker $builder $selectorId
    if ($SkipSymbol) {
      if ($popup) { Send-Escape; Start-Sleep -Milliseconds 600 }
      Write-Output 'SYMBOL_STEP_SKIPPED (using the symbols already in the form)'
    } else {
      if (-not $popup) { 'PICKER_NOT_OPENED'; exit 5 }
      $errorText = Select-PickerSymbol $popup $Group $Symbol
      if ($errorText -and $builtin) {
        # built-in rows are grouped by asset class; try the other classes before
        # giving up so the caller need not know that @BC sits under 'Futures'
        foreach ($g in 'Futures', 'ETF', 'FOREX', 'Crypto', 'Custom') {
          if ($g -eq $Group) { continue }
          $popup = Open-Picker $builder $selectorId
          if (-not $popup) { break }
          $errorText = Select-PickerSymbol $popup $g $Symbol
          if (-not $errorText) { $Group = $g; break }
        }
      }
      if ($errorText) { "SYMBOL_FAILED $errorText"; exit 6 }
    }

    if ($builtin) {
      # the built-in tab has no timeframe combo: the TF column of the picked row
      # ('@ES  1 hour') is what the strategy runs on
      Write-Output 'TIMEFRAME_SKIPPED (built-in symbols carry their own timeframe)'
    } else {
      $errorText = Set-Timeframe $builder $selectorId $Timeframe
      if ($errorText) { "TIMEFRAME_FAILED $errorText"; exit 7 }
    }

    if ($Start) { $errorText = Set-DateEdit $builder 'start' $Start; if ($errorText) { "START_FAILED $errorText"; exit 8 } }
    if ($Stop) { $errorText = Set-DateEdit $builder 'stop' $Stop; if ($errorText) { "STOP_FAILED $errorText"; exit 9 } }

    if ($Filter) {
      $errorText = Set-FilterGroup $Filter
      if ($errorText) { "FILTER_FAILED $errorText"; exit 14 }
    }

    $lines = Read-Form
    if (-not $SkipSymbol) {
      if ($builtin) {
        # the audit line for the built-in tab is empty by design; trust the count
        $count = Get-SelectorSymbolCount $builder $selectorId
        if ($count -lt 1) { "SYMBOL_NOT_IN_FORM wanted=$Symbol selector_count=$count"; exit 13 }
        Write-Output "symbol count : $count"
      } else {
        # the picker can look successful and still not commit; trust only the form
        $symbolLine = ($lines | Where-Object { $_ -like "Symbols`t*" } | Select-Object -First 1) -split "`t" | Select-Object -Index 1
        if ($symbolLine -notmatch [regex]::Escape($Symbol)) {
          Write-Output "SYMBOL_NOT_IN_FORM wanted=$Symbol form='$symbolLine'"
          exit 13
        }
      }
    }
    $request = [ordered]@{
      prepared_at = (Get-Date).ToString('o')
      action      = 'continuous simulation'
      symbol      = $Symbol
      symbol_step = if ($SkipSymbol) { 'skipped' } else { 'picker' }
      timeframe   = $Timeframe
      row_timeframe = "$($script:LastPickedTF)"
      market      = if ($builtin) { 'builtin' } else { 'server' }
      group       = $Group
      filter      = $Filter
      start       = $Start
      stop        = $Stop
      # strings only: Read-Form can emit other objects, and the pending file is
      # parsed by the MCP server / next phase
      settings    = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $request | ConvertTo-Json -Depth 5 | Set-Content -Path $pendingPath -Encoding UTF8

    Write-Output "PREPARED symbol=$Symbol timeframe=$Timeframe row_timeframe=$($script:LastPickedTF) start=$Start stop=$Stop"
    Write-Output '--- settings read back ---'
    Show-Audit $lines
    if ($Filter) { Write-Output "  Filter group = $Filter" }
    Write-Output "pending: $pendingPath"
    exit 0
  }

  'filters' {
    $dialog = Open-FilterDialog
    if (-not $dialog) { 'FILTER_DIALOG_NOT_OPENED'; exit 15 }
    $items = Get-FilterItems $dialog
    Close-FilterDialog $dialog | Out-Null
    Write-Output "FILTERS count=$($items.Count)"
    foreach ($i in $items) { Write-Output ('FILTER' + "`t" + $i.Name + "`t" + $(if ($i.Selected) { 'selected' } else { '' })) }
    exit 0
  }

  'show' {
    $builder = Get-BAWindowByTitle 'Strategy Builder'
    if (-not $builder) { 'NO_BUILDER'; exit 2 }
    Show-Audit (Read-Form)
    exit 0
  }

  'start' {
    if (-not (Test-Path $pendingPath)) { "NO_PENDING $pendingPath"; exit 2 }
    $pending = Get-Content $pendingPath -Raw | ConvertFrom-Json
    $builder = Get-BAWindowByTitle 'Strategy Builder'
    if (-not $builder) { 'NO_BUILDER (run -Action prepare)'; exit 2 }

    $lines = Read-Form
    $symbols = ($lines | Where-Object { $_ -like "Symbols`t*" } | Select-Object -First 1) -split "`t" | Select-Object -Index 1
    $startNow = ($lines | Where-Object { $_ -like "Start Date`t*" } | Select-Object -First 1) -split "`t" | Select-Object -Index 1
    $stopNow = ($lines | Where-Object { $_ -like "Stop Date`t*" } | Select-Object -First 1) -split "`t" | Select-Object -Index 1

    Write-Output "prepare wanted: $($pending.symbol) $($pending.timeframe) $($pending.start) -> $($pending.stop)"
    Write-Output "form now     : $symbols | $startNow -> $stopNow"
    if (-not $Force) {
      if ($pending.start -and $startNow -and $startNow -notmatch [regex]::Escape($pending.start.Split(' ')[0])) {
        'REFUSING start: start date drifted (use -Force to override)'; exit 10
      }
      if ($pending.stop -and $stopNow -and $stopNow -notmatch [regex]::Escape($pending.stop.Split(' ')[0])) {
        'REFUSING start: stop date drifted (use -Force to override)'; exit 10
      }
      if ($symbols -and $symbols -notmatch [regex]::Escape($pending.symbol)) {
        'REFUSING start: symbols drifted (use -Force to override)'; exit 10
      }
    }

    Focus-Window (Get-BuilderHwnd)
    if ($DryRun) { 'DRY_RUN verified, not clicking Continuous simulation'; exit 0 }
    $all = $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $run = $all | Where-Object { $_.Current.Name -eq 'Continuous simulation' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button } | Select-Object -First 1
    if (-not $run) { 'RUN_BUTTON_NOT_FOUND'; exit 11 }
    $before = @(Get-VisibleWindows $script:ProcessId)
    Invoke-Or-Click $run 0 0

    $jobWindow = $null
    for ($i = 0; $i -lt 90; $i++) {
      Start-Sleep -Seconds 2
      $new = Get-VisibleWindows $script:ProcessId | Where-Object { $before -notcontains $_ -and (Get-WindowTitle $_) -like 'Continuous Simulation results*' } | Select-Object -First 1
      if ($new) { $jobWindow = Get-WindowTitle $new; break }
    }
    if ($jobWindow) { "STARTED $jobWindow" } else { 'STARTED (no results window yet)' }
    exit 0
  }

  'stop' {
    # Stops the run only: the results window and the builder stay open.
    $builder = Get-BAWindowByTitle 'Strategy Builder'
    if (-not $builder) { 'NO_BUILDER'; exit 2 }
    $stopBtn = Get-StopButton $builder
    if (-not $stopBtn) { 'NOT_RUNNING'; exit 16 }
    Focus-Window (Get-BuilderHwnd)
    $r = $stopBtn.Current.BoundingRectangle
    Invoke-LeftClick ([int]($r.Left + $r.Width / 2)) ([int]($r.Top + $r.Height / 2))
    Start-Sleep -Seconds 1

    # a modal 'Continuous Simulation' dialog asks Yes/No
    $dialogHwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 10; $i++) {
      $dialogHwnd = Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -eq 'Continuous Simulation' } | Select-Object -First 1
      if ($dialogHwnd) { break }
      Start-Sleep -Milliseconds 500
    }
    if ($dialogHwnd) {
      $dlg = [System.Windows.Automation.AutomationElement]::FromHandle($dialogHwnd)
      $yes = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Yes')))
      if ($yes) {
        $ip = $null
        if ($yes.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke() }
        else { $yr = $yes.Current.BoundingRectangle; Invoke-LeftClick ([int]($yr.Left + $yr.Width / 2)) ([int]($yr.Top + $yr.Height / 2)) }
      }
    }

    # wait for the generator to actually stop (the STOP button disappears)
    $stopped = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      if (-not (Get-StopButton $builder)) { $stopped = $true; break }
    }
    Start-Sleep -Seconds 2   # let the results grid settle
    $total = Get-ResultsTotal
    $title = (Get-VisibleWindows $script:ProcessId | Where-Object { (Get-WindowTitle $_) -like 'Continuous Simulation results*' } | ForEach-Object { Get-WindowTitle $_ } | Select-Object -First 1)
    if ($stopped) { Write-Output "STOPPED total=$total title='$title'" }
    else { Write-Output "STOP_TIMEOUT total=$total title='$title'" }
    exit 0
  }

  'cancel' {
    $h = Get-BuilderHwnd
    if ($h) { Focus-Window $h; Send-Escape; Start-Sleep -Milliseconds 600 }
    if (Test-Path $pendingPath) { Remove-Item $pendingPath -Force }
    'CANCELLED'
    exit 0
  }
}
