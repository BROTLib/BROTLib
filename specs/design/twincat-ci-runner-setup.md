# Setting up a TwinCAT self-hosted CI runner from scratch

Step-by-step, distilled from the investigation in
[2026-09-15-twincat-ci-investigation.md](../plans/2026-09-15-twincat-ci-investigation.md)
(read that for the *why* and the false starts). Written so that standing up a **dedicated,
isolated VM** for this — instead of reusing a live telescope engineering PC — is a quick,
mechanical process next time. (Repos: BROTLib, AstroBROT, IAG50cm, MONETcommon, HalfBROT,
MONETRoof, and any future custom TwinCAT library/telescope repo in the `brotlib` org.)

## Prerequisites

- Windows, with **TwinCAT XAE Shell already installed** (standalone engineering shell, not full
  Visual Studio) — matching the fleet's target build. Check with the one-liner in
  [checking-twincat-xae-version.md](../steering/checking-twincat-xae-version.md);
  fleet target as of 2026-09-16 is TwinCAT 3.1 Build 4024 / XAE Shell 1.17.0.0. TcBuild's compile-
  only use doesn't appear to need a runtime license (you're never deploying to hardware from this
  machine).

## 1. Dev tooling

```powershell
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
```

Both `Git.Git` and the elevated MSI step below (§3) trigger a UAC prompt — an AI agent's own
auto-mode classifier will refuse to click through this, so it needs a human at the keyboard for
just those two steps, even if everything else is scripted.

**Gotcha:** a fresh PowerShell/tool-call process does not pick up a PATH change from an install
done in a *different* process, even in the "same" session — each call reads a possibly-stale
cached environment. Refresh explicitly before relying on a just-installed CLI tool:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

Set git identity once:

```powershell
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
```

## 2. GitHub auth

```powershell
gh auth login --hostname github.com --git-protocol https --web
```

Prints a one-time code + `https://github.com/login/device` — needs a human to complete in a
browser (device-code flow, not scriptable end-to-end). Then add the scopes needed later:

```powershell
gh auth refresh -h github.com -s workflow    # to push .github/workflows/*.yml
gh auth refresh -h github.com -s admin:org   # to register an ORG-level runner (see §4)
```

Both are separate device-code prompts too. `admin:org` is a significant scope — an AI agent's
auto-mode classifier will refuse to even initiate that refresh; only a human can request it.

## 3. TcBuild

