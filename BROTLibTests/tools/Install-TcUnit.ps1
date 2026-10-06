<#
.SYNOPSIS
  Installs the vendored TcUnit library into the local TwinCAT library repository.

.DESCRIPTION
  BROTLibTests references TcUnit as a placeholder ("TcUnit, * (www.tcunit.org)"), which only resolves if
  the library is installed in the machine's library repository. There is no command-line installer for a
  plain .library file (TcBuild's `install` only installs a PLC project as a library), so this drives XAE
  through its automation interface, the same call as Library Repository -> Install in the GUI.

  Run once per machine (and again after a TwinCAT reinstall). Needs TcXaeShell; no runtime, no license.
  It starts its own hidden XAE instance and always quits it: a stray TcXaeShell.exe left behind makes the
  next TcBuild run fail with exit code 1 (see BROTLib specs/plans/2026-09-15-twincat-ci-investigation.md).
#>
[CmdletBinding()]
param(
    [string]$Solution = (Join-Path $PSScriptRoot '..\BROTLibTests.sln'),
    [string]$Library  = (Join-Path $PSScriptRoot '..\vendor\tcunit.library'),
    [string]$PlcTreePath = 'TIPC^BROTLibTests^BROTLibTests Project^References',
    [int]$LockTimeoutMinutes = 60
)
$ErrorActionPreference = 'Stop'
$Solution = (Resolve-Path $Solution).Path
$Library  = (Resolve-Path $Library).Path

# XAE rejects COM calls (RPC_E_CALL_REJECTED 0x80010001 / RPC_E_SERVERCALL_RETRYLATER 0x8001010A) while it
# is busy starting up or loading a solution. PowerShell wraps the COMException, so match on the text.
function Invoke-Retry([scriptblock]$Action, [int]$Tries = 60, [int]$DelayMs = 1000) {
    for ($i = 1; ; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $Tries -or $_.Exception.ToString() -notmatch '0x80010001|0x8001010A|RPC_E_') { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# One TwinCAT test/XAE job at a time on this machine: the user-mode runtime and XAE are shared by CI runs, the
# test scripts of the other repos and local runs. A named mutex serialises them; it is released when the script
# ends, and taken over if the previous holder died.
$lock = New-Object System.Threading.Mutex($false, 'Global\BROT-TwinCAT-UmRT')
$locked = $false
try { $locked = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) {
    Write-Host "Another TwinCAT test run is in progress, waiting up to $LockTimeoutMinutes min for it to finish..."
    try { $locked = $lock.WaitOne([TimeSpan]::FromMinutes($LockTimeoutMinutes)) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
}
if (-not $locked) { throw "Another TwinCAT test run still held the lock after $LockTimeoutMinutes min." }
try {
    # Only ever clean up the XAE instance this script started, never one the user has open.
    # The instance is identified right after it was created: anything that shows up in TcXaeShell later (the user
    # starting XAE during the run) is not ours.
    $xaeBefore = @(Get-Process TcXaeShell -ErrorAction SilentlyContinue | ForEach-Object Id)
    $xaeOwn = @()
    $dte = $null
    try {
        $dte = New-Object -ComObject 'TcXaeShell.DTE.15.0'
        $xaeOwn = @(Get-Process TcXaeShell -ErrorAction SilentlyContinue | Where-Object { $xaeBefore -notcontains $_.Id } | ForEach-Object Id)
        # XAE is not ready right after the COM object exists: Solution stays null while it starts up
        for ($n = 0; $null -eq (Invoke-Retry { $dte.Solution }); $n++) {
            if ($n -ge 120) { throw 'XAE did not become ready (DTE.Solution stayed null for 120 s).' }
            Start-Sleep -Seconds 1
        }
        Invoke-Retry { $dte.SuppressUI = $true }
        Invoke-Retry { $dte.UserControl = $false }
        Invoke-Retry { $dte.Solution.Open($Solution) }
        # the project loads asynchronously after Open() returns: first the project, then its system manager object
        # (the leading commas stop PowerShell from unrolling these enumerable COM tree items into arrays)
        $sysMan = $null
        for ($i = 0; $null -eq $sysMan; $i++) {
            if ($i -ge 60) { throw "XAE did not load a TwinCAT project from $Solution" }
            if ((Invoke-Retry { $dte.Solution.Projects.Count }) -ge 1) {
                $sysMan = Invoke-Retry { ,$dte.Solution.Projects.Item(1).Object }
            }
            if ($null -eq $sysMan) { Start-Sleep -Seconds 1 }
        }
        $refs   = Invoke-Retry { ,$sysMan.LookupTreeItem($PlcTreePath) }
        Invoke-Retry { $refs.InstallLibrary('System', $Library, $true) }
        Write-Host "Installed $Library into the 'System' library repository."
    }
    finally {
        if ($dte) {
            try { Invoke-Retry { $dte.Solution.Close($false) } } catch { }
            # If COM attached to an XAE that was already open instead of starting its own, do not quit that one.
            if ($xaeOwn.Count -gt 0) { try { Invoke-Retry { $dte.Quit() } } catch { } }
            else { Write-Warning 'No new XAE process appeared; not quitting the XAE instance that was already open.' }
        }
        Start-Sleep -Seconds 3
        Get-Process TcXaeShell -ErrorAction SilentlyContinue | Where-Object { $xaeOwn -contains $_.Id } | ForEach-Object {
            Write-Warning "XAE instance $($_.Id) did not quit; killing it."
            Stop-Process -Id $_.Id -Force
        }
    }
}
finally { $lock.ReleaseMutex(); $lock.Dispose() }
