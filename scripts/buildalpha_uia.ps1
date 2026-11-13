# buildalpha_uia.ps1 - shared UI-Automation helpers for the BuildAlpha scripts.
# Dot-source from a script:  . "$PSScriptRoot\buildalpha_uia.ps1"
# Verified against BuildAlpha v3.22.37 (DevExpress 24.2) on Windows 11.

Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

if (-not ('BA' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class BA {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref uint c, uint d);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  public struct POINT { public int X, Y; }
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}

$script:CellPattern = '^(TextEdit)?Row (\d+) of \d+, Column (.+?), Column \d+ of \d+: (.*)$'

function Invoke-ScriptBounded {
  # Run a sibling script with a HARD deadline and return its combined output.
  #
  # Why this exists: a PowerShell script's own timeout loops only bound its sleeps. A blocking
  # UI Automation call inside it (a desktop-wide FindAll while the app is busy, a modal popup)
  # never returns, and the caller waits forever - measured: buildalpha_switch_portfolio.ps1 with
  # -TimeoutSec 30 was still alive 15 minutes later, holding a capture open. The child is the
  # killable unit, so the deadline has to live here.
  #
  # -Arguments are passed one by one and quoted when they contain spaces: Start-Process joins an
  # argument array with single spaces, so 'Common Portfolio' would arrive as two arguments.
  param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string[]]$Arguments = @(),
    [int]$TimeoutSec = 30
  )
  $quoted = @()
  foreach ($a in $Arguments) {
    if ($a -match '[\s"]') { $quoted += ('"' + ($a -replace '"', '\"') + '"') } else { $quoted += $a }
  }
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $quoted) -join ' '
  $proc = Start-Process -FilePath 'powershell' -ArgumentList $argLine -PassThru -NoNewWindow `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  $finished = $proc.WaitForExit($TimeoutSec * 1000)
  if (-not $finished) {
    try { $proc.Kill() } catch { }
    $partial = ''
    try { $partial = (Get-Content $outFile -Raw) + (Get-Content $errFile -Raw) } catch { }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ TimedOut = $true; ExitCode = -1; Output = ($partial + "`n[child killed after ${TimeoutSec}s]") }
  }
  $text = ''
  try { $text = ((Get-Content $outFile -Raw) + (Get-Content $errFile -Raw)) } catch { }
  $code = $proc.ExitCode
  Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{ TimedOut = $false; ExitCode = $code; Output = $text }
}

function Get-PortfolioItemsNow {
  # The portfolio combo is custom-drawn: its ValuePattern is a .NET object name
  # ('TradersToolbox.DataObjects.LinkData'), its Text child has no name and an infinite rect, so
  # the ONLY way to learn which portfolio is loaded is to open the dropdown and read the list.
  # That costs ~700 ms in-process (measured), against ~2.5-8 s when it is done through a child
  # PowerShell + the switch script's click-and-verify-again.
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, (Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1).Id)),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::ListItem)))
  $out = @()
  foreach ($li in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    $r = $li.Current.BoundingRectangle
    if ($r.Width -le 0) { continue }
    $txt = $li.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)))
    if (-not $txt) { continue }
    $sp = $null
    $sel = $false
    if ($li.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) {
      try { $sel = $sp.Current.IsSelected } catch { }
    }
    $out += [pscustomobject]@{ Name = $txt.Current.Name; Selected = $sel; Rect = $r }
  }
  return $out
}

function Open-PortfolioDropdown([int]$ComboX = 120, [int]$ComboY = 73, [int]$TimeoutMs = 4000) {
  Send-Escape
  Start-Sleep -Milliseconds 150
  Invoke-LeftClick $ComboX $ComboY
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $items = @(Get-PortfolioItemsNow)
    if ($items.Count -ge 2) { return $items }
  }
  return @(Get-PortfolioItemsNow)
}

function Get-PortfolioState([int]$ComboX = 120, [int]$ComboY = 73) {
  """Open the dropdown, read which portfolio is loaded, close it. No clicks on any item."""
  $items = @(Open-PortfolioDropdown -ComboX $ComboX -ComboY $ComboY)
  $selected = ($items | Where-Object { $_.Selected } | Select-Object -First 1)
  Send-Escape
  return [pscustomobject]@{
    Ok       = ($items.Count -ge 2)
    Selected = if ($selected) { $selected.Name } else { '' }
    Items    = $items
  }
}

function Set-PortfolioVerified([string]$Name, [int]$ComboX = 120, [int]$ComboY = 73, [switch]$SkipVerify) {
  """Make sure the named portfolio is loaded, and prove it by re-reading the dropdown.

  Reads first (one dropdown open). If the wanted portfolio is already the selected one, nothing is
  clicked - which is the common case and the whole point. A different one is clicked and then
  re-read, because SelectionItemPattern.Select() only highlights; a real click commits.
  """
  $state = Get-PortfolioState -ComboX $ComboX -ComboY $ComboY
  if (-not $state.Ok) {
    return [pscustomobject]@{ Ok = $false; Switched = $false; Read = $state.Selected
                              Reason = 'the portfolio dropdown did not open' }
  }
  if ($state.Selected -eq $Name) {
    return [pscustomobject]@{ Ok = $true; Switched = $false; Read = $state.Selected; Reason = '' }
  }
  $target = $state.Items | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if (-not $target) {
    $partial = @($state.Items | Where-Object { $_.Name -like "$Name*" })
    if ($partial.Count -eq 1) { $target = $partial[0] }
  }
  if (-not $target) {
    $available = ($state.Items | ForEach-Object { $_.Name }) -join '; '
    return [pscustomobject]@{ Ok = $false; Switched = $false; Read = $state.Selected
                              Reason = "portfolio '$Name' is not in the list: $available" }
  }
  # re-open (Get-PortfolioState closed it) and click the target
  $items = @(Open-PortfolioDropdown -ComboX $ComboX -ComboY $ComboY)
  $again = $items | Where-Object { $_.Name -eq $target.Name } | Select-Object -First 1
  if (-not $again) { Send-Escape; return [pscustomobject]@{ Ok = $false; Switched = $false
                     Read = $state.Selected; Reason = 'the dropdown closed before the click' } }
  Invoke-LeftClick ([int]($again.Rect.Left + $again.Rect.Width / 2)) ([int]($again.Rect.Top + $again.Rect.Height / 2))
  Start-Sleep -Milliseconds 700
  if ($SkipVerify) { return [pscustomobject]@{ Ok = $true; Switched = $true; Read = $target.Name; Reason = '' } }
  $after = Get-PortfolioState -ComboX $ComboX -ComboY $ComboY
  return [pscustomobject]@{ Ok = ($after.Selected -eq $target.Name); Switched = $true
                            Read = $after.Selected
                            Reason = if ($after.Selected -eq $target.Name) { '' }
                                     else { "wanted '$($target.Name)', loaded '$($after.Selected)'" } }
}

# --- one BuildAlpha, one driver -------------------------------------------------------------
# Every tool that drives the GUI acts on the same grid, the same foreground window and the same
# selection. Two calls running at once interleave clicks and filters: one call's click lands in the
# other call's filtered grid, which is precisely the wrong-row capture class of bug. The MCP server
# runs synchronous tools in a thread pool, so overlap is possible without anyone trying.
#
# The lock is an OS one: a file opened with FileShare.None. Windows releases it when the process
# dies, so a killed or crashed run can never leave the app wedged - no stale-pid bookkeeping, no
# timeout to tune. A child process inherits BA_UI_LOCK_HELD and skips acquiring, so the nested
# scripts (find_strategy, rerun) do not fight their own parent.
$script:uiLockHandle = $null

function Get-UiLockPath {
  $root = Split-Path $PSScriptRoot -Parent
  $dir = Join-Path $root 'logs'
  if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  return (Join-Path $dir 'ui.lock')
}