MSI lives in the [`JustusRijke/TcBuild`](https://github.com/JustusRijke/TcBuild) repo's own tree,
**not** published via GitHub Releases or NuGet — `dotnet tool install --global TcBuild` grabs an
unrelated same-named package and fails confusingly. Don't use it.

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/JustusRijke/TcBuild/main/TcBuildInstaller/Release/TcBuild_Installer.msi" -OutFile "$env:TEMP\TcBuild_Installer.msi"
Get-FileHash "$env:TEMP\TcBuild_Installer.msi" -Algorithm SHA256   # sanity-check before running
Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\TcBuild_Installer.msi`" /qn" -Verb RunAs -Wait
```

Silent install (`/qn`) gives **zero visible feedback even on success** — don't mistake that for a
no-op. Installs to `C:\Program Files\Industrial Brains B.V\TcBuild\TcBuild.exe`. This step needs
elevation (UAC prompt) — see the human-required note in §1.

## 4. Register the runner — org-level, not per-repo

An **org-level** runner (registered once against the whole `brotlib` org) is available to every
repo automatically — no per-repo token dance, no per-repo runner process. Needs the `admin:org`
scope from §2. (A repo-level runner is simpler to reason about for a single quick test, but don't
bother multiplying it across repos — we did that once, six separate runners, then tore all six
down and replaced them with one org-level runner within the same day. Just start org-level.)

```powershell
$dir = "C:\actions-runner-brotlib-org"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Location $dir
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip" -OutFile actions-runner.zip
# Verify against the SHA256 GitHub publishes in the release's own body text before trusting it.
Expand-Archive -Path actions-runner.zip -DestinationPath . -Force

$token = gh api -X POST orgs/brotlib/actions/runners/registration-token --jq .token
.\config.cmd --url https://github.com/brotlib --token $token --name <machine-name>-org --labels self-hosted,twincat,windows --runasservice --windowslogonaccount <windows-account-name>
```

Minting the registration token is a "credential materialization" action — an AI agent's auto-mode
classifier refuses this one too; a human runs it (or hands the printed token over).

**Gotcha:** `--runasservice --windowslogonaccount ... --unattended` together fails outright
("Invalid configuration provided for windowslogonpassword") — `--unattended` forbids the
interactive password prompt but doesn't accept the password any other way here. Drop
`--unattended` so `config.cmd` prompts for it interactively instead.

**Run the service under a real Windows user account, not `LocalSystem`/`NETWORK SERVICE`.**
Confirmed 2026-09-16: TcBuild's COM automation against XAE works fine under a service account,
*and* doesn't actually need an interactive desktop session at all — once (see next section) the
underlying stale-library-state problem was fixed. Earlier testing that seemed to show service mode
uniquely broken was actually this unrelated cause, not a real service-vs-interactive difference.

## 5. Prime the library store

Before building anything that depends on another custom library, install the dependencies first —
`TcBuild build` does **not** install library dependencies as a side effect:

```powershell
TcBuild install SomeLibrary.sln -x <XAE-project-name> -p <PLC-project-name> -l SomeLibrary.library
```

`-x`/`-p` want the actual project names from inside the `.sln`/`.tsproj` (`Project("...") = "Name"`
in the `.sln`, the PLC project's `Name=` attribute in the `.tsproj`) — these don't always match the
repo or solution filename (e.g. MONETRoof's XAE project is `MONETroof`, its PLC project is
`MonetRoof`, case differing from both the repo name and the `.sln` filename).

This **does** persist into this machine's shared TwinCAT library store
(`C:\TwinCAT\3.1\Components\Plc\Managed Libraries\...`) — same store XAE itself reads from. That's
fine and expected on a dedicated build-only VM (nothing else competes for that state); it was the
actual concern that motivated moving off a live engineering PC in the first place. Multiple
versions coexist side-by-side without conflict (a project only resolves whatever exact version its
`.plcproj` pins) — no cleanup needed after an `install`.

## 6. Add a build workflow per repo

```yaml
name: TcBuild test

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: [self-hosted, twincat, windows]
    steps:
      - uses: actions/checkout@v4
      - name: Build
        shell: powershell
        run: |
          & "C:\Program Files\Industrial Brains B.V\TcBuild\TcBuild.exe" build SomeSolution.sln
```

`workflow_dispatch` only — **not** `push`/`pull_request`. A prior attempt auto-triggered on every
push/PR to a public repo, exposing the runner to PR-triggered execution from anyone; removed once
found. `shell: powershell`, not `pwsh` — a fresh machine may only have Windows PowerShell 5.1.

**The real gotcha that cost the most time:** if a project's `.plcproj` has a stale visualization
profile (wrong/mismatched TwinCAT build embedded — see
[checking-twincat-xae-version.md](../steering/checking-twincat-xae-version.md) for
how to check what's actually installed), the *first* build on a machine writes the correct value —
but `actions/checkout`'s default `clean: true` wipes that fix on every subsequent run, making it
look like a permanent, unfixable, mode-dependent (service vs. interactive) failure. **The real fix
is committing the corrected `.plcproj` to the repo**, not touching checkout behavior. Set it
properly via XAE's own **Project Properties → Compile → Visualization Profile** (reliable) rather
than hoping a CLI retry resolves it (worked sometimes, not reliably). While in there: TwinCAT
refuses to save a project flagged `Released: true` at all, so fixing anything on a released project
flips that flag to `false` as a necessary side effect — that's an honest reflection of "this was
modified since release," not a bug to force back to `true`.

## Known TcBuild flakiness (retry, don't debug)

- `RPC_E_SERVERCALL_RETRYLATER` (exit 3, "message filter indicated application is busy") — cold-
  start COM flakiness, especially the very first build after install or after an idle period.
  Retry once or twice.
- Exit code 1 with no `E:` diagnostics, just warnings — check for a stray `TcXaeShell.exe`/`devenv`
  process left over from unrelated earlier activity (`Get-Process TcXaeShell,devenv`); kill it and
  retry. TcBuild spawns its own XAE instance per build and doesn't reuse/conflict with an
  already-open interactive session, but an *orphaned* one from a previous build does interfere.
- Killing a stray `Runner.Listener` process (e.g. to restart with a refreshed PATH) leaves an
  orphaned session server-side — "A session for this runner already exists" on the next start.
  Self-heals via the listener's own 30s-backoff retry within ~1-2 minutes; no action needed.

## Still open, not part of this setup guide

Full XAE **telescope** solutions (with I/O/target config, not pure PLC libraries — e.g. IAG50cm,
MONETS) hit a different, unresolved wall: exit 1, warnings only, nothing written to disk, immune
to retries. Every pure library solution builds cleanly. Not yet root-caused — see the investigation
doc's open items.
