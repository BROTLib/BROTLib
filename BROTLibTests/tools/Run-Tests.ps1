<#
.SYNOPSIS
  Deploys BROTLibTests to a TwinCAT runtime, runs the TcUnit suites and reports the result.

.DESCRIPTION
  1. Drives a hidden XAE instance (automation interface) to target the runtime, generate the boot project with
     autostart, activate the configuration and restart TwinCAT in run mode.
  2. Polls the runtime over ADS until TcUnit reports that all test suites finished, then reads the counters.
  3. Exits 0 if every test case passed, 1 if any failed, 2 if the run did not finish in time.

  The per-assertion failure messages go to the TwinCAT ADS log (XAE error list / event logger); this script only
  reports the counters. Build first (TcBuild build BROTLibTests.sln) so the compiled project is current.

  Target: the default is the beta user-mode runtime (Runtimes\UmRT_Default\Start.bat, AmsNetId 192.168.4.1.1.1),
  which is how tests run on a Windows 11 machine, where the 4024 real-time runtime does not work. It must already
  be running. The runtime needs a (trial) license for the PLC; activation fails without one.

  This overwrites whatever boot project is on the target runtime.
#>
[CmdletBinding()]
param(
    [string]$Solution    = (Join-Path $PSScriptRoot '..\BROTLibTests.sln'),
    [string]$TargetNetId = '192.168.4.1.1.1',
    [string]$PlcTreePath = 'TIPC^BROTLibTests',
    [int]$TimeoutSeconds = 120,
    [string]$AdsDll      = 'C:\TwinCAT\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll'
)
$ErrorActionPreference = 'Stop'
$Solution = (Resolve-Path $Solution).Path

# XAE rejects COM calls (RPC_E_CALL_REJECTED 0x80010001 / RPC_E_SERVERCALL_RETRYLATER 0x8001010A) while it is
# busy. PowerShell wraps the COMException, so match on the text.
function Invoke-Retry([scriptblock]$Action, [int]$Tries = 60, [int]$DelayMs = 1000) {
    for ($i = 1; ; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $Tries -or $_.Exception.ToString() -notmatch '0x80010001|0x8001010A|RPC_E_') { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# --- 1. deploy ---------------------------------------------------------------------------------------------
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
    $plc    = Invoke-Retry { ,$sysMan.LookupTreeItem($PlcTreePath) }

    Write-Host "Targeting $TargetNetId"
    Invoke-Retry { $sysMan.SetTargetNetId($TargetNetId) }
    # BootProjectAutostart / GenerateBootProject live on the PLC project's root node, not on its inner
    # "<name> Project" node. Without autostart the PLC is loaded but never started after the restart.
    Invoke-Retry { $plc.BootProjectAutostart = $true }
    Invoke-Retry { $plc.GenerateBootProject($true) }
    Write-Host 'Activating configuration and restarting TwinCAT in run mode'
    Invoke-Retry { $sysMan.ActivateConfiguration() }
    Invoke-Retry { $sysMan.StartRestartTwinCAT() }
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

# --- 2. wait for TcUnit and read the counters ------------------------------------------------------------------
Add-Type -Path $AdsDll
$runner = 'GVL_TcUnit.TcUnitRunner'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$client = New-Object TwinCAT.Ads.TcAdsClient
$finished = $false
try {
    $client.Connect($TargetNetId, 851)
    while ((Get-Date) -lt $deadline -and -not $finished) {
        try { $finished = [bool]$client.ReadSymbol("$runner.AllTestSuitesFinished", [bool], $false) }
        catch { Start-Sleep -Seconds 1 }   # symbols are not there until the PLC has started
        if (-not $finished) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $finished) {
        Write-Host "TcUnit did not report completion within $TimeoutSeconds s."
        exit 2
    }
    $res = "$runner.TestResults.TestSuiteResults"
    $suites = [int]$client.ReadSymbol("$res.NumberOfTestSuites", [uint16], $false)
    $cases  = [int]$client.ReadSymbol("$res.NumberOfTestCases", [uint16], $false)
    $ok     = [int]$client.ReadSymbol("$res.NumberOfSuccessfulTestCases", [uint16], $false)
    $failed = [int]$client.ReadSymbol("$res.NumberOfFailedTestCases", [uint16], $false)
}
finally { $client.Dispose() }

Write-Host ("TcUnit: {0} test suites, {1} test cases, {2} passed, {3} failed" -f $suites, $cases, $ok, $failed)
if ($failed -gt 0) {
    Write-Host 'Failure details are in the TwinCAT ADS log (XAE error list / event logger).'
    exit 1
}
exit 0