function Enter-UiLock {
  if ($env:BA_UI_LOCK_HELD -eq '1') { return $true }
  $path = Get-UiLockPath
  for ($try = 0; $try -lt 2; $try++) {
    try {
      $script:uiLockHandle = [System.IO.File]::Open(
        $path, [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      $info = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID started=$((Get-Date).ToUniversalTime().ToString('o'))`n")
      $script:uiLockHandle.SetLength(0)
      $script:uiLockHandle.Write($info, 0, $info.Length)
      $script:uiLockHandle.Flush()
      $env:BA_UI_LOCK_HELD = '1'      # inherited by every child this process starts
      return $true
    } catch [System.IO.IOException] {
      return $false                     # held by a live process
    } catch {
      return $false
    }
  }
  return $false
}

function Exit-UiLock {
  if ($script:uiLockHandle) { try { $script:uiLockHandle.Dispose() } catch { } }
  $script:uiLockHandle = $null
  if ($env:BA_UI_LOCK_HELD -eq '1') { Remove-Item Env:BA_UI_LOCK_HELD -ErrorAction SilentlyContinue }
}

function Start-BuildAlphaUi {
  # The three things every GUI-driving tool must do before it touches anything:
  #   1. one driver at a time (Enter-UiLock),
  #   2. is BuildAlpha running? (no -> NOT_RUNNING, nothing else attempted),
  #   3. is it in front? (no -> bring it to the front; INPUT_BLOCKED only if that fails).
  # Returns 'OK', 'UI_BUSY', 'NOT_RUNNING' or 'INPUT_BLOCKED'. Callers turn anything but OK into
  # their status and exit; they do not need to know which window happened to be in front.
  if (-not (Enter-UiLock)) { return 'UI_BUSY' }
  $proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { return 'NOT_RUNNING' }
  $hwnd = @(Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' }) | Select-Object -First 1
  if (-not $hwnd) { Start-Sleep -Milliseconds 400; $hwnd = @(Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' }) | Select-Object -First 1 }
  if (-not $hwnd) { return 'NOT_RUNNING' }
  try {
    Set-AppForeground $hwnd
  } catch {
    [Console]::Error.WriteLine("$($_.Exception.Message)")
    return 'INPUT_BLOCKED'
  }
  return 'OK'
}

function Get-MainWindow {
  $ws = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($w in $ws) { if ($w.Current.Name -eq 'Build Alpha') { return $w } }
  return $null
}

function Get-WindowClass([IntPtr]$hwnd) {
  $sb = New-Object System.Text.StringBuilder 256
  [void][BA]::GetClassName($hwnd, $sb, 256)
  return $sb.ToString()
}

# ---------------------------------------------------------------- input guard
# Every synthetic event goes through the wrappers below, so the foreground is checked
# immediately before each one rather than once at the start of a run: a dialog can
# appear between the check and the keystroke, and a keystroke aimed at a window the
# user did not open can confirm it.
#
# The guard is process-aware. BuildAlpha raises its own modals during a normal run, so
# rejecting class '#32770' outright would block valid work; what is rejected is a
# FOREIGN process, or a BuildAlpha dialog this script did not open itself.
$script:InjectionPid = 0
$script:InjectionWindows = @()   # hwnds this run opened (Re-Run, results, ...)

function Set-InjectionGuard([int]$ProcessId, [IntPtr[]]$Windows = @()) {
  $script:InjectionPid = $ProcessId
  $script:InjectionWindows = @($Windows | Where-Object { $_ -ne [IntPtr]::Zero })
}

function Add-InjectionWindow([IntPtr]$hwnd) {
  if ($hwnd -ne [IntPtr]::Zero) { $script:InjectionWindows += $hwnd }
}

function Test-InjectionAllowed([string]$Label = 'input') {
  $fg = [BA]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return }
  foreach ($h in $script:InjectionWindows) { if ($h -eq $fg) { return } }
  $fgPid = [uint32]0
  [void][BA]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $title = Get-WindowTitle $fg
  if ($script:InjectionPid -eq 0) { return }        # guard not armed (read-only helpers)
  if ($fgPid -ne $script:InjectionPid) {
    # Another program is in front - a window the operator left there (an editor, a browser). Input
    # would land in it, so bring BuildAlpha back to the front and carry on; that is what every
    # driving script does at its start anyway. Refuse only if it will not come forward.
    $target = $null
    foreach ($h in $script:InjectionWindows) { if ($h -and $h -ne [IntPtr]::Zero) { $target = $h; break } }
    if (-not $target) {
      $proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($proc) { $target = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' } | Select-Object -First 1 }
    }
    if ($target) {
      try { Set-AppForeground $target } catch { }
      $fg = [BA]::GetForegroundWindow()
      $fgPid = [uint32]0
      [void][BA]::GetWindowThreadProcessId($fg, [ref]$fgPid)
      if ($fgPid -eq $script:InjectionPid) { return }
      $title = Get-WindowTitle $fg
    }
    throw "INPUT_BLOCKED $Label fg_pid=$fgPid fg='$title' (could not bring Build Alpha to the front; refusing to inject input)"
  }
  # Same process and not a window this run registered -> it is a dialog BuildAlpha raised
  # (a confirmation prompt, an error box). Typing into it can answer a question the user
  # never saw, and that is exactly how closing a results window froze the desktop: the
  # "are you sure you want to close this window" prompt got the next keystroke. Every
  # window we are allowed to type into has to be registered explicitly - the picker popup
  # included (it is added when the popup is found), so no owner-based guessing.
  throw "BA_DIALOG_NOT_OURS $Label fg='$title' (BuildAlpha dialog this run did not open; refusing to inject input)"
}

# ----------------------------------------------------------------- dialogs
# A window of the process that this run did not register is a dialog until proven otherwise.
# Helper windows (IME, WPF plumbing) are filtered by title/size so they do not count.
function Get-DialogWindows([int]$ProcessId, [IntPtr[]]$Allowed = @()) {
  $out = @()
  foreach ($h in (Get-VisibleWindows $ProcessId)) {
    $skip = $false
    foreach ($a in $Allowed) { if ($a -eq $h) { $skip = $true; break } }
    if ($skip) { continue }
    $t = Get-WindowTitle $h
    if ($t -eq '' -or $t -like '*IME*' -or $t -like '*BroadcastEventWindow*' -or $t -like 'GDI+ Window*' -or $t -eq 'CiceroUIWndFrame') { continue }
    $r = Get-WindowRect $h
    $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
    if ($w -lt 80 -or $hh -lt 40) { continue }
    if ([double]::IsInfinity($r.Left) -or $r.Left -lt -1000) { continue }
    $out += [pscustomobject]@{ hwnd = $h; title = $t; width = $w; height = $hh }
  }
  return $out
}

function Get-DialogButtons([IntPtr]$hwnd) {
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $el) { return @() }
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  return @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond) | ForEach-Object { $_.Current.Name })
}

function Invoke-DialogAffirmative([IntPtr]$hwnd) {
  # Answer the prompt by pressing its own button element - no keystroke, no click, so it
  # cannot be confused with the window behind it.
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $el) { return $false }
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $buttons = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
  foreach ($want in @('Yes', '&Yes', 'OK', '&OK')) {
    foreach ($b in $buttons) {
      if ($b.Current.Name -eq $want) {
        $ip = $null
        if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip) -and $ip) {
          $ip.Invoke()
          return $true
        }
      }
    }
  }
  return $false
}

function Close-WindowChecked([IntPtr]$hwnd, [int]$ProcessId, [IntPtr[]]$Allowed = @(), [int]$TimeoutMs = 5000) {
  # Closing a results window raises a confirmation prompt. The prompt is modal: while it is
  # up nothing else in BuildAlpha responds, so it has to be answered - once - and the
  # result verified. Repeating WM_CLOSE instead (what this used to do) stacked prompts and
  # left the desktop unusable.
  if (-not $hwnd -or $hwnd -eq [IntPtr]::Zero) { return @{ closed = $true; title = ''; dialog = $null; answered = $false } }
  $title = Get-WindowTitle $hwnd
  [void][BA]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE once
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $dialogSeen = $null
  $answered = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if (-not [BA]::IsWindowVisible($hwnd)) { return @{ closed = $true; title = $title; dialog = $dialogSeen; answered = $answered } }
    $dlg = @(Get-DialogWindows -ProcessId $ProcessId -Allowed (@($Allowed) + @($hwnd)))
    if ($dlg.Count) {
      if (-not $dialogSeen) { $dialogSeen = $dlg[0] }
      $buttons = @(Get-DialogButtons $dlg[0].hwnd)
      "dialog '$($dlg[0].title)' buttons=[$($buttons -join ', ')]"
      if (-not $answered) { $answered = Invoke-DialogAffirmative $dlg[0].hwnd; "dialog answered=$answered" }
      elseif ($buttons.Count -eq 0) { break }
    }
  }
  return @{ closed = (-not [BA]::IsWindowVisible($hwnd)); title = $title; dialog = $dialogSeen; answered = $answered }
}

function Send-Keys([string]$Keys, [string]$Label = 'keys') {
  Test-InjectionAllowed $Label
  [System.Windows.Forms.SendKeys]::SendWait($Keys)
}

function Send-KeyEvent([byte]$VirtualKey, [uint32]$Flags, [string]$Label = 'key') {
  Test-InjectionAllowed $Label
  [BA]::keybd_event($VirtualKey, 0, $Flags, [UIntPtr]::Zero)
}

# ------------------------------------------------------------------ topmost
function Clear-Topmost([IntPtr[]]$Windows, [switch]$Async) {
  # 0x4000 SWP_ASYNCWINDOWPOS: SetWindowPos sends WM_WINDOWPOSCHANGING synchronously, so
  # against a hung window it blocks and the release is useless exactly when it is needed.
  $flags = 0x43 -bor $(if ($Async) { 0x4000 } else { 0 })
  foreach ($h in $Windows) {
    if (-not $h -or $h -eq [IntPtr]::Zero) { continue }
    [void][BA]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, $flags)   # HWND_NOTOPMOST
  }
}

function Test-ActivationAllowed([string]$Label = 'activate') {
  # Raising our own window above another application is normal and reversible. What must
  # never happen is taking the foreground away from a *dialog* - BuildAlpha's own prompt we
  # did not open, or another program's modal box - because that is what leaves a modal
  # question unanswered and the desktop stuck. Injecting input stays strictly guarded.
  $fg = [BA]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return }
  $fgPid = [uint32]0
  [void][BA]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $title = Get-WindowTitle $fg
  if ($script:InjectionPid -eq 0) { return }
  if ($fgPid -ne $script:InjectionPid) {
    if ((Get-WindowClass $fg) -eq '#32770') {
      throw "FOREGROUND_HELD_BY_DIALOG $Label fg_pid=$fgPid fg='$title' (another program has a dialog up; refusing to take the foreground)"
    }
    return
  }
  foreach ($h in $script:InjectionWindows) { if ($h -eq $fg) { return } }
  throw "BA_DIALOG_NOT_OURS $Label fg='$title' (BuildAlpha dialog this run did not open; refusing to take the foreground)"
}

function Focus-WindowVerified([IntPtr]$hwnd) {
  # One polite attempt, and never a loop: repeatedly calling SwitchToThisWindow/AttachThreadInput
  # while a modal dialog is open fights the modal loop and can wedge the desktop (it did).
  if ([BA]::IsIconic($hwnd)) { [void][BA]::ShowWindow($hwnd, 9) }
  if ([BA]::GetForegroundWindow() -eq $hwnd) { return $true }
  [void][BA]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 300
  return ([BA]::GetForegroundWindow() -eq $hwnd)
}

function Set-AppForeground([IntPtr]$hwnd) {
  Test-ActivationAllowed 'foreground'
  # Bring BuildAlpha to the front and leave it maximised, without ever pinning it: no topmost, no
  # geometry changes beyond maximising. The user must still be able to minimise it whenever they
  # like, so this is only ever called while a tool is working.
  if ([BA]::IsIconic($hwnd)) { [void][BA]::ShowWindow($hwnd, 9) }        # SW_RESTORE: minimised
  elseif (-not [BA]::IsZoomed($hwnd)) { [void][BA]::ShowWindow($hwnd, 3) } # SW_MAXIMIZE
  Start-Sleep -Milliseconds 250

  $fg = [BA]::GetForegroundWindow()
  $fgPid = [uint32]0; $fgT = [BA]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $tmpPid = [uint32]0; $tT = [BA]::GetWindowThreadProcessId($hwnd, [ref]$tmpPid)
  $my = [BA]::GetCurrentThreadId()
  [void][BA]::AttachThreadInput($my, $tT, $true)
  [void][BA]::AttachThreadInput($my, $fgT, $true)
  [void][BA]::BringWindowToTop($hwnd)
  [void][BA]::SetForegroundWindow($hwnd)
  [void][BA]::AttachThreadInput($my, $fgT, $false)
  [void][BA]::AttachThreadInput($my, $tT, $false)

  # Prove it: every click and keystroke goes to whatever is in front, and today an editor window
  # was in front for a whole session - clicks landed in it, the grid looked empty, keystrokes
  # never arrived. Refusing is the only safe behaviour.
  for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 200
    if ([BA]::GetForegroundWindow() -eq $hwnd) { return }
  }
  # The foreground can be another window of the SAME process. BuildAlpha's own IME frame does
  # exactly this (class CiceroUIWndFrame, 200x200), and Windows then refuses SetForegroundWindow
  # because the process already owns the foreground. Input sent now would still reach BuildAlpha,
  # but the grid click needs the main window focused, so nudge it once with a real click on its
  # title bar - one click, never the retry storm that wedged this desktop before - and look again.
  $front = [BA]::GetForegroundWindow()
  $fp = [uint32]0; [void][BA]::GetWindowThreadProcessId($front, [ref]$fp)
  if ($fp -eq $tmpPid) {
    $wr = New-Object BA+RECT
    [void][BA]::GetWindowRect($hwnd, [ref]$wr)
    $nudgeX = [int](($wr.Left + $wr.Right) / 2)
    $nudgeY = [int]($wr.Top + 8)          # title bar, not the client area
    [BA]::SetCursorPos($nudgeX, $nudgeY)
    Start-Sleep -Milliseconds 60
    [BA]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [BA]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    for ($i = 0; $i -lt 10; $i++) {
      Start-Sleep -Milliseconds 150
      if ([BA]::GetForegroundWindow() -eq $hwnd) { return }
    }
    $front = [BA]::GetForegroundWindow()
    $fp = [uint32]0; [void][BA]::GetWindowThreadProcessId($front, [ref]$fp)
  }
  throw "INPUT_BLOCKED could not bring BuildAlpha to the front (foreground pid $fp); refusing to send input to another window"
}


function Send-Escape([int]$Count = 1) {
  for ($i = 0; $i -lt $Count; $i++) {
    Send-KeyEvent 0x1B 0 'escape'
    Send-KeyEvent 0x1B 2 'escape'
    Start-Sleep -Milliseconds 150
  }
}

function Invoke-LeftClick([int]$X, [int]$Y) {
  Test-InjectionAllowed 'click'
  [BA]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 120
  [BA]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50
  [BA]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-RightClick([int]$X, [int]$Y) {
  Test-InjectionAllowed 'right-click'
  [BA]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 120
  [BA]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 70
  [BA]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-VisibleWindows([int]$ProcessId) {
  $script:baWins = @()
  $cb = [BA+EnumProc]{ param($h, $l)
    $p = [uint32]0
    [void][BA]::GetWindowThreadProcessId($h, [ref]$p)
    if ($p -eq $ProcessId -and [BA]::IsWindowVisible($h)) { $script:baWins += $h }
    return $true }
  [void][BA]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:baWins
}

function Get-ObservedWindows([int]$ProcessId) {
  # Titles of the process's visible windows, for reporting what is actually on screen.
  $titles = @()
  foreach ($h in (Get-VisibleWindows $ProcessId)) {
    $t = Get-WindowTitle $h
    if ($t) { $titles += $t }
  }
  return $titles
}
function Get-WindowTitle([IntPtr]$hwnd) {
  $t = New-Object System.Text.StringBuilder 256
  [void][BA]::GetWindowText($hwnd, $t, 256)
  return $t.ToString()
}

function Get-WindowRect([IntPtr]$hwnd) {
  $r = New-Object BA+RECT
  [void][BA]::GetWindowRect($hwnd, [ref]$r)
  return $r
}

function Get-ElementAt([int]$X, [int]$Y) {
  try {
    return [System.Windows.Automation.AutomationElement]::FromPoint(
      [System.Windows.Point]::new($X, $Y))
  } catch { return $null }
}

function Get-DataGrid($el) {
  $cur = $el
  for ($k = 0; $k -lt 14 -and $cur; $k++) {
    if ($cur.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataGrid) { return $cur }
    $cur = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($cur)
  }
  return $null
}

function Read-Grid($grid) {
  $d = @{}
  if (-not $grid) { return $d }
  $all = $grid.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($e in $all) {
    $m = [regex]::Match($e.Current.Name, $script:CellPattern)
    if (-not $m.Success) { continue }
    $rn = [int]$m.Groups[2].Value
    $cn = $m.Groups[3].Value.Trim()
    $val = $m.Groups[4].Value.Trim()
    if (-not $d.ContainsKey($rn)) { $d[$rn] = @{} }
    $d[$rn][$cn] = $val
  }
  return $d
}

function Reset-GridHorizontal($grid) {
  $sp = $null
  if (-not $grid.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$sp)) { return }
  for ($i = 0; $i -lt 16; $i++) {
    $sp.ScrollHorizontal([System.Windows.Automation.ScrollAmount]::LargeDecrement)
    Start-Sleep -Milliseconds 50
  }
}

# Reads every realized row, scrolling horizontally to realise all visible columns.
function Read-GridAllRows($grid) {
  $sp = $null
  $grid.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$sp) | Out-Null
  $all = @{}
  for ($step = 0; $step -lt 14; $step++) {
    $g = Read-Grid $grid
    foreach ($rn in $g.Keys) {
      if (-not $all.ContainsKey($rn)) { $all[$rn] = @{} }
      foreach ($k in $g[$rn].Keys) { $all[$rn][$k] = $g[$rn][$k] }
    }
    if (-not $sp) { break }
    $b = $sp.Current.HorizontalScrollPercent
    $sp.ScrollHorizontal([System.Windows.Automation.ScrollAmount]::LargeIncrement)
    Start-Sleep -Milliseconds 300
    $a = $sp.Current.HorizontalScrollPercent
    if ($b -ge 0 -and [math]::Abs($a - $b) -lt 0.01) { break }
  }
  Reset-GridHorizontal $grid
  return $all
}

# Returns the record (column -> value) whose Name matches, else the only row.
function Read-Record($grid, [string]$Name) {
  $rows = Read-GridAllRows $grid
  if ($Name) {
    foreach ($rn in $rows.Keys) {
      if ($rows[$rn]['Name'] -and $rows[$rn]['Name'] -eq $Name) { return $rows[$rn] }
    }
    foreach ($rn in $rows.Keys) {
      if ($rows[$rn]['Name'] -and $rows[$rn]['Name'] -like "*$Name*") { return $rows[$rn] }
    }
  }
  if ($rows.Count -eq 1) { return ($rows.Values | Select-Object -First 1) }
  return $null
}

# Finds the target row by scanning the Name column (x ~ 400) top to bottom.
function Find-Row([string]$Name, [int]$NameX = 400, [int]$FromY = 120, [int]$ToY = 820) {
  for ($y = $FromY; $y -le $ToY; $y += 6) {
    $el = Get-ElementAt $NameX $y
    if (-not $el) { continue }
    $m = [regex]::Match($el.Current.Name, $script:CellPattern)
    if ($m.Success -and $m.Groups[3].Value.Trim() -eq 'Name' -and $m.Groups[4].Value.Trim() -eq $Name) {
      return @{ Row = [int]$m.Groups[2].Value; Y = $y }
    }
  }
  return $null
}

# Moves other BuildAlpha result windows out of the portfolio grid's way.
function Park-ResultWindows([int]$ProcessId, [IntPtr]$MainHwnd, [int]$X = 1150, [int]$Y = 60) {
  foreach ($h in (Get-VisibleWindows $ProcessId)) {
    if ($h -eq $MainHwnd) { continue }
    $t = Get-WindowTitle $h
    $r = Get-WindowRect $h
    $w = $r.Right - $r.Left
    if ($t -like 'Seasonality*' -or $t -like 'Monthly Returns*' -or ($t -eq '' -and $w -gt 600)) {
      [void][BA]::SetWindowPos($h, [IntPtr]::Zero, $X, $Y, 0, 0, 5)
      Start-Sleep -Milliseconds 300
    }
  }
}

function Close-Window([IntPtr]$hwnd) {
  [void][BA]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
}

function Save-WindowShot([IntPtr]$hwnd, [string]$Path) {
  $r = Get-WindowRect $hwnd
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size -ArgumentList $w, $h))
  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return $Path
}

# --- trade list extraction (shared) ----------------------------------------
# Runs in-process: spawning a second PowerShell to do this costs ~2 s of start-up and a
# re-read of this module, which was a third of the whole operation.
$script:TradeMarks = [System.Collections.ArrayList]::new()
$script:TradeMarkClock = $null
function Start-TradeMarks {
  $script:TradeMarks = [System.Collections.ArrayList]::new()
  $script:TradeMarkClock = [System.Diagnostics.Stopwatch]::StartNew()
  $script:TradeMarkLast = 0
}
function Mark-Trade([string]$label) {
  if (-not $script:TradeMarkClock) { return }
  $now = [int]$script:TradeMarkClock.ElapsedMilliseconds
  [void]$script:TradeMarks.Add(('{0} ms={1}' -f $label, ($now - $script:TradeMarkLast)))
  $script:TradeMarkLast = $now
}

function Test-WindowIsForeground([IntPtr]$hwnd) {
  return ([BA]::GetForegroundWindow() -eq $hwnd)
}

function Focus-WindowFast([IntPtr]$hwnd) {
  # Activating costs ~850 ms (AttachThreadInput + sleeps). If the window is already in
  # front there is nothing to do - it happens whenever the caller just opened it.
  if (Test-WindowIsForeground $hwnd) { return $false }
  [void](Set-AppForeground $hwnd)
  return $true
}

function Get-TradeTable {
  <#
    Right-click a grid row -> 'Show Trades' -> copy the trade table -> TSV file.
    Returns an object; never exits, so it can be called in-process or from a wrapper.
    Status: TRADES_OK | TRADES_SUSPECT | WINDOW_MISSING | GRID_MISSING | ROW0_MISSING |
            CONTEXT_MENU_MISSING | MENU_ITEM_MISSING | TRADES_WINDOW_TIMEOUT |
            TRADES_GRID_MISSING | COPY_FAILED | NAME_MISMATCH
  #>
  param(
    [string]$WindowTitle = 'Build Alpha',
    [int]$RowX = 120,
    [int]$RowY = 0,
    [string]$OutFile = '',
    [double]$ExpectNetPnl = [double]::NaN,
    [string]$ExpectName = '',
    [double]$Tolerance = 0.5,
    [int]$TimeoutSec = 25,
    [switch]$KeepWindow
  )
  Start-TradeMarks
  $expectHeader = @('Trade', 'Symbol', 'Entry on', 'Exit on', 'Entry Value', 'Exit Value',
                    'Account value', 'Position size', 'Position exposure', 'Result')
  $result = [ordered]@{ status = 'COPY_FAILED'; window = ''; rows = 0; grid_rows = -1
                        columns = @(); header_ok = $false; rows_ok = $false
                        result_sum = 0.0; expect_pnl = $null; pnl_ok = $true
                        path = ''; bytes = 0; popups_seen = 0; attempt_used = 0
                        log = [System.Collections.ArrayList]::new() }

  $proc = Get-Process BuildAlpha_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { $result.status = 'NO_BUILDALPHA'; return [pscustomobject]$result }
  $mainHwnd = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -eq 'Build Alpha' } | Select-Object -First 1
  $prevClip = ''
  try { $prevClip = Get-Clipboard -Raw } catch { }
  Mark-Trade 'clipboard-saved'

  try {
    # stale Trades windows hold the foreground and would block activation
    foreach ($h in (Get-VisibleWindows $proc.Id)) {
      if ((Get-WindowTitle $h) -like 'Trades - *') {
        [void](Close-WindowChecked -hwnd $h -ProcessId $proc.Id -Allowed @($mainHwnd))
      }
    }
    Mark-Trade 'stale-scan'
    $sourceHwnd = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like $WindowTitle } | Select-Object -First 1
    if (-not $sourceHwnd) { $result.status = 'WINDOW_MISSING'; return [pscustomobject]$result }
    Mark-Trade 'source-window'

    if ($script:InjectionPid) { Add-InjectionWindow $sourceHwnd }
    else { Set-InjectionGuard -ProcessId $proc.Id -Windows @($mainHwnd, $sourceHwnd) }
    # A child process starts with an empty guard, and the Re-Run dialog it does not know
    # about can take the foreground back while the results window appears - the right-click
    # then refused with BA_DIALOG_NOT_OURS. These windows are the run's own; register them.
    foreach ($h in (Get-VisibleWindows $proc.Id)) {
      $t = Get-WindowTitle $h
      if ($t -eq 'Re-Run' -or $t -like 'Re-Run results*') { Add-InjectionWindow $h }
    }
    [void](Focus-WindowFast $sourceHwnd)
    Mark-Trade 'activate-source'
    # The click point comes from the window's OWN cells, not from a hardcoded x list.
    # Measured failure (2026-11-01, tag 65qhzc5ip2): a results window whose grid starts at x=131
    # was right-clicked at x=120, x=60 and x=760 - the first two are left of every column and the
    # third lands in an empty one - so no context menu ever opened and the export ended
    # CONTEXT_MENU_MISSING after three attempts. A cell from the automation tree is exact, costs one
    # FindAll, and avoids GridPattern.GetItem, which was measured blocking for 300 s in these
    # windows. The legacy x list stays as a fallback for a window whose cells cannot be read.
    $anchorX = 0; $anchorY = 0
    try {
      $srcEl = [System.Windows.Automation.AutomationElement]::FromHandle($sourceHwnd)
      $textCells = @($srcEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.Name -match '^Row \d+ of \d+, Column (Symbol|Index|Name), ' })
      if ($textCells.Count) {
        $pick = $textCells[0]
        if ($RowY -gt 0) {
          # prefer the cell whose row contains the requested y
          $inside = $textCells | Where-Object {
            $rr = $_.Current.BoundingRectangle
            $RowY -ge $rr.Y -and $RowY -le ($rr.Y + $rr.Height)
          } | Select-Object -First 1
          if ($inside) { $pick = $inside }
        }
        $pr = $pick.Current.BoundingRectangle
        if ($pr.Width -gt 4 -and -not [double]::IsInfinity($pr.X)) {
          $anchorX = [int]($pr.X + $pr.Width / 2)
          $anchorY = [int]($pr.Y + $pr.Height / 2)
          [Console]::Error.WriteLine("trade anchor from cell: $anchorX,$anchorY ('$("$($pick.Current.Name)".Substring(0,[Math]::Min(50,"$($pick.Current.Name)".Length)))')")
        }
      }
    } catch { }
    if ($anchorX -gt 0) { $RowY = $anchorY }

    if ($RowY -le 0) {
      # A results window has exactly one data row, so its Y is taken from the grid's own
      # rectangle. Reading a cell there with GridPattern.GetItem was measured blocking for
      # 300 s when the window's provider was busy - which turned a 50 s run into 342 s and
      # made the caller time out. One bounding-rectangle read cannot do that.
      $srcWin = [System.Windows.Automation.AutomationElement]::FromHandle($sourceHwnd)
      $srcGrid = $srcWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'stratGrid')))
      if (-not $srcGrid) {
        $srcGrid = $srcWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
          (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataGrid)))
      }
      if (-not $srcGrid) { $result.status = 'GRID_MISSING'; return [pscustomobject]$result }
      $gr = $srcGrid.Current.BoundingRectangle
      if ([double]::IsInfinity($gr.Top) -or $gr.Top -lt -1000 -or ($gr.Bottom - $gr.Top) -lt 20) {
        $result.status = 'GRID_MISSING'
        return [pscustomobject]$result
      }
      if ($WindowTitle -like 'Re-Run results*') {
        $RowY = [int]($gr.Top + 40)          # single row, near the top of the grid
      } else {
        # a multi-row grid needs the exact row: refuse rather than click the wrong strategy
        $result.status = 'ROWY_REQUIRED'
        return [pscustomobject]$result
      }
    }
    Mark-Trade 'row-point'

    # ---- open the menu. The first right-click sometimes misses: the grid may not have
    # focus yet (right after a simulation the results window has only just appeared), and a
    # right-click on an unfocused DevExpress grid does nothing. So each attempt focuses,
    # left-clicks the row to give the grid focus, then right-clicks. Attempts also vary the
    # column, and from the second one a popup is accepted when it merely *contains* the item
    # (its AutomationId is not always GridContextMenu).
    $popup = [IntPtr]::Zero
    $directHit = $null
    $seenPopups = @()
    $attemptUsed = 0
    # Wait until the source grid actually exposes row 0: just after a simulation the results
    # window is up before its grid is populated, and right-clicking then does nothing.
    $srcProbe = [System.Windows.Automation.AutomationElement]::FromHandle($sourceHwnd)
    for ($i = 0; $i -lt 12 -and $srcProbe; $i++) {
      $g = $srcProbe.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::DataGrid)))
      $ready = $false
      if ($g) {
        $gp = $null
        [void]$g.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$gp)
        try { $ready = ($gp.Current.RowCount -gt 0 -and $null -ne $gp.GetItem(0, 0)) } catch { $ready = $false }
      }
      if ($ready) { break }
      Start-Sleep -Milliseconds 250
    }
    Mark-Trade 'grid-ready'

    foreach ($attempt in 1..3) {
      if ($popup -ne [IntPtr]::Zero -or $directHit) { break }
      $attemptUsed = $attempt
      $clickX = if ($anchorX -gt 0) { $anchorX } else { @(120, 60, 760)[[Math]::Min($attempt - 1, 2)] }
      [void](Focus-WindowFast $sourceHwnd)
      Start-Sleep -Milliseconds 150
      Invoke-LeftClick $clickX $RowY      # focus the grid; a right-click without it is ignored
      Start-Sleep -Milliseconds 150
      Invoke-RightClick $clickX $RowY
      $deadline = (Get-Date).AddSeconds(2.5)
      while ((Get-Date) -lt $deadline -and $popup -eq [IntPtr]::Zero -and -not $directHit) {
        foreach ($h in (Get-VisibleWindows $proc.Id)) {
          if ($h -eq $mainHwnd -or $h -eq $sourceHwnd) { continue }
          $title = Get-WindowTitle $h
          if ($title -like 'Trades - *' -or $title -like 'Re-Run results*') { continue }
          try { $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h) } catch { continue }
          if (-not $ae) { continue }
          $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'GridContextMenu')
          if ($ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)) { $popup = $h; break }
          # fallback: a menu drawn by another popup class still OCRs to 'Show Trades'
          if ($attempt -ge 2) {
            $r = Get-WindowRect $h
            $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
            if ($w -lt 80 -or $hh -lt 100 -or $hh -gt 700 -or [double]::IsInfinity($r.Left)) { continue }
            if (-not ($seenPopups -contains [int64]$h)) { $seenPopups += [int64]$h }
            foreach ($it in @(Get-MenuItems $h)) {
              if ($it.Text.Trim() -match 'show\s*trades') { $directHit = $it; break }
            }
          }
        }
        if ($popup -eq [IntPtr]::Zero -and -not $directHit) { Start-Sleep -Milliseconds 80 }
      }
      if ($popup -eq [IntPtr]::Zero -and -not $directHit) {
        Send-Escape
        # stderr, not stdout: anything on the output stream becomes part of the return value
        [Console]::Error.WriteLine(("context menu attempt {0} missed (x={1}); retrying" -f $attempt, $clickX))
        [void]$result.log.Add(("attempt {0} missed x={1}" -f $attempt, $clickX))
      }
    }
    if ($popup -eq [IntPtr]::Zero -and -not $directHit) {
      $result.status = 'CONTEXT_MENU_MISSING'
      $result.popups_seen = $seenPopups.Count
      $result.attempt_used = $attemptUsed
      foreach ($m in $script:TradeMarks) { [void]$result.log.Add($m) }
      return [pscustomobject]$result
    }
    $result.attempt_used = $attemptUsed

    if ($popup -ne [IntPtr]::Zero) {
      Mark-Trade 'menu-popup'
      $items = @(Get-MenuItems $popup)
      Mark-Trade 'menu-ocr'
      foreach ($it in $items) { if (-not $directHit -and $it.Text.Trim() -match 'show\s*trades') { $directHit = $it } }
    }
    if (-not $directHit) { Send-Escape; $result.status = 'MENU_ITEM_MISSING'; return [pscustomobject]$result }
    Invoke-LeftClick $directHit.X $directHit.Y
    Mark-Trade 'menu-click'

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $tradesHwnd = $null
    while ((Get-Date) -lt $deadline -and -not $tradesHwnd) {
      Start-Sleep -Milliseconds 150
      # compare with -not: $null -eq [IntPtr]::Zero is False in PowerShell, so the old
      # IntPtr sentinel let a missing window through and the next call got a null hwnd
      $tradesHwnd = Get-VisibleWindows $proc.Id | Where-Object { (Get-WindowTitle $_) -like 'Trades - *' } | Select-Object -First 1
    }
    if (-not $tradesHwnd) { $result.status = 'TRADES_WINDOW_TIMEOUT'; return [pscustomobject]$result }
    $tradesTitle = Get-WindowTitle $tradesHwnd
    $result.window = $tradesTitle
    Mark-Trade 'trades-window'

    if ($ExpectName) {
      $flatWant = ($ExpectName -replace '\s+', ' ').Trim()
      $flatGot = ($tradesTitle -replace '\s+', ' ').Trim()
      if (-not $flatGot.Contains($flatWant)) {
        [void](Close-WindowChecked -hwnd $tradesHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
        $result.status = 'NAME_MISMATCH'
        return [pscustomobject]$result
      }
    }

    $tw = [System.Windows.Automation.AutomationElement]::FromHandle($tradesHwnd)
    $tgrid = $null
    for ($i = 0; $i -lt 16 -and -not $tgrid; $i++) {
      $tgrid = $tw.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::DataGrid)))
      if (-not $tgrid) { Start-Sleep -Milliseconds 150 }
    }
    if (-not $tgrid) {
      if (-not $KeepWindow) { [void](Close-WindowChecked -hwnd $tradesHwnd -ProcessId $proc.Id -Allowed @($mainHwnd)) }
      $result.status = 'TRADES_GRID_MISSING'
      return [pscustomobject]$result
    }
    $tgp = $null
    [void]$tgrid.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$tgp)
    $result.grid_rows = $tgp.Current.RowCount
    Mark-Trade 'trades-grid'

    # activate (skipped when already in front) and click one cell so the grid owns focus
    Add-InjectionWindow $tradesHwnd
    [void](Focus-WindowFast $tradesHwnd)
    $first = $null
    try { $first = $tgp.GetItem(0, 0) } catch { }
    $trect = if ($first) { $first.Current.BoundingRectangle } else { $tgrid.Current.BoundingRectangle }
    Invoke-LeftClick ([int]($trect.Left + $trect.Width / 2)) ([int]($trect.Top + $trect.Height / 2))
    Start-Sleep -Milliseconds 120   # click -> focus, then copy
    Mark-Trade 'grid-focus'

    Set-Clipboard -Value 'BA_TRADES_SENTINEL'
    Send-Keys '^a' 'trades-select-all'
    Start-Sleep -Milliseconds 120
    Send-Keys '^c' 'trades-copy'
    $text = ''
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 100
      $text = Get-Clipboard -Raw
      if ($text -and $text -ne 'BA_TRADES_SENTINEL') { break }
    }
    Mark-Trade 'clipboard'
    if (-not $text -or $text -eq 'BA_TRADES_SENTINEL') {
      if (-not $KeepWindow) { [void](Close-WindowChecked -hwnd $tradesHwnd -ProcessId $proc.Id -Allowed @($mainHwnd)) }
      $result.status = 'COPY_FAILED'
      return [pscustomobject]$result
    }

    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -lt 1) { $result.status = 'COPY_FAILED'; return [pscustomobject]$result }
    $header = @($lines[0] -split "`t")
    $data = @($lines | Select-Object -Skip 1)
    # The app's trade table grew columns: measured 2026-11-01 it carries 14
    # (Trade, Symbol, Direction, Sample, Entry on, Exit on, Entry Value, Exit Value,
    # Account value, Position size, Position exposure, Exposure basis, Point value, Result),
    # so an exact 10-column match rejected a complete export as TRADES_SUSPECT. Require instead
    # that every column we depend on is present, in order, and let the app add more.
    $actual = @($header | ForEach-Object { "$_".Trim() })
    $headerOk = $actual.Count -ge $expectHeader.Count
    $cursor = 0
    foreach ($want in $expectHeader) {
      $found = -1
      for ($j = $cursor; $j -lt $actual.Count; $j++) {
        if ($actual[$j] -eq $want) { $found = $j; break }
      }
      if ($found -lt 0) { $headerOk = $false; break }
      $cursor = $found + 1
    }
    $result.columns = $header
    $result.header_ok = $headerOk

    # The Result column is found by NAME. Index 9 was hardcoded when the table had 10 columns;
    # with the app's 14-column table index 9 is Position size, so result_sum was the sum of
    # position sizes (519393.71 for a run whose net P&L was 131528.92) while still looking
    # plausible. A wrong number is worse than a missing one.
    $resultIdx = [array]::IndexOf($actual, 'Result')
    if ($resultIdx -lt 0) { $headerOk = $false; $result.header_ok = $false }
    $sum = 0.0
    if ($resultIdx -ge 0) {
      foreach ($line in $data) {
        $cols = $line -split "`t"
        if ($cols.Count -gt $resultIdx) {
          $v = 0.0
          if ([double]::TryParse(($cols[$resultIdx] -replace ',', '').Trim(), [ref]$v)) { $sum += $v }
        }
      }
    }
    $result.result_sum = [math]::Round($sum, 2)
    $result.rows = $data.Count
    $result.rows_ok = ($data.Count -eq $result.grid_rows)
    if (-not [double]::IsNaN($ExpectNetPnl)) {
      $result.expect_pnl = $ExpectNetPnl
      $result.pnl_ok = ([math]::Abs($sum - $ExpectNetPnl) -le $Tolerance)
    }

    if (-not $OutFile) {
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
      $slug = ($tradesTitle -replace '^Trades - ', '') -replace '[^A-Za-z0-9]+', '-'
      $slug = $slug.Substring(0, [Math]::Min(40, $slug.Length)).Trim('-')
      $OutFile = Join-Path $env:TEMP ("trades-$slug-$stamp.tsv")
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    [System.IO.File]::WriteAllText($OutFile, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $result.path = $OutFile
    $result.bytes = (Get-Item $OutFile).Length
    $result.status = if ($result.rows_ok -and $headerOk -and $result.pnl_ok) { 'TRADES_OK' } else { 'TRADES_SUSPECT' }

    if (-not $KeepWindow) {
      [void](Close-WindowChecked -hwnd $tradesHwnd -ProcessId $proc.Id -Allowed @($mainHwnd))
    }
    Mark-Trade 'close-window'
    # the marks travel inside the object: writing them to the output stream turns the return
    # value into an array (that is exactly how trades_detail became a list-of-strings)
    foreach ($m in $script:TradeMarks) { [void]$result.log.Add($m) }
    return [pscustomobject]$result
  }
  finally {
    try { Set-Clipboard -Value $prevClip } catch { }
    if ($script:TradeMarkClock) { $script:TradeMarkClock.Stop() }
  }
}

# --- OCR of the custom-drawn GridContextMenu -------------------------------
$script:AsTaskMethod = $null
function Await-Result($op, $type) {
  if (-not $script:AsTaskMethod) {
    $script:AsTaskMethod = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  }
  $m = $script:AsTaskMethod.MakeGenericMethod($type)
  $task = $m.Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  return $task.Result
}

function Get-MenuItems([IntPtr]$PopupHwnd) {
  $r = Get-WindowRect $PopupHwnd
  $L = $r.Left; $T = $r.Top
  $w = $r.Right - $R.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($L, $T, 0, 0, (New-Object System.Drawing.Size -ArgumentList $w, $h))
  $g.Dispose()
  $png = Join-Path $env:TEMP ('ba_menu_' + [guid]::NewGuid().ToString('N') + '.png')
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $file = Await-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
  $stream = Await-Result ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await-Result ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sbmp = Await-Result ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  $ocr = Await-Result ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])

  $items = @()
  foreach ($line in $ocr.Lines) {
    $x0 = 1e9; $y0 = 1e9; $x1 = -1e9; $y1 = -1e9
    foreach ($wd in $line.Words) {
      $br = $wd.BoundingRect
      if ($br.X -lt $x0) { $x0 = $br.X }
      if ($br.Y -lt $y0) { $y0 = $br.Y }
      if (($br.X + $br.Width) -gt $x1) { $x1 = $br.X + $br.Width }
      if (($br.Y + $br.Height) -gt $y1) { $y1 = $br.Y + $br.Height }
    }
    $items += [pscustomobject]@{
      Text = $line.Text
      X    = [int]($L + ($x0 + $x1) / 2)
      Y    = [int]($T + ($y0 + $y1) / 2)
    }
  }
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  return $items
}

# Opens the row context menu, OCRs it, and clicks the item matching -Regex.
# Returns $null if no popup appeared or (with -ListOnly) if nothing was clicked.
function Invoke-MenuItem([int]$ProcessId, [IntPtr]$MainHwnd, [string]$Regex, [switch]$ListOnly) {
  $popup = [IntPtr]::Zero
  $deadline = (Get-Date).AddSeconds(6)
  while ((Get-Date) -lt $deadline -and $popup -eq [IntPtr]::Zero) {
    foreach ($h in (Get-VisibleWindows $ProcessId)) {
      if ($h -eq $MainHwnd) { continue }
      try { $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h) } catch { continue }
      $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'GridContextMenu')
      if ($ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)) { $popup = $h; break }
    }
    if ($popup -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
  }
  if ($popup -eq [IntPtr]::Zero) { return $null }

  $items = @(Get-MenuItems $popup)
  foreach ($it in $items) { Write-Host "  menu: '$($it.Text)' @ $($it.X),$($it.Y)" }

  if ($ListOnly) { Send-Escape; return [pscustomobject]@{ Items = $items; Clicked = $null } }

  $hit = $null
  foreach ($it in $items) {
    if ($it.Text.Trim() -match $Regex) { $hit = $it; break }
  }
  if (-not $hit) { Send-Escape; return [pscustomobject]@{ Items = $items; Clicked = $null } }

  Invoke-LeftClick $hit.X $hit.Y
  return [pscustomobject]@{ Items = $items; Clicked = $hit.Text }
}

# Waits for a new window (title match optional) that contains a readable grid.
function Wait-NewGridWindow([int]$ProcessId, $BeforeHwnds, [int]$TimeoutSec = 180) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1200
    foreach ($h in (Get-VisibleWindows $ProcessId)) {
      if ($BeforeHwnds -contains $h) { continue }
      try { $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h) } catch { continue }
      $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'GridContextMenu')
      if ($ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)) { continue }
      $r = Get-WindowRect $h
      $grid = $null
      foreach ($off in @(@(250, 140), @(300, 160), @(200, 120))) {
        $el = Get-ElementAt ($r.Left + $off[0]) ($r.Top + $off[1])
        if ($el) { $grid = Get-DataGrid $el; if ($grid) { break } }
      }
      if (-not $grid) { continue }
      $rows = Read-Grid $grid
      $hasName = $false
      foreach ($rn in $rows.Keys) { if ($rows[$rn]['Name']) { $hasName = $true } }
      if ($rows.Count -gt 0 -and $hasName) {
        return [pscustomobject]@{ Hwnd = $h; Grid = $grid }
      }
    }
  }
  return $null
}

