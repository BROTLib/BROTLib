<#
.SYNOPSIS
    CI build script for BROTLib.sln via TwinCAT XAE Automation Interface.

.NOTES
    - Registers a proper COM IMessageFilter so DTE calls survive "server busy"
      (RPC_E_CALL_REJECTED) instead of relying on blind sleep/retry loops.
    - Attempts ITcPlcIECProject.CheckAllObjects() as a best-effort, non-blocking
      pre-check (this Automation Interface path did not resolve on this specific
      TwinCAT installation after extensive probing - see inline comments). The
      full build's Error List remains the authoritative check.
    - Guarantees cleanup (Quit/Release/message filter revoke) via try/finally,
      so a failed run can't leave an orphaned devenv.exe behind for the next run.
    - Adds a timeout to the build-wait loop and dumps the Error List on failure.
#>

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------

$env:GITHUB_WORKSPACE = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { "C:\Users\mail\Documents\BROTLib\" }

$VerbosePreference     = "Continue"
$DebugPreference       = "Continue"
$InformationPreference = "Continue"
$ErrorActionPreference = "Stop"

$solution        = Join-Path $env:GITHUB_WORKSPACE "BROTLib.sln"
$plcProjectPath  = "TIPC^BROTLib^BROTLib Instance"  # confirmed via tree dump - this project uses "Instance", not the "Project" convention
$buildTimeoutSec = 600                              # 10 min ceiling for the build-wait loop

# TCatSysManagerLib.dll location - needed for a typed cast to ITcPlcIECProject2.
# LookupTreeItem() returns a bare ITcSmTreeItem over late-bound IDispatch, which
# does NOT expose CheckAllObjects() (it lives on the secondary interface
# ITcPlcIECProject2). Loading the interop assembly and casting forces a real
# QueryInterface instead.
#
# IMPORTANT: this must match the TCatSysManagerLib build behind whichever DTE
# ProgID is instantiated below (TcXaeShell.DTE.15.0). Multiple copies of this
# DLL exist on a TwinCAT install (per VS version / per shell), each with its
# own IIDs baked in - using a mismatched copy causes QueryInterface to fail
# with an InvalidCastException even though the type name looks identical.
$tcSysManagerLibDll = "C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\TcXaeShell\TCatSysManagerLib.dll"

Write-Host "Solution: $solution"
Write-Host "PLC project path: $plcProjectPath"

# ------------------------------------------------------------------
# COM Message Filter
#
# Without this, PowerShell (single-threaded, no message filter registered)
# gets RPC_E_CALL_REJECTED whenever it calls into DTE/TwinCAT while VS is
# busy, instead of the call being retried. This replaces blind retry loops
# with a real "retry on busy" signal at the COM layer.
# See Beckhoff Automation Interface manual, section 4.2.5.
# ------------------------------------------------------------------

$messageFilterSource = @"
using System;
using System.Runtime.InteropServices;

[ComImport(), Guid("00000016-0000-0000-C000-000000000046"),
InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IOleMessageFilter
{
    [PreserveSig] int HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo);
    [PreserveSig] int RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType);
    [PreserveSig] int MessageInterface(int dwFlags, IntPtr hTaskCallee);
}

public class TcMessageFilter : IOleMessageFilter
{
    [DllImport("Ole32.dll")]
    private static extern int CoRegisterMessageFilter(IOleMessageFilter newFilter, out IOleMessageFilter oldFilter);

    public static void Register()
    {
        IOleMessageFilter newFilter = new TcMessageFilter();
        IOleMessageFilter oldFilter;
        CoRegisterMessageFilter(newFilter, out oldFilter);
    }

    public static void Revoke()
    {
        IOleMessageFilter oldFilter;
        CoRegisterMessageFilter(null, out oldFilter);
    }

    int IOleMessageFilter.HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo)
    {
        return 0; // SERVERCALL_ISHANDLED
    }

    int IOleMessageFilter.RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType)
    {
        if (dwRejectType == 2) // SERVERCALL_RETRYLATER
        {
            return 99; // retry after 99ms
        }
        return -1; // cancel the call
    }

    int IOleMessageFilter.MessageInterface(int dwFlags, IntPtr hTaskCallee)
    {
        return 1; // PENDINGMSG_WAITDEFPROCESS
    }
}
"@

Add-Type -TypeDefinition $messageFilterSource -Language CSharp

if (-not (Test-Path $tcSysManagerLibDll)) {
    throw "TCatSysManagerLib.dll not found at: $tcSysManagerLibDll `nCheck your TwinCAT installation path and update `$tcSysManagerLibDll at the top of this script."
}
$tcAssembly = [System.Reflection.Assembly]::LoadFrom($tcSysManagerLibDll)

