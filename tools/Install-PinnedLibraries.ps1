<#
.SYNOPSIS
    Installs the released BROT-org libraries a repo pins in its .plcproj files into the machine's TwinCAT library
    repository, replacing whatever the version slot holds.

.DESCRIPTION
    Every `<DefaultResolution>Name, 1.2.3 (Company)</DefaultResolution>` of one of the org's libraries (see $Orgs)
    with a concrete version is looked up as release v1.2.3 of the library's repo, its .library asset is downloaded and
    installed with `tctool install-library` (RepTool). A `*` (wildcard) is skipped: the test projects reference the library they test that way.

    Why: the version slot of the shared library repository is overwritten by every CI run that installs a branch of
    that library with the same ProjectVersion (a branch cut before a fix reinstalls its old code over the fixed
    release), and a `*` reference picks the highest version, so consumers compiled against whatever ran last.
    Reinstalling the pinned release right before the build makes the result independent of that. Jobs run one at a
    time on the single runner, so nothing overwrites a slot between this script and the build.

    RepTool needs 10-70 s to start (it loads the profile), so all libraries are installed in one call.

.PARAMETER Root
    Folder searched for *.plcproj files (default: the repo root, one level up from this script).
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$Owner = 'BROTLib',
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
$Root = (Resolve-Path $Root).Path

# library name as written in a reference -> repo that releases it. Names differ from the repo for MONETRoof
# ("MONET Roof" is the library title).
$Orgs = @{
    'AstroBROT'   = 'AstroBROT'
    'BROTLib'     = 'BROTLib'
    'HalfBROT'    = 'HalfBROT'
    'MONETcommon' = 'MONETcommon'
    'MONET Roof'  = 'MONETRoof'
}

# --- 1. collect the pins -----------------------------------------------------------------------------------------
$pins = @{}
Get-ChildItem $Root -Recurse -Filter *.plcproj | ForEach-Object {
    foreach ($m in [regex]::Matches((Get-Content $_.FullName -Raw), '<DefaultResolution>\s*([^,<]+?)\s*,\s*([0-9][0-9.]*)\s*\(([^)<]*)\)\s*</DefaultResolution>')) {
        $name = $m.Groups[1].Value
        if ($Orgs.ContainsKey($name)) { $pins["$($Orgs[$name])|$($m.Groups[2].Value)"] = $true }
    }
}
if ($pins.Count -eq 0) { Write-Host 'No pinned org libraries in the .plcproj files, nothing to install.'; return }

# --- 2. download the release assets ------------------------------------------------------------------------------
$dir = Join-Path $env:RUNNER_TEMP 'pinned-libraries'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory $dir | Out-Null
foreach ($key in ($pins.Keys | Sort-Object)) {
    $repo, $version = $key -split '\|'
    $target = Join-Path $dir "$repo-$version"
    Write-Host "Downloading $repo v$version"
    & gh release download "v$version" --repo "$Owner/$repo" --pattern '*.library' --dir $target
    if ($LASTEXITCODE -ne 0) { throw "No release v$version with a .library asset in $Owner/$repo (pinned in a .plcproj)." }
    if (@(Get-ChildItem $target -Filter *.library).Count -ne 1) { throw "Expected exactly one .library asset in $Owner/$repo v$version." }
}

# --- 3. install with tctool ---------------------------------------------------------------------------------------
# tctool (BROTLib/TcTool, put on PATH by tools/Get-TcTool.ps1) installs everything below $dir with RepTool in one
# call, using the profile of the installed XAE build, and takes the shared TwinCAT lock while it does.
& tctool install-library --file $dir --reptool-timeout $TimeoutSeconds
if ($LASTEXITCODE -ne 0) { throw "tctool failed installing the pinned libraries (exit code $LASTEXITCODE)." }
Write-Host "Installed $($pins.Count) pinned librar$(if ($pins.Count -eq 1) { 'y' } else { 'ies' })."