function Wait-NewWindowByTitle([int]$ProcessId, $BeforeHwnds, [string]$TitleRegex, [int]$TimeoutSec = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 600
    foreach ($h in (Get-VisibleWindows $ProcessId)) {
      if ($BeforeHwnds -contains $h) { continue }
      $t = Get-WindowTitle $h
      if ($t -match $TitleRegex) { return $h }
    }
  }
  return [IntPtr]::Zero
}

# OCRs a screen rectangle and returns words with absolute coordinates.
function Get-OcrWordsFromBitmap($bmp, [int]$Scale = 3, [int]$OffsetX = 0, [int]$OffsetY = 0) {
  # Bitmap -> words. Split out of Get-OcrWords so a region of an already-captured image can
  # be read without going back to the screen: for a window that is not in front, PrintWindow
  # pixels are right while a screen grab of the same rectangle is black or shows whatever is
  # on top of it.
  if (-not $bmp -or $bmp.Width -le 0 -or $bmp.Height -le 0) { return @() }
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $W = $bmp.Width; $H = $bmp.Height
  $scale = [Math]::Max(1, $Scale)
  $scaled = New-Object System.Drawing.Bitmap -ArgumentList ($W * $scale), ($H * $scale)
  $sg = [System.Drawing.Graphics]::FromImage($scaled)
  $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $sg.DrawImage($bmp, 0, 0, ($W * $scale), ($H * $scale))
  $sg.Dispose()
  $png = Join-Path $env:TEMP ('ba_ocr_' + [guid]::NewGuid().ToString('N') + '.png')
  $scaled.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $scaled.Dispose()

  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $file = Await-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
  $stream = Await-Result ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $dec = Await-Result ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await-Result ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  $res = Await-Result ($eng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])

  $out = @()
  foreach ($line in $res.Lines) {
    foreach ($wd in $line.Words) {
      $b = $wd.BoundingRect
      $out += [pscustomobject]@{ Text = $wd.Text; X = [int]($OffsetX + $b.X / $scale); Y = [int]($OffsetY + $b.Y / $scale) }
    }
  }
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  return $out
}

