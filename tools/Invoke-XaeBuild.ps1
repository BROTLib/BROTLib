<#
.SYNOPSIS
  Builds a TwinCAT solution, or saves and installs one of its PLC projects as a library, through the XAE
  automation interface. Replaces `TcBuild.exe build|install`.

.DESCRIPTION
  TcBuild starts XAE and gives up with exit 3 (RPC_E_SERVERCALL_RETRYLATER) when XAE does not answer within
  about 17 s. A cold XAE start on the CI machine is CPU bound for longer than that, so every try failed the same
  way and retrying only restarted XAE from zero. This script drives XAE the way BROTLibTests/tools/Run-Tests.ps1
  does: it waits for XAE to become ready (up to 120 s) and retries COM calls while XAE is busy.

  build   builds the solution (the compile; the errors and warnings of the error list are printed as `E:` / `W:`)
  install checks all objects of the PLC project, saves it as a library file and installs it into the library
          repository of the machine (like `TcBuild install -x <xae> -p <plc> -l <file>`)

  Exit codes like TcBuild: 0 = ok, 1 = ok with compile warnings, 2 = compile errors, 4 = anything else (XAE did
  not start, project did not load, ...).

  One TwinCAT job at a time on this machine: it takes the same named mutex as Run-Tests.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('build', 'install')][string]$Command,
    [Parameter(Mandatory, Position = 1)][string]$Solution,
    # install only: the XAE project (as named in the solution), the PLC project in it, and the library file to write
    [string]$XaeProject,
    [string]$PlcProject,
    [string]$LibraryFile,
    # where TcBuild is installed (its interop assembly is used to read the error list)
    [string]$TcBuildDir = 'C:\Program Files\Industrial Brains B.V\TcBuild',
    # install only: write the library file but do not install it into the library repository (dry run)
    [switch]$SkipInstall,
    [int]$ReadyTimeoutSeconds = 120,
    [int]$LockTimeoutMinutes = 60
)
$ErrorActionPreference = 'Stop'
$Solution = (Resolve-Path $Solution).Path
if ($Command -eq 'install' -and (-not $XaeProject -or -not $PlcProject -or -not $LibraryFile)) {
    throw 'install needs -XaeProject, -PlcProject and -LibraryFile.'
}

