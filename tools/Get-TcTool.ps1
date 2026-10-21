<#
.SYNOPSIS
  Puts the pinned tctool.exe on PATH for the following steps of the job.

.DESCRIPTION
  The version is in .github/tctool-version. The exe is downloaded from the BROTLib/TcTool release into the
  runner's tool cache once per version and checked against the published SHA-256. BROTLib/TcTool is private,
  so GH_TOKEN must be a token that can read its contents (the TCTOOL_TOKEN secret).
#>
$ErrorActionPreference = 'Stop'
$version = (Get-Content (Join-Path $env:GITHUB_WORKSPACE '.github\tctool-version') -Raw).Trim()
$dir = Join-Path $env:RUNNER_TOOL_CACHE "tctool\$version"
$exe = Join-Path $dir 'tctool.exe'

if (-not (Test-Path $exe)) {
  if (-not $env:GH_TOKEN) { throw 'GH_TOKEN is empty: the TCTOOL_TOKEN secret is not available to this workflow' }
  $tmp = Join-Path $env:RUNNER_TEMP "tctool-$version"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  gh release download "v$version" --repo BROTLib/TcTool --pattern tctool.exe --pattern tctool.exe.sha256 --dir $tmp --clobber
  if ($LASTEXITCODE -ne 0) { throw "could not download tctool v$version" }
  $expected = ((Get-Content (Join-Path $tmp 'tctool.exe.sha256') -Raw).Trim() -split '\s+')[0]
  $actual = (Get-FileHash (Join-Path $tmp 'tctool.exe') -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected) { throw "tctool.exe SHA-256 mismatch: expected $expected, got $actual" }
  New-Item -ItemType Directory -Force $dir | Out-Null
  Move-Item (Join-Path $tmp 'tctool.exe') $exe -Force
}

$dir | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
& $exe --version