function Get-OcrWords([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 3) {
  if ($W -le 0 -or $H -le 0) { return @() }
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $W, $H
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size -ArgumentList $W, $H))
  $g.Dispose()
  try { return (Get-OcrWordsFromBitmap $bmp $Scale $X $Y) }
  finally { $bmp.Dispose() }
}

# Reads a region of an existing bitmap as text lines. Used for the Variance Testing panel: the
# image has already been captured, so the reading no longer depends on what is on top of it.
function Get-OcrLinesFromBitmap($bmp, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 4) {
  if (-not $bmp) { return @() }
  $x0 = [Math]::Max(0, $X); $y0 = [Math]::Max(0, $Y)
  $w = [Math]::Min($W, $bmp.Width - $x0); $h = [Math]::Min($H, $bmp.Height - $y0)
  if ($w -le 1 -or $h -le 1) { return @() }
  $crop = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
  $g = [System.Drawing.Graphics]::FromImage($crop)
  $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h),
    (New-Object System.Drawing.Rectangle -ArgumentList $x0, $y0, $w, $h),
    [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose()
  try {
    $words = @(Get-OcrWordsFromBitmap $crop $Scale 0 0)
  } finally { $crop.Dispose() }
  if (-not $words.Count) { return @() }
  $rows = @{}
  foreach ($wd in $words) {
    $k = [int]([math]::Round($wd.Y / 6.0) * 6)
    $rows[$k] = @($rows[$k]) + $wd
  }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($k in ($rows.Keys | Sort-Object)) {
    $text = (((@($rows[$k]) | Sort-Object X) | ForEach-Object { $_.Text }) -join ' ').Trim()
    if ($text) { $out.Add($text) }
  }
  return $out.ToArray()
}

