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

## tctool: builds, library installs and TcUnit runs (since 2026-10-22)

CI no longer uses `TcBuild.exe` or the per-repo scripts `Invoke-XaeBuild.ps1`, `Run-Tests.ps1` and
`Install-TcUnit.ps1`. All of it is [`tctool.exe`](https://github.com/BROTLib/TcTool) (C#, .NET Framework 4.8): one
executable that drives XAE through its automation interface, with a deadline on every phase. Design and CLI:
the TcTool repo. This section is what the runner needs.

- **Nothing to install.** Each repo pins a version in `.github/tctool-version`; the step `Get tctool` runs
  `tools/Get-TcTool.ps1`, which downloads that release of `BROTLib/TcTool` (checks the SHA-256) into the runner's tool
  cache once per version and puts it on `PATH` for the following steps. Roll back by changing the version in that file.
- **Access token.** `BROTLib/TcTool` is private, so the download needs the org secret **`TCTOOL_TOKEN`**: a fine-grained
  personal access token with *Contents: read* on `BROTLib/TcTool` only. Org settings > Secrets and variables > Actions >
  `TCTOOL_TOKEN` > *Repository access* lists the repos that may use it; add a repo there before it switches. The token
  has an expiry date: when it passes, every TwinCAT job fails at `Get tctool` ("GH_TOKEN is empty" or a 404).
- **XAE.** Still needed (XAE 4024, TcXaeShell). `tctool` takes the machine-wide mutex `Global\BROT-TwinCAT-UmRT` for the
  whole invocation, so only one TwinCAT job runs at a time, like the old scripts. It starts its own XAE, puts it into a
  job object (it dies with `tctool`) and quits it afterwards; it never touches another `TcXaeShell`.

What the workflows call:

| Call | Replaces |
|---|---|
| `tctool X.sln build` | `Invoke-XaeBuild.ps1 build`, `TcBuild build` |
| `tctool X.sln library --xae <XAE project> --plc <PLC project> --out <file> --install` | `Invoke-XaeBuild.ps1 install`, `TcBuild install ... -l` |
| `tctool install-library --file <dir or .library>` | the RepTool call in `Install-PinnedLibraries.ps1` |
| `tctool install-library --via xae --file <lib>` (after `X.sln`) | `Install-TcUnit.ps1` (not used in CI yet) |
| `tctool X.sln build run --require-license TC1200,TF6701 --skip-if-unavailable` | the license and runtime check steps, the tests build and `Run-Tests.ps1` |
| `tctool check --license <list> --runtime` | the inline license/runtime check steps, by hand or as a step of its own |

`run` checks the license (all `*.tclrs` of the user-mode runtime: not expired, order numbers present; or just not
expired with `--require-valid-license`) and the `TcSystemServiceUm` process **before** it starts XAE or touches the
runtime. If one is missing it returns 13: the build before it is still checked, the job stays green with a warning, and the
workflow sets `ran=false` so no `tests-passed` status is posted. A license with less than 48 h left is a warning (exit 1).
`run` deploys the boot project to the user-mode runtime (`192.168.4.1.1.1` or `127.0.0.1.1.1`; another target needs
`--allow-remote-target`), quits XAE, then waits for TcUnit over ADS and reads the counters. The name of the PLC project
is the XAE/PLC name from the `.sln`/`.tsproj`, not the repo name (`MONETRoof`: `MONETroof` / `MonetRoof`); `--xae` and
`--plc` default to the only project, and a wrong name is answered with the list of the existing ones.

Exit codes (0 and 1 are successes; the workflows treat 13 as success with a warning):

| Code | Meaning |
|---|---|
| 0 / 1 | all steps ok / ok with compile warnings or an expiring license |
| 2 | compile errors (`build`, `library`) |
| 4 | other error: XAE did not start, project did not load, COM error, RepTool failed |
| 5 | bad arguments or a missing file |
| 10 | `run`: a TcUnit test case failed, or 0 cases ran |
| 11 | a deadline expired (XAE ready, project load, `--deadline`, TcUnit); XAE is killed and its windows are logged |
| 12 | another TwinCAT job held the lock for `--lock-timeout` |
| 13 | `run`/`check`: license or runtime missing |
| 14 | `run`: TwinCAT stayed in Config after the restart (usually a license the boot project needs, e.g. TF6701) |

Exit code 3 of TcBuild ("COM busy") is never returned: `tctool` retries rejected COM calls itself for `--call-timeout`
(60 s) and starts XAE only once per solution, so a cold XAE start (about 20 s of CPU) no longer fails.

Testing `tctool` itself on the runner: the TcTool repo has the workflow `integration`
(`gh workflow run integration.yml --repo BROTLib/TcTool`, `workflow_dispatch` only, never on pull requests). It uses the
same `twincat-tests` concurrency group idea as the CI, installs a few throwaway libraries (`TcToolIntegrationLib`,
`TcToolSlotA/B/C`, no uninstall) into the library repository of the runner, and kills XAE processes of its own session
only. The script `Check-LibrarySlots.ps1` showed that RepTool, `SaveAsLibrary(..., install)` and `InstallLibrary('System')`
all write to `Managed Libraries\<Company>\<Name>\<Version>`.

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

## 3. TcBuild (superseded by tctool, not needed on a new runner)

> Since 2026-10-22 nothing in the org's workflows calls `TcBuild.exe` any more (see the tctool section above). The
> installation below is kept for the history; a new runner does not need it. It also still has the reason for the
> switch: on a cold XAE start TcBuild gave up after about 17 s with exit 3.

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
name: TcBuild   # saved as .github/workflows/tcbuild.yml

on:
  push:
    branches: ['**']
    tags-ignore: ['**']
  workflow_dispatch:

jobs:
  build:
    runs-on: [self-hosted, twincat, windows]
    steps:
      - uses: actions/checkout@v4
      - name: Get tctool
        shell: powershell
        env:
          GH_TOKEN: ${{ secrets.TCTOOL_TOKEN }}
        run: .\tools\Get-TcTool.ps1
      - name: Build
        shell: powershell
        run: |
          tctool SomeSolution.sln build
          if ($LASTEXITCODE -gt 1) { exit $LASTEXITCODE }   # 1 = built with compile warnings: a success
          exit 0
```

`push` and `workflow_dispatch` — **not** `pull_request`. A prior attempt auto-triggered on every
push/PR to a public repo, exposing the runner to PR-triggered execution from anyone; removed once
found. Since 2026-10-06 `push` (all branches, no tags) is back on purpose: a push needs write access,
fork PRs cannot trigger it. This is the CI that is live now: the repos build on every push, and a green run
is the compile check. It does not run TcUnit tests (needs a runtime and a license, see below). The real
workflow also has a `concurrency` group that cancels a superseded run and the exit-code handling from the last
section; copy `tcbuild.yml` from another repo of the org rather than the sketch above. Never add
`pull_request`/`pull_request_target`. `shell: powershell`, not
`pwsh` — a fresh machine may only have Windows PowerShell 5.1.

**BROTLib, AstroBROT and MONETcommon also have `tests.yml`:** it runs on every push to any branch (installs the
library, which compiles it, then builds and runs the tests, see below) next to `tcbuild.yml`, which also runs on
every push, so the check name `build` exists in every repo. A tag trigger would not work for the release build:
`tag-release.yml` pushes tags with `GITHUB_TOKEN`, and events caused by that token do not start workflows.
(Until 2026-10-07 these three ran `tcbuild.yml` only on pushes to `main`.)

### Running the tests (BROTLib)

`tests.yml` needs a TwinCAT runtime that executes the PLC, which on Windows 11 is the beta user-mode runtime
(`C:\TwinCAT\3.1\Runtimes\UmRT_Default`; the 4024 real-time runtime does not run there). Per machine:

1. `BROTLibTests\tools\Install-TcUnit.ps1` (installs the vendored TcUnit into the library repository).
2. A scheduled task that starts the runtime at boot — needs an **elevated** PowerShell, once:
   ```powershell
   $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c Start.bat' -WorkingDirectory 'C:\TwinCAT\3.1\Runtimes\UmRT_Default'
   $t = New-ScheduledTaskTrigger -AtStartup
   $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -Hidden
   $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
   Register-ScheduledTask -TaskName 'TwinCAT UmRT_Default' -Action $a -Trigger $t -Settings $s -Principal $p -Force
   ```
3. A license for the PLC (TC1200), plus TF6701 (TC3 IoT Communication, MQTT) for `BROTLibTests`, whose MQTT handler
   tests instantiate the `Tc3_IotBase` client. A license is needed only when the boot project instantiates a block
   that carries one; the compiled `.tmc` lists it under `<Licenses>`. Until permanent ones are bought this is the
   7-day trial from XAE > SYSTEM > License > Manage Licenses, renewed by hand (captcha) with every needed license in
   the list. A missing one leaves TwinCAT in Config after activation. The license is bound to the System ID; it was verified
   to stay the same across a runtime restart and a reboot, but not across a VM clone or move.

Verified 2026-10-06 on the first runner (TwinCAT 3.1 Build 4024.66, QEMU VM, platform level `other (90)`): after a
reboot the runtime starts on its own as SYSTEM and `Run-Tests.ps1` passes 60/60. The runner service
(`actions.runner.*`) has a delayed automatic start, so it can still show Stopped for a minute after boot.

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

## Publishing the compiled library with each release

`release-library.yml` (BROTLib, AstroBROT, HalfBROT, MONETcommon, MONETRoof) builds a tag on the
runner with `tctool <Repo>.sln library --xae ... --plc ... --out <Repo>_<tag>.library --install` and attaches the saved file to that tag's
GitHub Release, creating the Release if it does not exist. `tag-release.yml` dispatches it right
after it pushes a new tag, so the whole chain is: dispatch `release.yml` → merge the release PR →
tag → `.library` on the Release. It can also be run by hand for any existing tag
(`gh workflow run release-library.yml -f tag=v0.4.1`), e.g. to backfill. Unlike `tcbuild.yml` it is
`workflow_dispatch` only (it is triggered by `tag-release.yml`, not by pushes), and it needs to exist on `main` before it can be dispatched.

`--xae` and `--plc` (TcBuild: `-x`, `-p`) are the XAE project and PLC project names from the `.sln`/`.tsproj`; they
differ in case from the repo name for MONETRoof (`--xae MONETroof --plc MonetRoof`). Using the `.plcproj`'s `<Name>`
(`MONETRoof`) fails: `tctool` answers with "no PLC project ...; found: ...". The workflow downloads `tctool` in the version
pinned in `.github/tctool-version`, but that file and `tools/Get-TcTool.ps1` come from the checked-out tag, so a tag from before
they existed cannot be released with this workflow (the build would need a second checkout of `develop` for the tooling).

## Known TcBuild flakiness (historical; `tctool` handles the COM busy case itself)

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

## TcBuild exit codes (historical; the `tctool` codes are in the tctool section)

Per TcBuild's README: **0** = built, **1** = built *with compile warnings* (a success), **2** =
compile errors, **3** = COM busy (retry), **4** = unknown exception, **5** = missing file. Full XAE
telescope solutions (IAG50cm, MONETS, MONETN) always carry some warnings, so they exit 1 — which the
workflows used to treat as a failure ("exit 1, warnings only, nothing written to disk"). They do
build: the earlier belief that TcBuild cannot handle multi-project / TwinSAFE solutions was a
misreading of that exit code. `tcbuild.yml` therefore passes on 0 and 1, retries on 3, and fails on
anything else. (2026-10-06: checked on MONETS, IAG50cm and MONETN; removing the TwinSAFE project or
DriveManager/MotorTuning from a copy of MONETS changed nothing, since there was nothing to fix.)

What *did* block these solutions was real: BROTLib `FB_Comm_MQTT` used a non-existent
`stWill.fbPayload` (fixed in 0.5.3), and MONETN had an unsuppressed `SA0033` on `Global_Version`.
