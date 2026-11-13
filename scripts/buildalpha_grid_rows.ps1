param(
  [string]$OutFile = 'grid-rows.txt',
  [string]$Portfolio = '',
  [int]$SettleMs = 300,
  [int]$MaxColumns = 40
)

# Reads the portfolio grid's top-level rows (one per strategy).
#
# Basket strategies own nested child rows; those are NOT grid rows: the grid's
# GridPattern enumerates exactly the top-level strategies (RowCount ~= 444),
# while cell names say "Row n of 8899" because they count every tree node.
# Reading through GridPattern therefore skips the nested legs for free.
#
#   powershell -ExecutionPolicy Bypass -File .\buildalpha_grid_rows.ps1 -OutFile grid-rows.txt
#
# Output: '#' header, then TSV: row + one column per grid column (Name, Symbol,
# Type, Exit Params, 26 metrics, ...). `row` is the tree-node index from the
# cell name, which is stable for a portfolio.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

# This script clicks a cell and sends Ctrl+A / Ctrl+C. Without the guard those went to whatever
# window was in front - measured: a sweep with an editor focused clicked and typed into the editor.
$uiReady = Start-BuildAlphaUi
if ($uiReady -eq 'UI_BUSY') { 'UI_BUSY another BuildAlpha tool is running'; exit 40 }
if ($uiReady -eq 'NOT_RUNNING') { 'BUILDALPHA_NOT_RUNNING'; exit 41 }
if ($uiReady -eq 'INPUT_BLOCKED') { 'INPUT_BLOCKED could not bring Build Alpha to the front'; exit 25 }

$Preferred = @(
  'Name','Symbol','Type','Exit Params','Trades','Sharpe','Net P&L','Drawdown','Win Percentage',
  'Drawdown MTM','P&L / DD','Profit Factor','Ratio WL','CAGR','SQM','SQN','T-Test','E-Ratio',
  'K-Ratio','Expectancy Score','Avg Trade','Mean W trades','Mean L trades','Std W trades',
  'Std L trades','Corr Coef','CPC Ratio','Perfect Profit Percentage','Perfect Profit Correlation',
  'Custom Fitness','ECurve','Index','Live Position','State','X'
)

Add-Type -Namespace BAG -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

function Focus-Window([IntPtr]$h) {
  [void][BAG.W]::ShowWindow($h, 9)
  [void][BAG.W]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 3)
  [void][BAG.W]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 3)
  $fg = [BAG.W]::GetForegroundWindow()
  $tfg = [BAG.W]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  [void][BAG.W]::AttachThreadInput([BAG.W]::GetCurrentThreadId(), $tfg, $true)
  [void][BAG.W]::SetForegroundWindow($h)
  [void][BAG.W]::AttachThreadInput([BAG.W]::GetCurrentThreadId(), $tfg, $false)
  Start-Sleep -Milliseconds 400
}

$proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output 'NO_BUILDALPHA'; exit 2 }
foreach ($h in (Get-VisibleWindows $proc.Id)) {
  if ((Get-WindowTitle $h) -like 'Build Alpha*') { Focus-Window $h; break }
}

$grid = $null
# The window's own tree first (DevExpress publishes the grid there in some builds), then hit-testing
# at several points: measured 2026-11-03, FromPoint at (600,420)/(500,300)/(700,500) returned a
# Pane whose parent walk did NOT reach the grid, while (400,300) did - so the NO_GRID that aborted a
# whole sweep was a point list that was too narrow.
$mainWin = $null
foreach ($h in (Get-VisibleWindows $proc.Id)) {
  if ((Get-WindowTitle $h) -like 'Build Alpha*') { $mainWin = [System.Windows.Automation.AutomationElement]::FromHandle($h); break }
}
if ($mainWin) {
  $grid = $mainWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
}
foreach ($point in @(@(400, 300), @(600, 420), @(500, 300), @(700, 500), @(300, 250), @(800, 400))) {
  if ($grid) { break }
  $hit = Get-ElementAt $point[0] $point[1]
  if (-not $hit) { continue }
  $grid = Get-DataGrid $hit
  if ($grid) { break }
  # walk up by hand as a second chance: Get-DataGrid stops at the first DataGrid it meets
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $el = $hit
  for ($i = 0; $i -lt 8 -and $el; $i++) {
    if ($el.Current.AutomationId -eq 'stratGrid') { $grid = $el; break }
    $el = $walker.GetParent($el)
  }
}
if (-not $grid) { Write-Output 'NO_GRID'; exit 2 }