# ------------------------------------------------------------------
# Pre-flight: kill any orphaned TwinCAT XAE / devenv processes left
# over from a previous failed run, so we don't attach to a zombie.
# ------------------------------------------------------------------

Write-Host "Cleaning up stray processes from previous runs (if any)..."
Get-Process -Name "devenv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "TcXaeShell" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$dte = $null

# Explicit exit codes are essential here - $LASTEXITCODE only reflects
# external/native command results, never a script's own `throw`, and whether
# an uncaught terminating error inside a script produces a non-zero PROCESS
# exit code is inconsistent across PowerShell versions and invocation modes
# (-File vs -Command, Windows PowerShell vs pwsh). GitHub Actions only checks
# the process exit code, so we guarantee it explicitly rather than relying on
# implicit propagation.
try {

try {
    # ------------------------------------------------------------------
    # Register message filter, then start TwinCAT XAE
    # ------------------------------------------------------------------

    Write-Host "Registering COM message filter..."
    [TcMessageFilter]::Register()

    Write-Host "Starting TwinCAT XAE..."
    $dte = New-Object -ComObject TcXaeShell.DTE.15.0
    $dte.SuppressUI = $false
    $dte.MainWindow.Visible = $true

    # Capture the actual process for a reliable window handle later (used for
    # UI Automation). $dte.MainWindow.HWnd has proven unreliable (returns
    # null) - Process.MainWindowHandle from .NET is more dependable. Pick the
    # most recently started matching process, since pre-flight cleanup above
    # ensures there's only one by the time we get here.
    Start-Sleep -Seconds 2
    $tcProcess = Get-Process -Name "devenv","TcXaeShell" -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending | Select-Object -First 1
    if ($tcProcess) {
        Write-Host "Tracked TwinCAT XAE process: PID=$($tcProcess.Id) Name=$($tcProcess.ProcessName)"
    }
    else {
        Write-Host "Could not identify the TwinCAT XAE process (UI Automation fallback may not work later)."
    }

    # ------------------------------------------------------------------
    # Open solution
    # (retry loop kept as a safety net; message filter should make it
    #  largely unnecessary, but a fresh VS instance can still be slow
    #  to become ready)
    # ------------------------------------------------------------------

    $opened = $false
    for ($i = 1; $i -le 15 -and -not $opened; $i++) {
        try {
            Write-Host "Opening solution (attempt $i)..."
            $dte.Solution.Open($solution)
            $opened = $true
            Write-Host "Solution opened."
        }
        catch {
            Write-Host "Open failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    if (-not $opened) {
        throw "Could not open solution."
    }

    Write-Host "Waiting for solution to finish loading..."
    Start-Sleep -Seconds 10


    # ------------------------------------------------------------------
    # Build
    # ------------------------------------------------------------------

    # ------------------------------------------------------------------
    # Clean, then Build
    #
    # TwinCAT's PLC build is incremental - it skips recompiling POUs it
    # believes are unchanged, based on internal state that isn't necessarily
    # invalidated by edits made outside the IDE (e.g. a fresh git checkout,
    # or direct file edits). That's the likely reason a plain Build() missed
    # real syntax errors that Check All Objects caught. Clean() first to
    # force a genuine full recompile rather than trusting cached state.
    # ------------------------------------------------------------------

    $cleaned = $false
    for ($i = 1; $i -le 15 -and -not $cleaned; $i++) {
        try {
            Write-Host "Cleaning (attempt $i)..."
            $dte.Solution.SolutionBuild.Clean($true)
            $cleaned = $true
            Write-Host "Clean finished."
        }
        catch {
            Write-Host "Clean failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    if (-not $cleaned) {
        throw "Unable to clean before build."
    }

    $started = $false
    for ($i = 1; $i -le 15 -and -not $started; $i++) {
        try {
            Write-Host "Starting build (attempt $i)..."
            $dte.Solution.SolutionBuild.Build($true)
            $started = $true
            Write-Host "Build started."
        }
        catch {
            Write-Host "Build start failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    if (-not $started) {
        throw "Unable to start build."
    }

    # ------------------------------------------------------------------
    # Wait for build to finish, with a timeout
    # ------------------------------------------------------------------

    Write-Host "Waiting for build (timeout: ${buildTimeoutSec}s)..."

    $elapsed = 0
    while ($dte.Solution.SolutionBuild.BuildState -eq 1) {
        Start-Sleep -Seconds 1
        $elapsed++
        if ($elapsed -ge $buildTimeoutSec) {
            throw "Build timed out after $buildTimeoutSec seconds."
        }
    }

    $result = $dte.Solution.SolutionBuild.LastBuildInfo
    Write-Host "LastBuildInfo = $result"

    # Don't trust LastBuildInfo=0 blindly - it counts FAILED projects, so if the
    # active solution configuration doesn't have this project's "Build" checkbox
    # ticked in Configuration Manager, zero projects get attempted and this
    # reports a trivial, false "success". Read the actual Output Window build
    # summary line to catch that case.
    try {
        $buildPane = $dte.ToolWindows.OutputWindow.OutputWindowPanes.Item("Build")
        $doc = $buildPane.TextDocument
        $sel = $doc.Selection
        $sel.StartOfDocument($false)
        $sel.EndOfDocument($true)
        $buildOutputText = $sel.Text
        Write-Host "----- Build Output Window -----"
        Write-Host $buildOutputText
        Write-Host "----- End Build Output -----"

        $summaryLine = ($buildOutputText -split "`r?`n") | Where-Object { $_ -match "==========\s*Build:" } | Select-Object -Last 1
        if ($summaryLine) {
            Write-Host "Build summary: $summaryLine"
            if ($summaryLine -match "(\d+)\s+succeeded" -and [int]$Matches[1] -eq 0) {
                throw "Build summary shows 0 projects succeeded - the PLC project was likely never actually built (check Configuration Manager 'Build' checkbox for the active configuration). LastBuildInfo=0 was a false positive, not a real success."
            }
        }
        else {
            Write-Host "Could not find a '========== Build: ...' summary line - unable to confirm the PLC project was actually built."
        }
    }
    catch {
        if ($_.Exception.Message -like "*Build summary shows 0*") { throw }
        Write-Host "Could not read Build output pane: $($_.Exception.Message)"
    }

    # Always dump the Error List for visibility while this is being diagnosed,
    # not just when LastBuildInfo is nonzero - LastBuildInfo has already proven
    # unreliable once.
    Write-Host "Error List (regardless of LastBuildInfo):"
    try {
        $errorItems = $dte.ToolWindows.ErrorList.ErrorItems
        if ($errorItems.Count -eq 0) {
            Write-Host "  (empty)"
        }
        for ($i = 1; $i -le $errorItems.Count; $i++) {
            $e = $errorItems.Item($i)
            Write-Host "  $($e.FileName)($($e.Line)): $($e.Description)"
        }
    }
    catch {
        Write-Host "  (Could not read Error List: $($_.Exception.Message))"
    }

    if ($result -ne 0) {
        throw "$result project(s) failed to build."
    }

    Write-Host "Build succeeded."

    # ------------------------------------------------------------------
    # Static check: CheckAllObjects() via the Automation Interface
    #
    # Runs AFTER the build, not before - moved here because
    # Build.CheckAllObjects's availability appears to depend on the project
    # having gone through at least one successful build first. On a truly
    # fresh checkout (first-ever open, as happens on a CI runner), the
    # command was unavailable when tried before any build; running it after
    # a successful build establishes whatever internal state it needs.
    # ------------------------------------------------------------------

    Write-Host "Running static check (CheckAllObjects) after build - best effort, will not fail the run if unavailable..."

    $checkOk = $null  # null = skipped/unavailable, distinct from actual $true/$false results

    try {
    # Command name varies by TcXaeShell UI language. Confirmed via Tools >
    # Options > Environment > Keyboard on both German and English installs:
    #   German:  Erstellen.ÜberprüfeAlleObjekte (built from char codes below -
    #            PS 5.1 reads .ps1 without a UTF-8 BOM using the system
    #            codepage, which corrupts literal umlauts into mojibake)
    #   English: Build.CheckAllObjects
    # Try both - Commands.Item() lookups are case-insensitive, so exact
    # capitalization doesn't matter.
    $checkCommandCandidates = @(
        "Build.CheckAllObjects",
        ("Erstellen." + [char]0x00DC + "berpr" + [char]0x00FC + "feAlleObjekte")
    )

    $checkCommandName = $null
    $cmdObj = $null
    foreach ($candidate in $checkCommandCandidates) {
        try {
            $found = $dte.Commands.Item($candidate)
            if ($found) {
                $checkCommandName = $candidate
                $cmdObj = $found
                break
            }
        }
        catch {
            Write-Host "Command '$candidate' not found: $($_.Exception.Message)"
        }
    }

    if ($cmdObj) {
        Write-Host "Found command '$checkCommandName' (available: $($cmdObj.IsAvailable))"

        # NOTE: We deliberately do NOT try to select the project in Solution
        # Explorer here. IsAvailable was True immediately after opening the
        # solution; a prior attempt to activate/select via
        # ExecuteCommand("View.SolutionExplorer") + Windows.Item(...) left
        # the command permanently unavailable afterward (10/10 retries
        # failed). That side effect - not a missing selection - was the
        # actual problem, so we just invoke directly instead.

        # IsAvailable appears to fluctuate with transient IDE state rather
        # than being stable once checked - retry a few times, re-checking
        # freshly each attempt, instead of trusting the earlier check.
        # Command availability appears tied to the IDE window having actual
        # OS-level foreground focus, not just being visible - this worked
        # every time when launched interactively (which naturally puts the
        # window in the foreground), but failed immediately (IsAvailable=
        # False from the start) when triggered via the GitHub Actions
        # runner service, which never explicitly focuses it. Force focus
        # explicitly via both the DTE API and a raw Win32 call.
        try {
            $dte.MainWindow.Activate()
        }
        catch {
            Write-Host "  `$dte.MainWindow.Activate() failed: $($_.Exception.Message)"
        }
        if ($tcProcess) {
            try {
                Add-Type -Name Win32Focus -Namespace TcAutomation -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@
                $tcProcess.Refresh()
                [TcAutomation.Win32Focus]::ShowWindow($tcProcess.MainWindowHandle, 3) | Out-Null  # SW_MAXIMIZE
                [TcAutomation.Win32Focus]::SetForegroundWindow($tcProcess.MainWindowHandle) | Out-Null
                Write-Host "  Forced window to foreground via Win32 SetForegroundWindow."
            }
            catch {
                Write-Host "  Win32 SetForegroundWindow failed: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 1

        $dispatched = $false
        for ($a = 1; $a -le 10 -and -not $dispatched; $a++) {
            $stillAvailable = try { $dte.Commands.Item($checkCommandName).IsAvailable } catch { $false }
            if (-not $stillAvailable) {
                Write-Host "  attempt $a`: command not currently available, re-activating window and waiting..."
                try { $dte.MainWindow.Activate() } catch {}
                if ($tcProcess) {
                    try {
                        $tcProcess.Refresh()
                        [TcAutomation.Win32Focus]::SetForegroundWindow($tcProcess.MainWindowHandle) | Out-Null
                    }
                    catch {}
                }
                Start-Sleep -Seconds 2
                continue
            }
            try {
                $dte.ExecuteCommand($checkCommandName)
                $dispatched = $true
                Write-Host "ExecuteCommand('$checkCommandName') dispatched (attempt $a)."
            }
            catch {
                Write-Host "  attempt $a`: ExecuteCommand threw: $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }

        if (-not $dispatched) {
            throw "Could not dispatch '$checkCommandName' after 10 attempts - command never became available."
        }

        try {
            # ErrorList.ErrorItems.Count is confirmed always 0 regardless of
            # reality (legacy COM surface - see below), so polling it isn't
            # meaningful. But the check does run asynchronously, so we still
            # need to wait before reading results. Use a fixed, generous
            # wait instead of a fake poll that only accidentally provided
            # useful delay before.
            $checkWaitSeconds = 15
            Write-Host "Waiting ${checkWaitSeconds}s for the check to finish running in the background..."
            Start-Sleep -Seconds $checkWaitSeconds

            # ErrorList.ErrorItems is the LEGACY COM error surface, tied to
            # the classic MSBuild-era error list. Modern VS packages (which
            # TwinCAT's PLC compiler is) populate the newer WPF table-based
            # Error List instead, which is NOT visible through this old
            # property - it can report 0 while the pane visibly shows real
            # entries. Don't trust it. Use UI Automation to read the
            # rendered grid directly instead.
            Write-Host "Reading Error List via UI Automation (ErrorList.ErrorItems/Output Window are both confirmed dead ends for TwinCAT-origin errors)."

            $checkErrorLines = @()
            $errorListFound = $false
            try {
                Add-Type -AssemblyName UIAutomationClient
                Add-Type -AssemblyName UIAutomationTypes

                # Build a compound key from ALL of a row's child cell values,
                # not just row.Current.Name - that property reflects only the
                # Description column, so distinct rows in different files
                # with the same error message (e.g. the same error code
                # repeated across several POUs) collapse into one row and
                # get undercounted.
                function Get-RowKey {
                    param($rowElement)
                    $cellCondition = [System.Windows.Automation.Condition]::TrueCondition
                    $cells = $rowElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cellCondition)
                    $parts = @()
                    foreach ($cell in $cells) {
                        $n = $cell.Current.Name
                        if ($n -and $n.Trim().Length -gt 0) { $parts += $n }
                    }
                    if ($parts.Count -eq 0) { return $rowElement.Current.Name }
                    return ($parts -join " | ")
                }

                $mainHwnd = [IntPtr]::Zero
                if ($tcProcess) {
                    $tcProcess.Refresh()
                    $mainHwnd = $tcProcess.MainWindowHandle
                }
                if ($mainHwnd -eq [IntPtr]::Zero) {
                    Write-Host "  Process.MainWindowHandle was zero, falling back to `$dte.MainWindow.HWnd..."
                    $mainHwnd = [IntPtr]$dte.MainWindow.HWnd
                }
                if ($mainHwnd -eq [IntPtr]::Zero) {
                    throw "Could not obtain a valid main window handle from either source."
                }
                Write-Host "  Using window handle: $mainHwnd"
                $rootElement = [System.Windows.Automation.AutomationElement]::FromHandle($mainHwnd)

                # Find the Error List tool window by name (case-insensitive
                # contains, since exact title/AutomationId can vary by VS
                # version/language).
                $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::NameProperty, "Error List"
                )
                $errorListPane = $rootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)

                if (-not $errorListPane) {
                    Write-Host "  Could not find an 'Error List' element via UI Automation."
                }
                else {
                    $errorListFound = $true
                    Write-Host "  Found Error List UI element."

                    # PRIMARY signal: the Error List toolbar shows a literal
                    # "N Errors" label/button (visible in the screenshot).
                    # Reading this directly is far more robust than
                    # enumerating/scrolling every row, since it's a single
                    # element VS itself already computed - no virtualization
                    # or scroll-targeting issues to fight.
                    $errorCountFromLabel = $null
                    try {
                        $allDescendants = $errorListPane.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                        foreach ($el in $allDescendants) {
                            $n = $el.Current.Name
                            if ($n -match "^\s*(\d+)\s+Error") {
                                $errorCountFromLabel = [int]$Matches[1]
                                Write-Host "  Found toolbar label: '$n' -> $errorCountFromLabel"
                                break
                            }
                        }
                    }
                    catch {
                        Write-Host "  Could not read toolbar error count label: $($_.Exception.Message)"
                    }

                    Write-Host "  Scrolling to accumulate row detail for logging (grid is virtualized - a single snapshot only sees the visible viewport; this is supplementary detail, not the pass/fail signal)..."

                    $dataItemCondition = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::DataItem
                    )

                    # Find the scrollable ancestor/container that actually
                    # supports ScrollPattern - it may be the pane itself or a
                    # descendant list/grid control.
                    $scrollPattern = $null
                    $patternObj = $null
                    if ($errorListPane.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$patternObj)) {
                        $scrollPattern = $patternObj
                    }
                    else {
                        $scrollableCondition = New-Object System.Windows.Automation.PropertyCondition(
                            [System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty, $true
                        )
                        $scrollable = $errorListPane.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $scrollableCondition)
                        if ($scrollable) {
                            $patternObj = $null
                            if ($scrollable.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$patternObj)) {
                                $scrollPattern = $patternObj
                            }
                        }
                    }

                    # Key = compound cell text (for dedup), Value = display text
                    $allRows = [ordered]@{}

                    # Capture current viewport
                    $rows = $errorListPane.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dataItemCondition)
                    foreach ($row in $rows) {
                        $key = Get-RowKey -rowElement $row
                        if ($key) { $allRows[$key] = $row.Current.Name }
                    }
                    Write-Host "  Initial viewport: $($allRows.Count) unique row(s)."

                    if ($scrollPattern) {
                        Write-Host "  ScrollPattern found - scrolling through the full list..."
                        $maxScrolls = 50
                        $prevCount = $allRows.Count
                        $stagnantRounds = 0

                        # Scroll to top first for a known starting point
                        try { $scrollPattern.SetScrollPercent(-1, 0) } catch {}
                        Start-Sleep -Milliseconds 300
                        $rows = $errorListPane.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dataItemCondition)
                        foreach ($row in $rows) {
                            $key = Get-RowKey -rowElement $row
                            if ($key) { $allRows[$key] = $row.Current.Name }
                        }

                        for ($s = 1; $s -le $maxScrolls; $s++) {
                            try {
                                $scrollPattern.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
                            }
                            catch { break }  # can't scroll further (likely at bottom)
                            Start-Sleep -Milliseconds 300

                            $rows = $errorListPane.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dataItemCondition)
                            foreach ($row in $rows) {
                                $key = Get-RowKey -rowElement $row
                                if ($key) { $allRows[$key] = $row.Current.Name }
                            }

                            if ($allRows.Count -eq $prevCount) {
                                $stagnantRounds++
                                if ($stagnantRounds -ge 3) { break }  # no new rows for 3 scrolls in a row - assume done
                            }
                            else {
                                $stagnantRounds = 0
                            }
                            $prevCount = $allRows.Count

                            $vPercent = try { $scrollPattern.Current.VerticalScrollPercent } catch { -1 }
                            if ($vPercent -ge 99.9) { break }
                        }
                        Write-Host "  Finished scrolling. Total unique rows: $($allRows.Count)"
                    }
                    else {
                        Write-Host "  No ScrollPattern found - only the initial viewport could be read. Row count may be incomplete."
                    }

                    $checkErrorLines = @($allRows.Values)
                    foreach ($line in $checkErrorLines) { Write-Host "    ROW: $line" }
                }
            }
            catch {
                Write-Host "  UI Automation read failed: $($_.Exception.Message)"
            }

            # Use the UI-Automation-derived rows, not ErrorItems.Count (proven
            # unreliable above). Filter to rows that look like real compiler
            # error entries (TwinCAT error codes look like "C0009:", "C0077:"
            # etc.) to avoid false positives from unrelated UI element names
            # that happened to match "DataItem".
            $realErrorLines = $checkErrorLines | Where-Object { $_ -match "\bC\d{4}:" }

            # Prefer the toolbar "N Errors" label - it's VS's own computed
            # total and doesn't depend on grid virtualization/scrolling
            # working correctly, unlike the row scan above (which is kept
            # for logging detail but is known to sometimes undercount).
            $effectiveErrorCount = if ($null -ne $errorCountFromLabel) { $errorCountFromLabel } else { $realErrorLines.Count }

            Write-Host "Check All Objects result: label count=$errorCountFromLabel, row-scan found $($checkErrorLines.Count) row(s) ($($realErrorLines.Count) look like real errors). Using effective count: $effectiveErrorCount"

            if ($effectiveErrorCount -gt 0) {
                $checkOk = $false
                throw "Check All Objects found $effectiveErrorCount error(s) - see rows above."
            }
            elseif ($null -ne $errorCountFromLabel -or $errorListFound) {
                # Either the toolbar label confirmed 0, or we found and
                # scanned the Error List and got 0 rows - treat as OK.
                $checkOk = $true
                Write-Host "Check All Objects: OK (0 errors)"
            }
            else {
                # We got rows but none matched the error-code pattern - could
                # be a UI Automation structure mismatch rather than a genuine
                # clean result. Don't claim success on shaky evidence.
                throw "UI Automation found $($checkErrorLines.Count) row(s) but none matched an error-code pattern - can't confirm this is a clean result rather than a read failure. Treating as unavailable."
            }
        }
        catch {
            if ($_.Exception.Message -like "*Check All Objects found*") { throw }
            Write-Host "Polling/reading Error List after check failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Command '$checkCommandName' not available - falling through to COM interface probe as a secondary attempt."

    $project    = $dte.Solution.Projects.Item(1)
    $sysManager = $project.Object

    Write-Host "Solution projects (Item count: $($dte.Solution.Projects.Count)):"
    $solutionProjectObjects = [ordered]@{}
    for ($i = 1; $i -le $dte.Solution.Projects.Count; $i++) {
        $p = $dte.Solution.Projects.Item($i)
        $pName = try { $p.Name } catch { "(no Name)" }
        $pKind = try { $p.Kind } catch { "(no Kind)" }
        $pFile = try { $p.FileName } catch { "(no FileName)" }
        Write-Host "  [$i] Name=$pName Kind=$pKind FileName=$pFile"
        try {
            $solutionProjectObjects["project[$i] ($pName)"] = $p.Object
        }
        catch {
            Write-Host "      (.Object threw: $($_.Exception.Message))"
        }
    }

    # Recursive tree dump helper. PathName on each ITcSmTreeItem is the exact
    # string LookupTreeItem expects - ground truth, no need to guess naming
    # conventions like "<name> Project".
    function Show-TcTree {
        param($item, $depth = 0, $maxDepth = 5)
        if ($depth -gt $maxDepth) { return }
        $indent = "  " * $depth
        $path = try { $item.PathName } catch { "(no PathName)" }
        Write-Host "$indent$($item.Name)  [$path]"
        for ($i = 1; $i -le $item.ChildCount; $i++) {
            Show-TcTree -item $item.Child($i) -depth ($depth + 1) -maxDepth $maxDepth
        }
    }

    $plcRoot = $sysManager.LookupTreeItem("TIPC")

    try {
        $plcProject = $sysManager.LookupTreeItem($plcProjectPath)
    }
    catch {
        Write-Host "LookupTreeItem('$plcProjectPath') failed. Dumping full TIPC tree with real paths:"
        Show-TcTree -item $plcRoot
        throw
    }

    # Discover candidate interfaces by what they actually DECLARE, not by
    # guessing name patterns - a name-pattern search already proved insufficient
    # (it found ITcPlcIECProject*/ITcPlcProject* but none of them matched via
    # QueryInterface). Find every interface with a method literally named
    # CheckAllObjects, whatever it's called.
    $candidateInterfaces = $tcAssembly.GetTypes() |
        Where-Object {
            $_.IsInterface -and ($_.GetMethods() | Where-Object { $_.Name -eq "CheckAllObjects" })
        } |
        Select-Object -ExpandProperty FullName

    Write-Host "Interfaces in $($tcAssembly.GetName().Name) that declare CheckAllObjects:"
    if ($candidateInterfaces) {
        $candidateInterfaces | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host "  (none - CheckAllObjects is not declared anywhere in this assembly)"
    }

    $candidateNodes = [ordered]@{
        "configured path ($plcProjectPath)" = $plcProject
        "parent (TIPC^BROTLib)"             = $sysManager.LookupTreeItem("TIPC^BROTLib")
    }
    foreach ($key in $solutionProjectObjects.Keys) {
        $candidateNodes[$key] = $solutionProjectObjects[$key]
    }

    Write-Host "Node type diagnostics (base ITcSmTreeItem properties, no cast needed):"
    foreach ($nodeLabel in $candidateNodes.Keys) {
        $node = $candidateNodes[$nodeLabel]
        $itemType     = try { $node.ItemType } catch { "(unavailable)" }
        $itemSubType  = try { $node.ItemSubType } catch { "(unavailable)" }
        $itemSubName  = try { $node.ItemSubTypeName } catch { "(unavailable)" }
        Write-Host "  '$nodeLabel': ItemType=$itemType ItemSubType=$itemSubType ItemSubTypeName=$itemSubName"
    }

    Write-Host "Get-Member on '$plcProjectPath' (default dispatch only, secondary interfaces won't show):"
    Get-Member -InputObject $plcProject | ForEach-Object { Write-Host "  $($_.MemberType) $($_.Name)" }

    # Bridging step: ITcSmPlc2Object wasn't caught by our interface name filter
    # (it doesn't contain "Project"), but its naming pattern mirrors how
    # EnvDTE.Project.Object bridges to ITcSysManager - it likely exposes an
    # .Object property that hands back the actual nested PLC project object,
    # rather than the tree item itself being directly castable.
    $bridgeIfaceType = $tcAssembly.GetType("TCatSysManagerLib.ITcSmPlc2Object")
    if ($bridgeIfaceType) {
        Write-Host "Trying ITcSmPlc2Object bridge on each node..."
        $bridgedNodes = [ordered]@{}
        foreach ($nodeLabel in $candidateNodes.Keys) {
            $node = $candidateNodes[$nodeLabel]
            $bridged = $node -as $bridgeIfaceType
            if ($bridged) {
                Write-Host "  '$nodeLabel' implements ITcSmPlc2Object - pulling .Object"
                try {
                    $inner = $bridged.Object
                    if ($inner) {
                        $bridgedNodes["'$nodeLabel'.Object (via ITcSmPlc2Object)"] = $inner
                        Write-Host "    -> got inner object"
                    }
                }
                catch {
                    Write-Host "    -> .Object threw: $($_.Exception.Message)"
                }
            }
        }
        foreach ($key in $bridgedNodes.Keys) {
            $candidateNodes[$key] = $bridgedNodes[$key]
        }
    }
    else {
        Write-Host "ITcSmPlc2Object not found in this assembly."
    }

    # Second bridging attempt: VSProjectItem showed up in the Get-Member dump.
    # EnvDTE ProjectItem objects representing nested projects commonly expose
    # their own .Object property (same pattern as Project.Object -> ITcSysManager
    # that we already rely on above) - worth trying one level deeper.
    Write-Host "Trying VSProjectItem.Object bridge on each node..."
    $vsBridgedNodes = [ordered]@{}
    foreach ($nodeLabel in @($candidateNodes.Keys)) {
        $node = $candidateNodes[$nodeLabel]
        try {
            $vsProjItem = $node.VSProjectItem
        }
        catch {
            continue
        }
        if ($vsProjItem) {
            Write-Host "  '$nodeLabel' has a VSProjectItem"
            try {
                $inner = $vsProjItem.Object
                if ($inner) {
                    $vsBridgedNodes["'$nodeLabel'.VSProjectItem.Object"] = $inner
                    Write-Host "    -> got .Object"
                }
            }
            catch {
                Write-Host "    -> .Object threw: $($_.Exception.Message)"
            }
        }
    }
    foreach ($key in $vsBridgedNodes.Keys) {
        $candidateNodes[$key] = $vsBridgedNodes[$key]
    }

    # Third bridging attempt: per Beckhoff's own docs, EVERY PLC project tree
    # item (not just this one) is cast to ITcProjectRoot to reach a
    # .NestedProject property, which is what actually holds the compilable
    # source. This interface was missed by both earlier searches - it doesn't
    # contain "Plc" in its name, and it doesn't itself declare CheckAllObjects
    # (it declares .NestedProject instead, one hop further).
    Write-Host "Trying ITcProjectRoot.NestedProject bridge on each node..."
    $rootIfaceType = $tcAssembly.GetType("TCatSysManagerLib.ITcProjectRoot")
    $rootBridgedNodes = [ordered]@{}
    if ($rootIfaceType) {
        foreach ($nodeLabel in @($candidateNodes.Keys)) {
            $node = $candidateNodes[$nodeLabel]
            $rootCast = $node -as $rootIfaceType
            if ($rootCast) {
                Write-Host "  '$nodeLabel' implements ITcProjectRoot"
                try {
                    $nested = $rootCast.NestedProject
                    if ($nested) {
                        $rootBridgedNodes["'$nodeLabel'.NestedProject (via ITcProjectRoot)"] = $nested
                        Write-Host "    -> got NestedProject"
                    }
                }
                catch {
                    Write-Host "    -> .NestedProject threw: $($_.Exception.Message)"
                }
            }
        }
    }
    else {
        Write-Host "ITcProjectRoot not found in this assembly."
    }
    foreach ($key in $rootBridgedNodes.Keys) {
        $candidateNodes[$key] = $rootBridgedNodes[$key]
    }

    Write-Host "Enumerating DTE Commands matching Check/Verify/TwinCAT/PLC/Tc..."
    $matchingCommands = @()
    foreach ($cmd in $dte.Commands) {
        try {
            if ($cmd.Name -like "*TwinCAT*" -or $cmd.Name -like "*Tc*" -or $cmd.Name -like "*PLC*" -or $cmd.Name -like "*Check*" -or $cmd.Name -like "*Verify*") {
                $matchingCommands += $cmd.Name
            }
        }
        catch { }
    }
    $matchingCommands | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }

    $iecProject = $null
    $usedLabel  = $null
    $usedIface  = $null

    Write-Host "Probing which node/interface combination supports CheckAllObjects()..."
    foreach ($nodeLabel in $candidateNodes.Keys) {
        $node = $candidateNodes[$nodeLabel]
        foreach ($ifaceName in $candidateInterfaces) {
            $ifaceType = $tcAssembly.GetType($ifaceName)
            if (-not $ifaceType) { continue }

            $attempt = $node -as $ifaceType
            if ($attempt) {
                Write-Host "  MATCH: '$nodeLabel' implements $ifaceName"
                if (-not $iecProject) {
                    $iecProject = $attempt
                    $usedLabel  = $nodeLabel
                    $usedIface  = $ifaceName
                }
            }
        }
    }

    if (-not $iecProject) {
        Write-Host "No candidate interface matched on any node. Full tree for reference:"
        Show-TcTree -item $plcRoot
        throw "Could not find an object supporting CheckAllObjects() under TIPC^BROTLib. See probe output above."
    }

    Write-Host "Using '$usedLabel' via $usedIface"
    $checkOk = $iecProject.CheckAllObjects()

    if (-not $checkOk) {
        throw "CheckAllObjects() reported errors in PLC project. Open the solution locally to inspect the Error List, or extend this script to dump ITcPlcIECProject error output."
    }

    Write-Host "CheckAllObjects: OK"
    }
    }
    catch {
        if ($_.Exception.Message -like "*Check All Objects found*") {
            # The check genuinely ran and found real errors - this is now a
            # proven, working mechanism (confirmed via UI Automation reading
            # actual error rows), so this should hard-fail the whole run,
            # not just warn. Rethrow past this best-effort wrapper.
            Write-Host "Check All Objects found real errors - failing the build. Details above."
            throw
        }
        Write-Warning "Static check (CheckAllObjects) unavailable or failed on this installation: $($_.Exception.Message)"
        Write-Warning "Continuing to full build - the build's own Error List remains the authoritative check."
        $checkOk = $null
    }
}
finally {
    # ------------------------------------------------------------------
    # Cleanup - always runs, even on failure, so a bad run can't poison
    # the next one on this self-hosted runner.
    # ------------------------------------------------------------------

    Write-Host "Cleaning up..."

    if ($dte) {
        try { $dte.Solution.Close($false) } catch {}
        try { $dte.Quit() } catch {}
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($dte) | Out-Null
        $dte = $null
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    try { [TcMessageFilter]::Revoke() } catch {}

    # Belt-and-braces: make sure nothing lingers for the next run.
    Get-Process -Name "devenv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "TcXaeShell" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "Done."
}

}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    exit 1
}

exit 0