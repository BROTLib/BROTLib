<#
.SYNOPSIS
    Builds a TwinCAT XAE solution via the EnvDTE Automation Interface and
    fails on any project compile error, including PLC (IEC 61131-3) errors.

.DESCRIPTION
    devenv.exe/TcXaeShell.exe's own command-line /Build, /Rebuild, /Out and
    exit code do NOT reliably reflect TwinCAT PLC compiler failures - this
    was confirmed by hand against this repo (a deliberately broken POU still
    produced exit code 0 and an empty /Out log).

    Per Beckhoff's own TC_AI_DOTNET_Samples (PlcStressTest.cs), the only
    authoritative signal is EnvDTE's SolutionBuild.LastBuildInfo (the count
    of failed project compilations) - NOT the ErrorList, which can be
    non-empty even on a successful build (e.g. warnings in unused types).

.PARAMETER SolutionPath
    Full path to the .sln file to build.

.PARAMETER Configuration
    Solution configuration name, e.g. "Release".

.PARAMETER Platform
    Solution platform name, e.g. "TwinCAT RT (x64)". Must match an entry in
    the .sln's SolutionConfigurationPlatforms section together with
    -Configuration.

.PARAMETER DteProgId
    COM ProgID for the TcXaeShell DTE. Depends on which TcXaeShell/Visual
    Studio shell version is installed on this machine - check
    HKEY_CLASSES_ROOT\TcXaeShell.DTE.* in the registry if the default here
    doesn't resolve.
#>
param(
    [Parameter(Mandatory = $true)][string]$SolutionPath,
    [Parameter(Mandatory = $true)][string]$Configuration,
    [Parameter(Mandatory = $true)][string]$Platform,
    [string]$DteProgId = "TcXaeShell.DTE.15.0"
)

$ErrorActionPreference = "Stop"
$dte = $null
$exitCode = 1

try {
    Write-Host "Creating DTE via ProgID '$DteProgId'..."
    $dte = New-Object -ComObject $DteProgId

    Write-Host "Waiting for DTE to finish initializing..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            if ($null -ne $dte.Solution) {
                $ready = $true
                break
            }
        }
        catch {
            # Not ready yet - COM calls can throw (e.g. RPC_E_CALL_REJECTED) while
            # the shell is still starting up. Keep retrying.
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        throw "DTE.Solution stayed unavailable after 60s - TcXaeShell may not have started correctly."
    }

    try { $dte.MainWindow.Visible = $false } catch { Write-Host "Could not hide MainWindow (non-fatal): $_" }

    Write-Host "Opening solution '$SolutionPath'..."
    $dte.Solution.Open($SolutionPath)

    $solutionBuild = $dte.Solution.SolutionBuild

    # TwinCAT solutions keep loading (parsing the .tsproj/.plcproj tree) in the
    # background after Solution.Open() already returned, so the configuration
    # list can come back empty/incomplete for a while. Poll until it's populated.
    Write-Host "Waiting for solution configurations to be populated..."
    $target = $null
    for ($i = 0; $i -lt 180; $i++) {
        $configs = @($solutionBuild.SolutionConfigurations)
        $named = $configs | Where-Object { $_.Name }
        if ($named.Count -gt 0) {
            foreach ($cfg in $named) {
                if ($cfg.Name -eq $Configuration -and $cfg.PlatformName -eq $Platform) {
                    $target = $cfg
                }
            }
            if ($null -ne $target) { break }
            if ($i -eq 0 -or $i % 15 -eq 0) {
                Write-Host "  (seen so far, no match yet:)"
                foreach ($cfg in $named) { Write-Host "    - $($cfg.Name) | $($cfg.PlatformName)" }
            }
        }
        Start-Sleep -Seconds 1
    }

    if ($null -eq $target) {
        Write-Host "Final solution configuration list:"
        foreach ($cfg in @($solutionBuild.SolutionConfigurations)) {
            Write-Host "  - $($cfg.Name) | $($cfg.PlatformName)"
        }
    }
    if ($null -eq $target) {
        throw "No solution configuration matching Name='$Configuration' Platform='$Platform'. See the list printed above."
    }
    $target.Activate()

    Write-Host "Building '$Configuration|$Platform'..."
    $solutionBuild.Build($true)  # $true = wait synchronously for build to finish

    $failedProjects = $solutionBuild.LastBuildInfo
    Write-Host "LastBuildInfo (failed project count): $failedProjects"

    # Diagnostic only - per Beckhoff's own sample, the ErrorList is NOT
    # authoritative for build success/failure, only useful for logging.
    $errorItems = $dte.ToolWindows.ErrorList.ErrorItems
    for ($i = 1; $i -le $errorItems.Count; $i++) {
        $item = $errorItems.Item($i)
        Write-Host "[$($item.ErrorLevel)] $($item.Description) ($($item.FileName):$($item.Line))"
    }

    $dte.Solution.Close()

    if ($failedProjects -ne 0) {
        Write-Host "Build FAILED: $failedProjects project(s) failed to compile."
        $exitCode = 1
    }
    else {
        Write-Host "Build succeeded."
        $exitCode = 0
    }
}
finally {
    if ($null -ne $dte) {
        try { $dte.Quit() } catch { }
    }
}

exit $exitCode