# XAE rejects COM calls (RPC_E_CALL_REJECTED 0x80010001 / RPC_E_SERVERCALL_RETRYLATER 0x8001010A) while it is
# busy. PowerShell wraps the COMException, so match on the text. While XAE is still starting or loading the
# solution, DTE.Solution / Solution.Projects can also be null for a moment, which is retried too.
function Invoke-Retry([scriptblock]$Action, [int]$Tries = 120, [int]$DelayMs = 1000) {
    for ($i = 1; ; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $Tries -or $_.Exception.ToString() -notmatch '0x80010001|0x8001010A|RPC_E_|null-valued expression') { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# The messages of the XAE error list. PowerShell cannot cast the DTE object to EnvDTE80.DTE2 (the error list is
# not reachable through the late bound DTE), so a small compiled helper does it, like TcBuild does: the error list
# is the selection of the window with the error list GUID, with ToolWindows.ErrorList as the fallback. It needs the
# interop assembly of TcBuild (installed on the runner anyway). SuppressUI must stay off for this to work.
$interop = Join-Path $TcBuildDir 'Microsoft.VisualStudio.Interop.dll'
[void][Reflection.Assembly]::LoadFrom($interop)
Add-Type -ReferencedAssemblies $interop -TypeDefinition @'
using System;
using System.Collections.Generic;
using EnvDTE;
using EnvDTE80;
public static class XaeErrorList {
  public static string[] Read(object dte) {
    var d = (DTE2)dte;
    ErrorItems items = null;
    try { items = ((ErrorList)d.Windows.Item("{D78612C7-9962-4B83-95D9-268046DAD23A}").Selection).ErrorItems; }
    catch (Exception) { }
    if (items == null) items = d.ToolWindows.ErrorList.ErrorItems;
    var r = new List<string>();
    for (int i = 1; i <= items.Count; i++) {
      var it = items.Item(i);
      r.Add(((int)it.ErrorLevel) + "|" + it.FileName + "|" + it.Line + "|" + it.Description);
    }
    return r.ToArray();
  }
}
'@

# Prints the error list as `E:` / `W:` / `I:` lines (the format TcBuild prints) and returns the counts.
# ErrorLevel: 4 = error, 2 = warning, 1 = message.
function Write-ErrorList($dte) {
    $errors = 0; $warnings = 0
    try {
        foreach ($line in [XaeErrorList]::Read($dte)) {
            $level, $file, $row, $text = $line.Split('|', 4)
            $where = if ($file) { "${file}:$row - " } else { '' }
            switch ($level) {
                '4' { $errors++;   Write-Host "E: $where$text" }
                '2' { $warnings++; Write-Host "W: $where$text" }
                default { Write-Host "I: $where$text" }
            }
        }
    }
    catch { Write-Host "::warning::Could not read the XAE error list: $($_.Exception.Message)" }
    [pscustomobject]@{ Errors = $errors; Warnings = $warnings }
}

# One TwinCAT test/XAE job at a time on this machine (see Run-Tests.ps1): named mutex, released when the script
# ends and taken over if the previous holder died.
$lock = New-Object System.Threading.Mutex($false, 'Global\BROT-TwinCAT-UmRT')
$locked = $false
try { $locked = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) {
    Write-Host "Another TwinCAT job is in progress, waiting up to $LockTimeoutMinutes min for it to finish..."
    try { $locked = $lock.WaitOne([TimeSpan]::FromMinutes($LockTimeoutMinutes)) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
}
if (-not $locked) { Write-Host "Another TwinCAT job still held the lock after $LockTimeoutMinutes min."; exit 4 }

$exitCode = 4
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    # Only ever clean up the XAE instance this script started, never one the user has open or opens meanwhile.
    $xaeBefore = @(Get-Process TcXaeShell -ErrorAction SilentlyContinue | ForEach-Object Id)
    $xaeOwn = @()
    $dte = $null
    try {
        $dte = New-Object -ComObject 'TcXaeShell.DTE.15.0'
        $xaeOwn = @(Get-Process TcXaeShell -ErrorAction SilentlyContinue | Where-Object { $xaeBefore -notcontains $_.Id } | ForEach-Object Id)
        # XAE is not ready right after the COM object exists: Solution stays null while it starts up
        for ($n = 0; $null -eq (Invoke-Retry { ,$dte.Solution }); $n++) {
            if ($n -ge $ReadyTimeoutSeconds) { throw "XAE did not become ready (DTE.Solution stayed null for $ReadyTimeoutSeconds s)." }
            Start-Sleep -Seconds 1
        }
        Write-Host ("XAE ready after {0} s" -f [math]::Round($watch.Elapsed.TotalSeconds))
        # (TcBuild neither sets SuppressUI nor UserControl, and passes the path with forward slashes)
        Invoke-Retry { $dte.Solution.Open($Solution.Replace('\', '/')) }

        # The project loads asynchronously after Open() returns: wait for the project and its system manager object
        # (the leading commas stop PowerShell from unrolling these enumerable COM tree items into arrays)
        # (a wall clock deadline: every Invoke-Retry inside can take long on its own while XAE is busy)
        $sysMan = $null
        $loadWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($null -eq $sysMan) {
            if ($loadWatch.Elapsed.TotalSeconds -ge $ReadyTimeoutSeconds) { throw "XAE did not load a TwinCAT project from $Solution within $ReadyTimeoutSeconds s." }
            try {
                $count = Invoke-Retry -Tries 5 { $dte.Solution.Projects.Count }
                for ($p = 1; $p -le $count -and $null -eq $sysMan; $p++) {
                    $project = Invoke-Retry -Tries 5 { $dte.Solution.Projects.Item($p) }
                    if ($Command -eq 'build' -or $project.Name -eq $XaeProject) { $sysMan = Invoke-Retry -Tries 5 { ,$project.Object } }
                }
            }
            catch [System.Management.Automation.RuntimeException] { $sysMan = $null }
            if ($null -eq $sysMan) { Start-Sleep -Seconds 1 }
        }
        Write-Host ("Project loaded after {0} s" -f [math]::Round($watch.Elapsed.TotalSeconds))

        if ($Command -eq 'build') {
            Write-Host "Building $Solution"
            $slnBuild = Invoke-Retry { $dte.Solution.SolutionBuild }
            Invoke-Retry { $slnBuild.Clean($true) }
            Start-Sleep -Seconds 1
            Invoke-Retry { $slnBuild.Build($true) }
            # vsBuildStateDone = 3
            for ($n = 0; (Invoke-Retry { [int]$slnBuild.BuildState }) -ne 3; $n++) {
                if ($n -ge 600) { throw 'The build did not finish within 10 min.' }
                Start-Sleep -Seconds 1
            }
            $failedProjects = [int](Invoke-Retry { $dte.Solution.SolutionBuild.LastBuildInfo })
            $list = Write-ErrorList $dte
            Write-Host ("Build complete -- {0} errors, {1} warnings" -f $list.Errors, $list.Warnings)
            $exitCode = if ($failedProjects -gt 0 -or $list.Errors -gt 0) { 2 } elseif ($list.Warnings -gt 0) { 1 } else { 0 }
        }
        else {
            # The PLC project node is "<plc> Project" inside the PLC project "<plc>" of the XAE project
            $plc = Invoke-Retry { ,$sysMan.LookupTreeItem("TIPC^$PlcProject^$PlcProject Project") }
            Write-Host "Checking all objects of $PlcProject"
            $ok = [bool](Invoke-Retry { $plc.CheckAllObjects() })
            $list = Write-ErrorList $dte
            Write-Host ("Compile complete -- {0} errors, {1} warnings" -f $list.Errors, $list.Warnings)
            if (-not $ok -or $list.Errors -gt 0) { $exitCode = 2 }
            else {
                Write-Host "Saving $LibraryFile$(if (-not $SkipInstall) { ' and installing it into the library repository' })"
                Invoke-Retry { $plc.SaveAsLibrary($LibraryFile, (-not $SkipInstall)) }
                $exitCode = if ($list.Warnings -gt 0) { 1 } else { 0 }
            }
        }
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
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host "::error::$Command failed: $($_.Exception.Message)"
    $exitCode = 4
}
finally { $lock.ReleaseMutex(); $lock.Dispose() }
Write-Host ("{0} exited with {1} after {2} s" -f $Command, $exitCode, [math]::Round($watch.Elapsed.TotalSeconds))
exit $exitCode