# The grid must belong to the main 'Build Alpha' window. Another DevExpress grid
# (Strategy Builder, results window) can sit under the probe points, and reading
# it silently produced a capture of the wrong portfolio.
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$top = $grid
while ($true) {
  $parent = $walker.GetParent($top)
  if (-not $parent -or $parent -eq [System.Windows.Automation.AutomationElement]::RootElement) { break }
  $top = $parent
}
$ownerTitle = Get-WindowTitle ([IntPtr]$top.Current.NativeWindowHandle)
if (-not $ownerTitle) { $ownerTitle = $top.Current.Name }
if ($ownerTitle -notlike 'Build Alpha*') {
  Write-Output "WRONG_WINDOW title='$ownerTitle'"
  exit 3
}
$winTag = $ownerTitle -replace '\s+', '_'   # header values cannot contain spaces

# A filter left by an earlier tool narrows the grid, so a sweep would ingest only that subset and
# mark every other strategy as removed. Clear it first: open the find panel, empty it, commit.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$bound0 = $grid.Current.BoundingRectangle
if ($bound0.Width -gt 0) {
  Invoke-LeftClick ([int]($bound0.Left + 200)) ([int]($bound0.Top + 90))
  Start-Sleep -Milliseconds 150
  [System.Windows.Forms.SendKeys]::SendWait('^f')
  Start-Sleep -Milliseconds 250
  [System.Windows.Forms.SendKeys]::SendWait('^a{DEL}{ENTER}')
  Start-Sleep -Milliseconds 900
}

# Fast path: the grid copies itself. Click a data cell, Ctrl+A, Ctrl+C and the
# clipboard holds the whole grid as TSV (35 columns, every row) in ~2 s instead
# of ~75 s of GridPattern.GetItem calls. GridPattern.RowCount is used to check
# that the copy really is complete before trusting it.
function Read-GridViaClipboard($winHandle, $gridElement) {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
  $bound = $gridElement.Current.BoundingRectangle
  if ($bound.Width -le 0) { return $null }
  # a click inside the body ('first data row') gives the grid keyboard focus
  $clickX = [int]($bound.Left + 60)
  $clickY = [int]($bound.Top + 60)
  Set-Clipboard -Value "BA_CLIPBOARD_PROBE_$((Get-Date).Ticks)"
  Invoke-LeftClick $clickX $clickY
  Start-Sleep -Milliseconds 350
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 450
  [System.Windows.Forms.SendKeys]::SendWait('^c')
  Start-Sleep -Milliseconds 900
  $text = Get-Clipboard -Raw
  if (-not $text -or $text.StartsWith('BA_CLIPBOARD_PROBE_')) { return $null }
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
  if ($lines.Count -lt 2) { return $null }
  $rows = @()
  foreach ($line in $lines) { $rows += , @($line -split "`t") }
  return $rows
}

$gp = $null
if (-not $grid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)) {
  Write-Output 'NO_GRID_PATTERN'
  exit 2
}
$sp = $null
$grid.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$sp) | Out-Null
$nRows = $gp.Current.RowCount

# The clipboard copy is flaky (measured: 433 rows, then 355 and 367 of 433 in the same session), and
# a short copy looks exactly like "these strategies were deleted". Retry until the copy's row count
# equals the grid's own RowCount - that number is the authority.
$table = $null
for ($attempt = 1; $attempt -le 4; $attempt++) {
  $table = Read-GridViaClipboard ([IntPtr]$top.Current.NativeWindowHandle) $grid
  $copied = if ($table) { @($table).Count - 1 } else { 0 }
  if ($table -and $copied -eq $nRows) { break }
  [Console]::Error.WriteLine("clipboard copy gave $copied of $nRows row(s); retrying ($attempt/4)")
  Start-Sleep -Milliseconds 700
  $table = $null
}
if (-not $table) {
  Write-Output "GRID_COPY_INCOMPLETE expected=$nRows"
  exit 4
}

