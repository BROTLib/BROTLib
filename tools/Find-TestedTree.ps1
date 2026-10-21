<#
.SYNOPSIS
  Tells CI whether the checked-out tree has already been built and tested successfully.

.DESCRIPTION
  A merge creates a new commit, but when it brings in nothing else the tree (the file contents) is the one that
  already passed on the branch. Rebuilding it only repeats that result and holds the single runner for minutes.

  Looks through the recent successful runs of this workflow for a commit with the same tree that carries a
  `tests-passed` commit status (-Context). That status is posted only when the tests really ran (a run that
  skipped them because the license or runtime was missing is green too, and must not vouch for a later commit).
  Repos without tests post `build-passed` after a successful build and pass -Context build-passed.

  Writes `same=true` or `same=false` to $env:GITHUB_OUTPUT. Best effort: any failure means `same=false`, so the
  worst case is a normal full build.

  Never skips a workflow_dispatch run: release.yml dispatches it for the version bump and wants a real build.
#>
param(
    [string]$Repo     = $env:GITHUB_REPOSITORY,
    [string]$Sha      = $env:GITHUB_SHA,
    [string]$Workflow = 'tcbuild.yml',
    [string]$Context  = 'tests-passed',
    [int]$Limit       = 50
)
$ErrorActionPreference = 'Stop'

function Set-Same([bool]$value) {
    # (not `>>`: Windows PowerShell 5.1 would write UTF-16, which the runner cannot parse)
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "same=$($value.ToString().ToLower())`n")
}

try {
    if ($env:GITHUB_EVENT_NAME -eq 'workflow_dispatch') { Write-Host 'workflow_dispatch: full build.'; Set-Same $false; exit 0 }

    $tree = (git rev-parse "$Sha^{tree}").Trim()
    Write-Host "Tree of $Sha is $tree"

    $shas = @(gh run list --repo $Repo --workflow $Workflow --status success --limit $Limit --json headSha | ConvertFrom-Json |
        ForEach-Object { $_.headSha } | Where-Object { $_ -ne $Sha } | Select-Object -Unique)
    foreach ($candidate in $shas) {
        $candidateTree = (gh api "repos/$Repo/git/commits/$candidate" --jq .tree.sha).Trim()
        if ($candidateTree -ne $tree) { continue }
        # (filtered here, not with --jq: Windows PowerShell 5.1 strips the double quotes inside a native argument,
        # which turns `"tests-passed"` into a jq subtraction and the count into nothing)
        $passed = @(gh api "repos/$Repo/commits/$candidate/statuses" | ConvertFrom-Json |
            Where-Object { $_.context -eq $Context -and $_.state -eq 'success' }).Count
        if ($passed -gt 0) {
            Write-Host "Same tree as $candidate, which was built and tested successfully: the build and tests are skipped."
            Set-Same $true
            exit 0
        }
        Write-Host "Same tree as $candidate, but it has no successful '$Context' status (its run did not run the tests?): not a proof."
    }
    Write-Host 'No earlier successful run with this tree: full build.'
    Set-Same $false
}
catch {
    Write-Host "::warning::Same-tree check failed ($($_.Exception.Message)); doing a full build."
    Set-Same $false
}
exit 0
