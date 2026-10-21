<#
.SYNOPSIS
  Logs what could keep TcXaeShell busy when TcBuild fails with exit 3 (RPC_E_SERVERCALL_RETRYLATER).

.DESCRIPTION
  The TcBuild steps call this when a try ends with exit 3. It only reads and logs, never changes anything, and
  never fails the step (best effort). It must not end with 'exit': that would reset $LASTEXITCODE, which the
  caller still needs. Writes, as a collapsible log group:
    - the TwinCAT / build related processes with session, start time, responding state and main window title
    - every top-level window of those processes, including hidden ones: a modal dialog nobody can dismiss in the
      session of the runner service blocks COM calls and shows up here (visible, enabled, title, class)
    - recent Application event log errors of those processes
#>
param([string]$Label = '')
$ErrorActionPreference = 'Continue'
Write-Host "::group::XAE busy diagnostics $Label"
try {
    Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class XaeWin {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public static List<string> Windows(HashSet<uint> pids) {
    var r = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pids.Contains(pid)) {
        var t = new StringBuilder(256); var c = new StringBuilder(256);
        GetWindowText(h, t, 256); GetClassName(h, c, 256);
        r.Add(string.Format("pid {0} hwnd {1} visible={2} enabled={3} class='{4}' title='{5}'", pid, h, IsWindowVisible(h), IsWindowEnabled(h), c, t));
      }
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@
    $names = 'TcXaeShell', 'TcBuild', 'devenv', 'ServiceHub*', 'TcSystemServiceUm', 'WerFault', 'msiexec'
    $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    Write-Host "Runner session: $((Get-Process -Id $PID).SessionId)"
    if ($procs.Count -eq 0) { Write-Host 'No TcXaeShell / TcBuild / devenv / WerFault process.' }
    foreach ($p in $procs) {
        $start = try { $p.StartTime.ToString('s') } catch { '?' }
        Write-Host ("{0} pid {1} session {2} started {3} responding={4} threads={5} cpu={6}s title='{7}'" -f
            $p.ProcessName, $p.Id, $p.SessionId, $start, $p.Responding, $p.Threads.Count, [math]::Round($p.CPU), $p.MainWindowTitle)
    }
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    foreach ($p in $procs) { [void]$pids.Add([uint32]$p.Id) }
    $windows = [XaeWin]::Windows($pids)
    Write-Host "Top-level windows of these processes: $($windows.Count)"
    $windows | ForEach-Object { Write-Host "  $_" }

    $since = (Get-Date).AddMinutes(-15)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'TcXaeShell|TcBuild|devenv|TwinCAT' } | Select-Object -First 5)
    Write-Host "Application log errors about TwinCAT in the last 15 min: $($events.Count)"
    foreach ($e in $events) { Write-Host ("  {0} {1}: {2}" -f $e.TimeCreated.ToString('s'), $e.ProviderName, (($e.Message -split "`n")[0])) }
}
catch { Write-Host "Diagnostics failed: $($_.Exception.Message)" }
Write-Host '::endgroup::'
