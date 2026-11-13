<#
.SYNOPSIS
  Report BuildAlpha status: process, active job, job start, throughput, results, filter.

.DESCRIPTION
  Read-only. Combines three sources:
    * process table            -> is BuildAlpha running (pid, start, cpu, memory)
    * UI Automation            -> active job window, throughput, result count, filter
    * logs\app.log             -> when the current continuous job started (and its symbols)

  Nothing is clicked or changed.

.PARAMETER Json
  Emit JSON instead of a human-readable block.

.PARAMETER LogPath
  Path to app.log (default: %BA_LOG% or C:\Users\sam\BuildAlpha\BuildAlpha\logs\app.log)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\buildalpha_status.ps1
  powershell -ExecutionPolicy Bypass -File .\buildalpha_status.ps1 -Json
#>
param(
  [switch]$Json,
  [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\buildalpha_uia.ps1"

if (-not $LogPath) {
  $LogPath = if ($env:BA_LOG) { $env:BA_LOG } else { 'C:\Users\sam\BuildAlpha\BuildAlpha\logs\app.log' }
}

# ---------------------------------------------------------------- process
$proc = Get-Process -Name 'BuildAlpha_x64' -ErrorAction SilentlyContinue | Select-Object -First 1
$status = [ordered]@{
  checked_at      = (Get-Date).ToString('o')
  running         = [bool]$proc
  pid             = if ($proc) { $proc.Id } else { $null }
  responding      = if ($proc) { $proc.Responding } else { $null }
  process_started = if ($proc) { $proc.StartTime.ToString('o') } else { $null }
  cpu_seconds     = if ($proc) { [int]$proc.CPU } else { $null }
  memory_mb       = if ($proc) { [int]($proc.WorkingSet64 / 1MB) } else { $null }
  active_job      = $false
  results_open    = $false
  state           = 'idle'
  job_title       = $null
  job_started     = $null
  job_stop_marker = $null
  job_age_seconds = $null
  job_symbols     = $null
  job_data_from   = $null
  throughput      = $null
  results_total   = $null
  results_visible = $null
  filter          = $null
  windows         = @()
}

if (-not $proc) {
  if ($Json) { $status | ConvertTo-Json -Depth 4 } else { 'BuildAlpha: NOT RUNNING' }
  exit 0
}

$main = Get-MainWindow
if ($main) {
  $pidBa = $main.Current.ProcessId
  $status.windows = @(Get-VisibleWindows $pidBa | ForEach-Object { Get-WindowTitle $_ } | Where-Object { $_ })

  # ------------------------------------------------------------ active job
  $builder = Get-BAWindowByTitle 'Strategy Builder'
  $stopBtn = $null
  if ($builder) {
    foreach ($e in $builder.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
      if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $e.Current.Name -match '^STOP continuous simulation') { $stopBtn = $e; break }
    }
  }

  $resHwnd = [IntPtr]::Zero
  $resTitle = $null
  foreach ($h in (Get-VisibleWindows $pidBa)) {
    if ((Get-WindowTitle $h) -like 'Continuous Simulation results*') { $resHwnd = $h; $resTitle = Get-WindowTitle $h }
  }
  $status.results_open = ($resHwnd -ne [IntPtr]::Zero)
  $status.job_title = $resTitle

  if ($resHwnd -ne [IntPtr]::Zero) {
    $res = [System.Windows.Automation.AutomationElement]::FromHandle($resHwnd)
    $elems = $res.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)

    foreach ($e in $elems) {
      $n = $e.Current.Name
      if (-not $n) { continue }
      if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
      if ($n -match '^(?<rate>[\d\.,]+[KMB]?)\s*strat/sec$') { $status.throughput = $n }
    }

    $maxRow = 0; $maxTotal = 0; $minRow = [int]::MaxValue
    foreach ($e in $elems) {
      $m = [regex]::Match($e.Current.Name, '^Row (\d+) of (\d+), Column ')
      if (-not $m.Success) { continue }
      $rn = [int]$m.Groups[1].Value
      $tot = [int]$m.Groups[2].Value
      if ($rn -gt $maxRow) { $maxRow = $rn }
      if ($rn -lt $minRow) { $minRow = $rn }
      if ($tot -gt $maxTotal) { $maxTotal = $tot }
    }
    if ($maxTotal -gt 0) {
      $status.results_total = $maxTotal
      $status.results_visible = if ($minRow -eq [int]::MaxValue) { $null } else { "$minRow..$maxRow" }
    }

    foreach ($e in $elems) {
      if ($e.Current.AutomationId -ne 'FilteringPanel') { continue }
      $vp = $null
      if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        $v = $vp.Current.Value
        if ($v) { $status.filter = $v; break }
      }
    }
  }

  # A results window alone is not a running job: after a run finishes the window
  # stays open (often with an empty grid). Only the STOP button or a live
  # '<n> strat/sec' counter means strategies are still being generated.
  $status.active_job = [bool]($stopBtn -or $status.throughput)
  if ($status.active_job) { $status.state = 'running' }
  elseif ($status.results_open) { $status.state = 'results-open' }
  else { $status.state = 'idle' }
}

