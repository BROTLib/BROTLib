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
    [string]$PlcTreePath = 'TIPC^BROTLibTests^BROTLibTests Project^References'
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

# Only ever clean up the XAE instance this script started, never one the user has open.
$xaeBefore = @(Get-Process TcXaeShell -ErrorAction SilentlyContinue | ForEach-Object Id)
$dte = $null
try {
    $dte = New-Object -ComObject 'TcXaeShell.DTE.15.0'
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
        try { Invoke-Retry { $dte.Quit() } } catch { }
    }
    Start-Sleep -Seconds 3
    Get-Process TcXaeShell -ErrorAction SilentlyContinue | Where-Object { $xaeBefore -notcontains $_.Id } | ForEach-Object {
        Write-Warning "XAE instance $($_.Id) did not quit; killing it."
        Stop-Process -Id $_.Id -Force
    }
}