# Reads a small region as text lines rather than words: words are grouped by their Y and
# joined left-to-right, which is what a label/value panel needs (the OCR engine returns
# separate words with no line structure of its own).
function Get-OcrLines([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 4) {
  $words = @(Get-OcrWords $X $Y $W $H $Scale)
  if (-not $words.Count) { return @() }
  $rows = @{}
  foreach ($wd in $words) {
    $k = [int]([math]::Round($wd.Y / 6.0) * 6)
    $rows[$k] = @($rows[$k]) + $wd
  }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($k in ($rows.Keys | Sort-Object)) {
    $text = (((@($rows[$k]) | Sort-Object X) | ForEach-Object { $_.Text }) -join ' ').Trim()
    if ($text) { $out.Add($text) }
  }
  return $out.ToArray()
}

# Reads a two-sided toggle button (e.g. Close|Next Open). UIA exposes only the
# toggle state, so the labels are OCR'd and the selected side is picked by state.
function Read-TogglePair($pane) {
  $btn = $null; $tp = $null
  $kids = $pane.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($k in $kids) {
    if ($k.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
        -not $k.Current.IsOffscreen -and
        $k.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) { $btn = $k; break }
  }
  if (-not $btn) { return '' }
  $state = $tp.Current.ToggleState.ToString()
  $pr = $pane.Current.BoundingRectangle
  $br = $btn.Current.BoundingRectangle
  if ([double]::IsInfinity($pr.X) -or [double]::IsInfinity($br.X)) { return '' }
  $x0 = [int]$pr.X + 70
  $w = [int]($br.Right - $x0)
  if ($w -lt 40) { return '' }
  $words = @(Get-OcrWords $x0 ([int]$pr.Y - 2) $w ([int]$pr.Height + 4))
  if ($words.Count -lt 1) { return '' }
  $mid = ([int]$br.X + [int]$br.Right) / 2
  $lw = @($words | Where-Object { $_.X -lt $mid -and $_.Text -notmatch '^[a-z]$' } | Sort-Object X)
  $rw = @($words | Where-Object { $_.X -ge $mid -and $_.Text -notmatch '^[a-z]$' } | Sort-Object X)
  $left = ((@($lw) | ForEach-Object { $_.Text }) -join ' ').Trim()
  $right = ((@($rw) | ForEach-Object { $_.Text }) -join ' ').Trim()
  if ($state -eq 'On' -and $right) { return $right }
  if ($state -eq 'Off' -and $left) { return $left }
  if ($right -and $left) { return "$right / $left" }
  if ($right -or $left) { return ($right + $left).Trim() }
  return $state
}

# Rounds spin-edit values to 6 decimal places and removes trailing zeros so
# float noise like 0.0015999999595806 becomes 0.0016.
function Format-SpinValue($value) {
  if ($null -eq $value) { return $value }
  $n = ConvertTo-Number $value
  if ($null -eq $n) { return $value }
  return [math]::Round($n, 6).ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-Number($value) {
  if ($null -eq $value) { return $null }
  $s = ($value -replace '[^\-\d.]', '')
  if ($s -eq '' -or $s -eq '-' -or $s -eq '.') { return $null }
  $n = 0.0
  if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Any,
      [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
  return $null
}

function Get-OosSplit {
  # In-sample / out-of-sample settings, read from the form. BuildAlpha stores
  # OutOfSamplePercent as a fraction (0.3 = 30%) - confirmed against its own serialized
  # config, which holds <OosLocation>1</OosLocation><OutOfSamplePercent>0.3</OutOfSamplePercent>
  # for a form that displays 'Out of Sample: End' and 'Out of Sample percent 0.3'.
  # The split date is derived, not read: there is no split field in the form, so it is
  # reported with its own provenance and never used as a check.
  param($Fields)
  $rawPct = "$($Fields['Out of Sample percent'])".Trim()
  $modeRaw = "$($Fields['Out of Sample'])".Trim()
  $fraction = $null
  $n = ConvertTo-Number $rawPct
  if ($null -ne $n) {
    # A fraction is 0..1; be tolerant of a form that ever shows whole percent.
    $fraction = if ($n -gt 1) { $n / 100 } else { $n }
  }
  if ($null -eq $fraction -or $fraction -le 0) {
    # out of sample disabled: say so, and do not report a zero percentage
    return [pscustomobject]@{ mode = 'off'; percent_raw = $rawPct; percentage = $null
                              fraction = $null; split_date = ''; basis = 'computed' }
  }
  $mode = 'unknown'
  if ($modeRaw -match '(?i)\bend\b') { $mode = 'End' }
  elseif ($modeRaw -match '(?i)\bbegin') { $mode = 'Begin' }
  elseif ($modeRaw) { $mode = $modeRaw }
  $splitDate = ''
  $s = [datetime]::MinValue; $e = [datetime]::MinValue
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  if ([datetime]::TryParse("$($Fields['Start Date'])", $inv,
        [System.Globalization.DateTimeStyles]::None, [ref]$s) -and
      [datetime]::TryParse("$($Fields['Stop Date'])", $inv,
        [System.Globalization.DateTimeStyles]::None, [ref]$e) -and $e -gt $s) {
    $span = $e - $s
    $split = if ($mode -eq 'Begin') { $s.AddTicks([int64]($span.Ticks * $fraction)) }
             else { $e.AddTicks(-[int64]($span.Ticks * $fraction)) }
    $splitDate = $split.ToString('yyyy-MM-dd')
  }
  return [pscustomobject]@{
    mode = $mode; percent_raw = $rawPct; percentage = [math]::Round($fraction * 100, 4)
    fraction = $fraction; split_date = $splitDate; basis = 'computed' }
}

function Get-OosPair {
  # A "Begin | End" toggle is two labels with one selected side. The form read only
  # returns the selected side, so the unselected one is not reported at all.
  param($Fields)
  $m = "$($Fields['Out of Sample'])".Trim()
  if (-not $m) { return '' }
  return $m
}

function ConvertFrom-OcrNumber([string]$text) {
  # The OCR engine reads the panel's slashed zero as 'ø'/'Ø' and often as 'l'. These
  # substitutions are limited to characters that cannot be anything else in a number, so a
  # clean reading is never changed:  ø Ø -> 0, l | -> 1, o O -> 0 next to a digit.
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $s = $text.Trim()
  $s = $s -replace '[øØ]', '0'
  $s = $s -replace '[l|]', '1'
  $s = $s -replace '(?<=\d)[oO](?=\d|$)', '0'
  $s = $s -replace '[^\-\d.]', ''
  if ($s -eq '' -or $s -eq '-' -or $s -eq '.') { return $null }
  $n = 0.0
  if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Any,
      [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
  return $null
}

function ConvertFrom-VarianceText([string[]]$Lines) {
  # Pure function: OCR lines -> the summary object. Split out from Read-VarianceSummary so the
  # parsing can be tested against recorded OCR text without a screen or a live window.
  $fields = [ordered]@{
    simulation = $null; make_money_count = $null; make_money_pct = $null
    ruin_count = $null; ruin_odds_pct = $null
    avg_pnl_dd = $null; avg_profit = $null; avg_drawdown = $null
    conf95_profit_low = $null; conf95_profit_high = $null
    conf95_drawdown_low = $null; conf95_drawdown_high = $null
  }
  $Lines = @($Lines | Where-Object { $_ -and "$_".Trim() })
  if (-not $Lines.Count) {
    return [pscustomobject]@{ Fields = $fields; Status = 'OCR_FAILED' }
  }
  # The engine returns lines in visual order, but a wrapped label splits away from its
  # value ('Ruin' / 'Count : 43'). Flattening the panel to one string lets a pattern span
  # that break, and keeps the column order so 'the second Count' is the Ruin count.
  $text = (($Lines -join ' ') -replace '\s+', ' ')

  function Grab([string]$pattern) {
    $m = [regex]::Match($text, $pattern, 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return (ConvertFrom-OcrNumber $m.Groups[1].Value)
  }
  function GrabAll([string]$pattern) {
    $out = @()
    foreach ($m in [regex]::Matches($text, $pattern, 'IgnoreCase')) {
      $v = ConvertFrom-OcrNumber $m.Groups[1].Value
      if ($null -ne $v) { $out += $v }
    }
    return $out
  }

  # 'Results of Simulation:' is a caption with no number of its own in this panel; it only
  # counts if a figure is actually printed next to it.
  $m = [regex]::Match($text, 'Results\s+of\s+(\d[\d,]{0,7})\s*(?:Sim|sim)', 'IgnoreCase')
  if ($m.Success) { $fields.simulation = ConvertFrom-OcrNumber $m.Groups[1].Value }

  $fields.make_money_count = Grab 'Make\s*M[o0a]ney\s*Count\s*:?\s*([\døØOol,]{1,9})'
  # the colon is required here: 'Make Money Count:' must not be read as the percentage, and
  # the trailing '%' is often split off into its own token, so it is not part of the pattern
  $fields.make_money_pct = Grab 'Make\s*M[o0a]ney\s*:\s*([\døØOol.,]{1,9})'
  $fields.ruin_count = Grab 'Ruin[^A-Za-z]{0,12}Count\s*:?\s*([\døØOol,]{1,9})'
  $fields.ruin_odds_pct = Grab 'Ruin\s*Odds\s*:?\s*([\døØOol.,]{1,9})'
  # the two columns read in order, so a merged line ('... Count: 1000 Count : 43') still
  # separates correctly when the labels were not recognised
  if ($null -eq $fields.ruin_count -or $null -eq $fields.ruin_odds_pct) {
    $counts = GrabAll 'Count\s*:?\s*([\døØOol,]{1,9})'
    $pcts = GrabAll '(?:Odds|Money)\s*:\s*([\døØOol.,]{1,9})'
    if ($null -eq $fields.make_money_count -and $counts.Count -ge 1) { $fields.make_money_count = $counts[0] }
    if ($null -eq $fields.ruin_count -and $counts.Count -ge 2) { $fields.ruin_count = $counts[1] }
    if ($null -eq $fields.make_money_pct -and $pcts.Count -ge 1) { $fields.make_money_pct = $pcts[0] }
    if ($null -eq $fields.ruin_odds_pct -and $pcts.Count -ge 2) { $fields.ruin_odds_pct = $pcts[1] }
  }

  $fields.avg_pnl_dd = Grab 'Average\s*PNLDD\s*:?\s*(-?[\døØOol.,]{1,10})'
  $fields.avg_profit = Grab 'Average\s*Profit\s*:?\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'
  $fields.avg_drawdown = Grab 'Average\s*Dr[ao]wdown\s*:?\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'
  # '95% Confident Profit' and 'Confident 95% Profit' both occur, depending on where the
  # engine breaks the wrapped label
  $fields.conf95_profit_low = Grab 'Confiden\w*\s*(?:\d+\s*%?\s*)?Profit\s*:?\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'
  $fields.conf95_profit_high = Grab 'Confiden\w*\s*(?:\d+\s*%?\s*)?Profit\s*:?\s*(?:USD)?\s*-?[\døØOol.,]{1,12}\s*(?:-|to|\s)\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'
  $fields.conf95_drawdown_low = Grab 'Confiden\w*\s*(?:\d+\s*%?\s*)?Dr[ao]wdown\s*:?\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'
  $fields.conf95_drawdown_high = Grab 'Confiden\w*\s*(?:\d+\s*%?\s*)?Dr[ao]wdown\s*:?\s*(?:USD)?\s*-?[\døØOol.,]{1,12}\s*(?:-|to|\s)\s*(?:USD)?\s*(-?[\døØOol.,]{1,12})'

  # A confidence interval whose low sits above its high is a misread (the engine dropped a
  # digit), and a misread number is worse than a missing one: both ends go null.
  foreach ($pair in @(@('conf95_profit_low', 'conf95_profit_high'),
                      @('conf95_drawdown_low', 'conf95_drawdown_high'))) {
    $lo = $fields[$pair[0]]; $hi = $fields[$pair[1]]
    if ($null -ne $lo -and $null -ne $hi -and $lo -gt $hi) {
      $fields[$pair[0]] = $null
      $fields[$pair[1]] = $null
    }
  }

  $read = @($fields.Values | Where-Object { $null -ne $_ }).Count
  $status = if ($read -eq 0) { 'OCR_FAILED' } elseif ($read -eq $fields.Count) { 'OK' } else { 'PARTIAL' }
  return [pscustomobject]@{ Fields = $fields; Status = $status }
}

function Read-VarianceSummaryBitmap($bmp) {
  # The panel occupies the bottom-left of the client area. Reading it from the captured
  # bitmap means the result cannot disagree with the saved image.
  if (-not $bmp) { return [pscustomobject]@{ Fields = $null; Status = 'OCR_FAILED' } }
  $y = [int]($bmp.Height * 0.58)
  $lines = @()
  try { $lines = @(Get-OcrLinesFromBitmap $bmp 0 $y $bmp.Width ($bmp.Height - $y) 6) } catch { $lines = @() }
  $parsed = ConvertFrom-VarianceText $lines
  return [pscustomobject]@{ Fields = $parsed.Fields; Status = $parsed.Status; Lines = $lines }
}

function Read-VarianceSummary([int]$X, [int]$Y, [int]$W, [int]$H) {
  # Statistics panel of the Variance Testing view: cropped out of the window rect (never the
  # whole screen) and upscaled before reading, because it is small white-on-black text.
  $lines = @()
  try { $lines = @(Get-OcrLines $X $Y $W $H 4) } catch { $lines = @() }
  $parsed = ConvertFrom-VarianceText $lines
  return [pscustomobject]@{ Fields = $parsed.Fields; Status = $parsed.Status; Lines = $lines }
}

function Compare-BARecord($Before, $After) {
  $keys = @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)
  $lines = New-Object System.Collections.Generic.List[string]
  $changed = 0
  foreach ($k in $keys) {
    $b = $Before[$k]; $a = $After[$k]
    $bn = ConvertTo-Number $b; $an = ConvertTo-Number $a
    $delta = ''
    if ($null -ne $bn -and $null -ne $an) {
      $d = $an - $bn
      if ([math]::Abs($d) -gt 1e-9) { $changed++; $delta = ('{0:0.######}' -f $d) }
    } elseif ("$b" -ne "$a") { $changed++ }
    $lines.Add(("{0}`t{1}`t{2}`t{3}" -f $k, $b, $a, $delta))
  }
  return [pscustomobject]@{ Lines = $lines; Changed = $changed; Total = $keys.Count }
}

# ---------------------------------------------------------------------------
# Form reading (Re-Run / Strategy Builder windows)
# ---------------------------------------------------------------------------

# Finds a visible BuildAlpha window by its exact title (e.g. 'Re-Run').
function Get-BAWindowByTitle([string]$Title) {
  $main = Get-MainWindow
  if (-not $main) { return $null }
  foreach ($h in (Get-VisibleWindows $main.Current.ProcessId)) {
    if ((Get-WindowTitle $h) -eq $Title) {
      return [System.Windows.Automation.AutomationElement]::FromHandle($h)
    }
  }
  return $null
}

function Get-ControlValue($el) {
  $vp = $null
  if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
    $v = $vp.Current.Value
    if ($v -and $v -notmatch '^System\.Collections') { return $v }
  }
  $tp = $null
  if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) {
    switch ($tp.Current.ToggleState.ToString()) {
      'On' { return 'True' }
      'Off' { return 'False' }
      default { return $tp.Current.ToggleState.ToString() }
    }
  }
  return ''
}

# Top-level tab strip only (skips nested symbol sub-tabs).
function Get-FormTabs($root) {
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  $tabs = @()
  foreach ($e in $all) {
    if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and
        $e.Current.ClassName -eq 'DXTabItem') { $tabs += $e }
  }
  if ($tabs.Count -le 1) { return $tabs }
  $minY = ($tabs | ForEach-Object { $_.Current.BoundingRectangle.Y } | Measure-Object -Minimum).Minimum
  return @($tabs | Where-Object { [math]::Abs($_.Current.BoundingRectangle.Y - $minY) -le 8 })
}

# Walks up to the enclosing LayoutGroup (the unit that pairs a GroupBox with
# its sibling spin edits) and returns a stable key.
function Get-LayoutGroupKey($el) {
  $p = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($el)
  for ($k = 0; $k -lt 10 -and $p; $k++) {
    if ($p.Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and
        $p.Current.ClassName -eq 'LayoutGroup') {
      return ($p.GetRuntimeId() -join '.')
    }
    if ($p.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) { break }
    $p = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($p)
  }
  return ''
}

function Select-FormTab($tab) {
  $sip = $null
  if ($tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sip)) {
    $sip.Select(); Start-Sleep -Milliseconds 900; return
  }
  $r = $tab.Current.BoundingRectangle
  if (-not [double]::IsInfinity($r.X)) {
    Invoke-LeftClick ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 900
  }
}