if ($table -and ($table.Count - 1) -eq $nRows) {
  # clipboard path: complete copy of the grid, 35 labelled columns
  $header = @($table[0])
  $data = @()
  for ($i = 1; $i -lt $table.Count; $i++) { $data += , $table[$i] }

  # the clipboard already carries every column with its header; keep it verbatim
  $cols = $header

  $idx = @{}
  for ($i = 0; $i -lt $header.Count; $i++) { $idx[$header[$i]] = $i }
  $sigSrc = ($data | ForEach-Object { "$($_[$idx['Symbol']])|$($_[$idx['Type']])|$($_[$idx['Name']])" }) -join "`n"
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $sig = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sigSrc))) -replace '-', '').ToLower().Substring(0, 12)
  $sha.Dispose()

  $lines = New-Object System.Collections.Generic.List[string]
  $meta = "# top_level=$nRows grid_rows=$nRows unread=0 sig=$sig window=$winTag source=clipboard"
  if ($Portfolio) { $meta += " portfolio=$Portfolio" }
  $lines.Add($meta)
  $lines.Add(('row' + "`t" + ($cols -join "`t")))
  $i = 0
  foreach ($row in $data) {
    $vals = foreach ($c in $cols) { if ($idx[$c] -lt $row.Count) { $row[$idx[$c]] } else { '' } }
    $lines.Add((@($i) + @($vals)) -join "`t")
    $i++
  }
  $lines -join "`n" | Set-Content -Path $OutFile -Encoding UTF8
  Write-Output "GRID_OK top_level=$nRows grid_rows=$nRows unread=0 columns=$($cols.Count) sig=$sig source=clipboard windows='$ownerTitle' file=$OutFile"
  exit 0
}
$records = @{}     # tree index -> @{ column = value }
$cellPattern = '^Row (\d+) of \d+, Column (.*?), Column \d+ of \d+: ?'

function Read-Row([int]$r) {
  $got = 0
  for ($c = 0; $c -lt $MaxColumns; $c++) {
    $cell = $null
    try { $cell = $gp.GetItem($r, $c) } catch { continue }
    if (-not $cell) { continue }
    $name = $cell.Current.Name
    $m = [regex]::Match($name, $cellPattern)
    if (-not $m.Success) { continue }
    $n = [int]$m.Groups[1].Value
    $col = $m.Groups[2].Value.Trim()
    $vp = $null
    $val = if ($cell.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
      [string]$vp.Current.Value
    } else {
      $name.Substring($m.Length)
    }
    if (-not $records.ContainsKey($n)) { $records[$n] = @{} }
    $records[$n][$col] = $val
    $got++
  }
  return $got
}

$seen = @{}
for ($r = 0; $r -lt $nRows; $r++) {
  if ((Read-Row $r) -gt 0) { $seen[$r] = $true }
}

# Some rows are not realized until they are near the viewport; retry those.
$missing = @(0..($nRows - 1) | Where-Object { -not $seen.ContainsKey($_) })
foreach ($r in $missing) {
  if ($sp) {
    $pct = [math]::Min(100.0, [math]::Max(0.0, ($r / [double][math]::Max(1, $nRows)) * 100.0))
    try { [void]$sp.SetScrollPercent(-1, $pct) } catch { }   # pane may reload mid-read
    Start-Sleep -Milliseconds $SettleMs
  }
  if ((Read-Row $r) -gt 0) { $seen[$r] = $true }
}
if ($sp) { try { [void]$sp.SetScrollPercent(0, 0) } catch { } }

$found = @($records.Keys)
$columns = New-Object System.Collections.Generic.List[string]
foreach ($c in $Preferred) { if ($found.Count -and ($records[$found[0]].ContainsKey($c))) { $columns.Add($c) } }
foreach ($n in $found) {
  foreach ($c in $records[$n].Keys) { if (-not $columns.Contains($c)) { $columns.Add($c) } }
}

$lines = New-Object System.Collections.Generic.List[string]
$sigSrc = ($found | Sort-Object | ForEach-Object { "$($records[$_]['Symbol'])|$($records[$_]['Type'])|$($records[$_]['Name'])" }) -join "`n"
$sha = [System.Security.Cryptography.SHA1]::Create()
$sig = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sigSrc))) -replace '-', '').ToLower().Substring(0, 12)
$sha.Dispose()

$meta = "# top_level=$($found.Count) grid_rows=$nRows unread=$($nRows - $seen.Count) sig=$sig window=$winTag source=uia"
if ($Portfolio) { $meta += " portfolio=$Portfolio" }
$lines.Add($meta)
$lines.Add(('row' + "`t" + ($columns -join "`t")))
foreach ($n in ($found | Sort-Object)) {
  $vals = foreach ($c in $columns) { $records[$n][$c] }
  $lines.Add((@($n) + @($vals)) -join "`t")
}
$lines -join "`n" | Set-Content -Path $OutFile -Encoding UTF8

Write-Output "GRID_OK top_level=$($found.Count) grid_rows=$nRows unread=$($nRows - $seen.Count) columns=$($columns.Count) sig=$sig file=$OutFile"
