<#
.SYNOPSIS
  Runs TcBuild.exe and, while it runs, samples the TcXaeShell / TcBuild processes every few seconds.

.DESCRIPTION
  TcBuild fails with exit 3 (RPC_E_SERVERCALL_RETRYLATER) when XAE does not answer within TcBuild's own COM retry
  window, and then takes its XAE down with it. A snapshot taken after that shows nothing (the XAE is already
  gone), so the samples are taken during the call: when XAE starts, how much CPU it uses, whether it responds.
  The timeline is printed only when TcBuild ends with exit 3. Always prints one line with the exit code and how
  long TcBuild took. Exits with the exit code of TcBuild, so the callers keep their retry logic.
#>
param(
    [Parameter(Mandatory)][string[]]$TcBuildArgs,
    [string]$Exe = 'C:\Program Files\Industrial Brains B.V\TcBuild\TcBuild.exe',
    [int]$IntervalSeconds = 2
)
$sampler = Start-Job -ArgumentList $IntervalSeconds -ScriptBlock {
    param($interval)
    $t0 = Get-Date
    $previous = @{}
    while ($true) {
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds)
        foreach ($p in @(Get-Process -Name TcXaeShell, TcBuild, devenv -ErrorAction SilentlyContinue)) {
            $cpu = [math]::Round($p.CPU, 1)
            $delta = if ($previous.ContainsKey($p.Id)) { [math]::Round($cpu - $previous[$p.Id], 1) } else { 0 }
            $previous[$p.Id] = $cpu
            'start+{0,3}s  {1} pid {2}: cpu {3}s (+{4}s), threads {5}, responding={6}' -f $elapsed, $p.ProcessName, $p.Id, $cpu, $delta, $p.Threads.Count, $p.Responding
        }
        Start-Sleep -Seconds $interval
    }
}
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    & $Exe @TcBuildArgs
    $code = $LASTEXITCODE
}
finally {
    Stop-Job $sampler
    $samples = @(Receive-Job $sampler)
    Remove-Job $sampler -Force
}
Write-Host ("TcBuild {0} exited with {1} after {2} s" -f $TcBuildArgs[0], $code, [math]::Round($watch.Elapsed.TotalSeconds))
if ($code -eq 3) {
    Write-Host '::group::XAE during the busy TcBuild call (sampled every 2 s)'
    if ($samples.Count -eq 0) { Write-Host 'No TcXaeShell / TcBuild / devenv process was seen.' }
    $samples | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'
}
exit $code