# Reads the Main tab's rule list (DataGrid 'listView'): one row per rule with
# the Signal text and its Entry / Required / Exit flags.
function Read-FormRules($root) {
  $out = @()
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'listView')
  $grid = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if (-not $grid) { return $out }
  $items = $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($it in $items) {
    if ($it.Current.ControlType -ne [System.Windows.Automation.ControlType]::DataItem) { continue }
    $text = ''
    $flags = @()
    $kids = $it.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($k in $kids) {
      $ct = $k.Current.ControlType
      if (-not $text -and $ct -eq [System.Windows.Automation.ControlType]::Text -and $k.Current.Name) {
        $text = ($k.Current.Name -replace '\s+', ' ').Trim()
        continue
      }
      if ($ct -eq [System.Windows.Automation.ControlType]::CheckBox) {
        $tp = $null
        $state = 'Off'
        if ($k.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) {
          $state = if ($tp.Current.ToggleState.ToString() -eq 'On') { 'On' } else { 'Off' }
        }
        $flags += $state
      }
    }
    if (-not $text) { continue }
    $names = @('Entry', 'Required', 'Exit')
    $parts = @()
    for ($i = 0; $i -lt $flags.Count; $i++) {
      $label = if ($i -lt $names.Count) { $names[$i] } else { "flag$i" }
      $parts += "$label=$($flags[$i])"
    }
    $out += [pscustomobject]@{ Text = $text; Flags = ($parts -join ' ') }
  }
  return $out
}