# ------------------------------------------------- job start (from app.log)
function Get-JobStartFromLog([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $lines = @(Get-Content $path -Tail 20000)
  $anchor = -1
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match 'Continuous Simulation') { $anchor = $i; break }
  }
  if ($anchor -lt 0) { return $null }
  for ($i = $anchor; $i -ge 0; $i--) {
    if ($lines[$i] -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ \| \w+ \| BrokersManager\.LoadServerSideData\(\): start loading \((.+?)\) from (.+)$') {
      $when = $matches[1]; $symbols = $matches[2]; $from = $matches[3]
      # A continuous run that is stopped (STOP -> Yes) leaves a Destroy marker.
      # Runs that finish on their own log nothing, so this stays $null.
      $stop = $null
      for ($j = $lines.Count - 1; $j -gt $i; $j--) {
        if ($lines[$j] -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ \| INFO \| StrategiesViewModel\.Destroy') {
          $stop = $matches[1]
          break
        }
      }
      return [pscustomobject]@{ When = $when; Symbols = $symbols; From = $from; Stop = $stop }
    }
  }
  return $null
}

$start = Get-JobStartFromLog $LogPath
if ($start) {
  $status.job_started = $start.When
  $status.job_stop_marker = $start.Stop
  $status.job_symbols = $start.Symbols
  $status.job_data_from = $start.From
  try {
    $t = [datetime]::ParseExact($start.When, 'yyyy-MM-dd HH:mm:ss', $null)
    $status.job_age_seconds = [int]((Get-Date) - $t).TotalSeconds
  } catch { }
}

# ------------------------------------------------------------------ output
if ($Json) {
  $status | ConvertTo-Json -Depth 4
  exit 0
}

function Fmt([object]$v) { if ($null -eq $v -or "$v" -eq '') { '-' } else { "$v" } }
$age = if ($status.job_age_seconds -ne $null) {
  [TimeSpan]::FromSeconds($status.job_age_seconds).ToString('d\d\ hh\:mm\:ss')
} else { '-' }

Write-Output 'BuildAlpha status'
Write-Output ("  running      : {0}" -f $(if ($status.running) { "yes (pid $($status.pid), responding=$($status.responding))" } else { 'no' }))
Write-Output ("  process up   : {0}   cpu={1}s  mem={2} MB" -f (Fmt $status.process_started), (Fmt $status.cpu_seconds), (Fmt $status.memory_mb))
Write-Output ("  state        : {0}" -f $status.state)
Write-Output ("  job          : {0}" -f (Fmt $status.job_title))
Write-Output ("  job started  : {0}  (age {1})" -f (Fmt $status.job_started), $age)
Write-Output ("  stop marker  : {0}" -f (Fmt $status.job_stop_marker))
Write-Output ("  symbols      : {0}" -f (Fmt $status.job_symbols))
Write-Output ("  data from    : {0}" -f (Fmt $status.job_data_from))
Write-Output ("  throughput   : {0}" -f (Fmt $status.throughput))
Write-Output ("  results      : {0} rows (visible {1})" -f (Fmt $status.results_total), (Fmt $status.results_visible))
Write-Output ("  filter       : {0}" -f (Fmt $status.filter))
Write-Output ("  windows      : {0}" -f ($status.windows -join ' | '))