# Extracts labelled fields from the currently visible tab.
function Read-FormFields($root) {
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  $generic = '^(|LayoutItem|ComboBoxEdit|LookUpEdit|PART_Editor|TextBox|TextBlock|LayoutGroup|LayoutControl|GroupBox|Button|PART_Item|PART_Label|Custom)$'
  $recs = New-Object System.Collections.Generic.List[object]
  $seen = @{}

  # 1) GroupBoxes: CheckBox label, mode tab (ATR/Fixed/%), and the parameter
  #    grid's Base/Max/Step. The spins are siblings of the group box, so they
  #    are collected by document order: everything after the group box until
  #    the next group box or the next *labelled* LayoutItem pane.
  $allArr = @($all)
  for ($gi = 0; $gi -lt $allArr.Count; $gi++) {
    $e = $allArr[$gi]
    if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Group) { continue }
    if ($e.Current.ClassName -ne 'GroupBox') { continue }

    $label = ''; $state = ''
    $gd = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($d in $gd) {
      if (-not $label -and
          $d.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and
          $d.Current.Name) {
        $label = $d.Current.Name
        $state = Get-ControlValue $d
      }
    }
    if (-not $label) { continue }
    if ($seen.ContainsKey($label)) { continue }

    $units = @(); $spins = @(); $mode = ''
    for ($j = $gi + 1; $j -lt $allArr.Count; $j++) {
      $q = $allArr[$j]
      if ($q.Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and
          $q.Current.ClassName -eq 'GroupBox') { break }
      if ($q.Current.ControlType -eq [System.Windows.Automation.ControlType]::Pane -and
          $q.Current.ClassName -eq 'LayoutItem') {
        $qn = ($q.Current.Name -replace '\s+', ' ').Trim()
        if ($qn -and $qn -notmatch $generic) { break }
        continue
      }
      if ($q.Current.ClassName -eq 'PageViewItem') {
        $unit = $q.Current.Name.Trim()
        $units += $unit
        $sip = $null
        if ($q.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sip) -and $sip.Current.IsSelected) {
          $mode = $unit
        }
      } elseif ($q.Current.ClassName -eq 'SpinEdit') {
        $spins += (Get-ControlValue $q)
      }
    }

    $seen[$label] = 1
    $shown = $state
    if ($shown -eq 'True') { $shown = 'On' } elseif ($shown -eq 'False') { $shown = 'Off' }
    $recs.Add([pscustomobject]@{ Label = $label; Value = $shown; Kind = 'CheckBox'; Group = $label }) | Out-Null
    if ($mode) {
      $recs.Add([pscustomobject]@{ Label = "$label Mode"; Value = $mode; Kind = 'ModeTab'; Group = $label }) | Out-Null
    }
    # The three spins are the parameter grid's Base / Max / Step columns.
    if ($spins.Count -ge 3) {
      $cols = @('Base', 'Max', 'Step')
      for ($i = 0; $i -lt 3; $i++) {
        $recs.Add([pscustomobject]@{ Label = "$label $($cols[$i])"; Value = $spins[$i]; Kind = 'SpinEdit'; Group = $label }) | Out-Null
      }
    }
  }

  # 2) Symbol selectors: OCR the rendered symbol, pair it with its timeframe.
  foreach ($e in $all) {
    if ($e.Current.ClassName -ne 'SymbolsSelector') { continue }
    $r = $e.Current.BoundingRectangle
    if ([double]::IsInfinity($r.X) -or $r.X -lt -1000) { continue }
    $label = ''; $bestX = -1e9
    foreach ($t in $all) {
      if ($t.Current.ControlType -ne [System.Windows.Automation.ControlType]::Text) { continue }
      if (-not $t.Current.Name) { continue }
      $tr = $t.Current.BoundingRectangle
      if ([double]::IsInfinity($tr.X) -or $tr.X -lt -1000) { continue }
      if ([math]::Abs($tr.Y - $r.Y) -gt 8) { continue }
      if ($tr.X -ge $r.X) { continue }
      if ($tr.X -gt $bestX) { $bestX = $tr.X; $label = $t.Current.Name }
    }
    if (-not $label) { $label = $e.Current.Name }
    $label = ($label -replace '\s+', ' ').Trim()
    if (-not $label -or $label -match $generic) { continue }
    if ($seen.ContainsKey($label)) { continue }
    $words = @(Get-OcrWords ([int]$r.X + 4) ([int]$r.Y) ([int]($r.Width - 26)) ([int]$r.Height))
    $sym = (@($words | ForEach-Object { $_.Text }) -join ' ').Trim()
    $sym = (($sym -replace '\s*[XxÃ—]\s*$', '') -replace '\s*â€”\s*', '-').Trim()
    if ($sym -match '^(Select|Select\.\.\.)$') { $sym = '' }
    $tf = ''
    foreach ($c in $all) {
      if ($c.Current.ClassName -ne 'ComboBoxEdit') { continue }
      $cr = $c.Current.BoundingRectangle
      if ([double]::IsInfinity($cr.X) -or $cr.X -lt -1000) { continue }
      if ([math]::Abs($cr.Y - $r.Y) -gt 8) { continue }
      if ($cr.X -le $r.X) { continue }
      $tf = Get-ControlValue $c
      if ($tf) { break }
    }
    $shown = $sym
    if (-not $shown) { $shown = '(none)' }
    if ($tf) { $shown = "$shown ($tf)" }
    $seen[$label] = 1
    $recs.Add([pscustomobject]@{ Label = $label; Value = $shown; Kind = 'Symbols'; Group = '' }) | Out-Null
  }

  # 3) LayoutItem Panes: prefer the visible control (hidden template checkboxes
  #    are skipped) and read two-sided toggle buttons from their rendered label.
  foreach ($e in $all) {
    if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Pane) { continue }
    if ($e.Current.ClassName -ne 'LayoutItem') { continue }
    $nm = ($e.Current.Name -replace '\s+', ' ').Trim()
    if (-not $nm -or $nm -match $generic) { continue }
    if ($seen.ContainsKey($nm)) { continue }

    $kids = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    $cands = @()
    foreach ($k in $kids) {
      $ct = $k.Current.ControlType
      if ($k.Current.ClassName -eq 'TextBox') { continue }
      if ($ct -eq [System.Windows.Automation.ControlType]::Button -and $k.Current.AutomationId -like 'PART_*') { continue }
      if ($ct -notin @([System.Windows.Automation.ControlType]::ComboBox,
          [System.Windows.Automation.ControlType]::CheckBox,
          [System.Windows.Automation.ControlType]::Edit,
          [System.Windows.Automation.ControlType]::Slider,
          [System.Windows.Automation.ControlType]::Spinner,
          [System.Windows.Automation.ControlType]::Button)) { continue }
      $v = Get-ControlValue $k
      if (-not $v) { continue }
      $isCheck = ($ct -eq [System.Windows.Automation.ControlType]::CheckBox -or
        $ct -eq [System.Windows.Automation.ControlType]::Button)
      $cands += [pscustomobject]@{ Kind = $k.Current.ClassName; Value = $v; Off = $k.Current.IsOffscreen; IsCheck = $isCheck }
    }
    if ($cands.Count -eq 0) { continue }
    $vis = @($cands | Where-Object { -not $_.Off })
    if ($vis.Count -eq 0) { $vis = $cands }

    $nonCheck = @($vis | Where-Object { -not $_.IsCheck })
    $check = @($vis | Where-Object { $_.IsCheck })

    if ($nonCheck.Count -eq 0) {
      $pair = ''
      if ($check[0].Kind -eq 'Button') { $pair = Read-TogglePair $e }
      if ($pair) {
        $seen[$nm] = 1
        $recs.Add([pscustomobject]@{ Label = $nm; Value = $pair; Kind = 'TogglePair'; Group = '' }) | Out-Null
      } else {
        $v = $check[0].Value
        if ($v -eq 'True') { $v = 'On' } elseif ($v -eq 'False') { $v = 'Off' }
        $seen[$nm] = 1
        $recs.Add([pscustomobject]@{ Label = $nm; Value = $v; Kind = $check[0].Kind; Group = '' }) | Out-Null
      }
      continue
    }

    $v = $nonCheck[0].Value
    if ($v -eq 'True') { $v = 'On' } elseif ($v -eq 'False') { $v = 'Off' }
    $seen[$nm] = 1
    $recs.Add([pscustomobject]@{ Label = $nm; Value = $v; Kind = $nonCheck[0].Kind; Group = '' }) | Out-Null
    if ($check.Count -gt 0) {
      $cv = $check[0].Value
      if ($cv -eq 'True') { $cv = 'On' } elseif ($cv -eq 'False') { $cv = 'Off' }
      $recs.Add([pscustomobject]@{ Label = "$nm Enabled"; Value = $cv; Kind = 'CheckBox'; Group = '' }) | Out-Null
    }
  }

  # 3) Free-standing controls that already carry a real name.
  foreach ($e in $all) {
    $ct = $e.Current.ControlType
    if ($ct -notin @([System.Windows.Automation.ControlType]::ComboBox,
        [System.Windows.Automation.ControlType]::CheckBox,
        [System.Windows.Automation.ControlType]::Edit)) { continue }
    if ($e.Current.ClassName -in @('TextBox', 'PART_Editor')) { continue }
    $nm = ($e.Current.Name -replace '\s+', ' ').Trim()
    if (-not $nm -or $nm -match $generic) { continue }
    if ($seen.ContainsKey($nm)) { continue }
    $v = Get-ControlValue $e
    if (-not $v) { continue }
    if ($v -eq 'True') { $v = 'On' } elseif ($v -eq 'False') { $v = 'Off' }
    $seen[$nm] = 1
    $recs.Add([pscustomobject]@{ Label = $nm; Value = $v; Kind = $e.Current.ClassName; Group = '' }) | Out-Null
  }

  # 4) Generic-named combos: label from the nearest Text on the same row (left).
  foreach ($e in $all) {
    $ct = $e.Current.ControlType
    if ($ct -notin @([System.Windows.Automation.ControlType]::ComboBox,
        [System.Windows.Automation.ControlType]::Edit)) { continue }
    if ($e.Current.ClassName -ne 'ComboBoxEdit') { continue }
    $r = $e.Current.BoundingRectangle
    if ([double]::IsInfinity($r.X) -or $r.X -lt -1000) { continue }
    $v = Get-ControlValue $e
    if (-not $v) { continue }
    $bestLabel = ''; $bestX = -1e9
    foreach ($t in $all) {
      if ($t.Current.ControlType -ne [System.Windows.Automation.ControlType]::Text) { continue }
      if (-not $t.Current.Name) { continue }
      $tr = $t.Current.BoundingRectangle
      if ([double]::IsInfinity($tr.X) -or $tr.X -lt -1000) { continue }
      if ($tr.X -ge $r.X) { continue }
      if ([math]::Abs($tr.Y - $r.Y) -gt 10) { continue }
      if ($tr.X -gt $bestX) { $bestX = $tr.X; $bestLabel = $t.Current.Name }
    }
    if (-not $bestLabel) { continue }
    $bestLabel = ($bestLabel -replace '\s+', ' ').Trim()
    if ($seen.ContainsKey($bestLabel)) { continue }
    $seen[$bestLabel] = 1
    $recs.Add([pscustomobject]@{ Label = $bestLabel; Value = $v; Kind = 'ComboBox'; Group = '' }) | Out-Null
  }

  # Spin editors hold doubles, so their text can carry float noise
  # (0.0015999999595806). Round to 6 dp and drop trailing zeros.
  foreach ($r in $recs) {
    if ($r.Kind -eq 'SpinEdit') { $r.Value = Format-SpinValue $r.Value }
  }

  return $recs
}
