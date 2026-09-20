# TwinCAT CI investigation: TcBuild + self-hosted runner vs. ironplc

Status: mechanism fully proven, then deliberately torn down; root cause of the one remaining
gap now understood and accepted as a known limitation, not a bug to keep chasing. Steps 1–4
confirmed working, including a real workflow-triggered build via a self-hosted runner in
interactive console mode (2026-09-15), as a Windows service (2026-09-16), and — after
consolidating six separate repo-level runners into one — as a single **org-level** runner
covering the whole `brotlib` org (2026-09-16, see below). CI works reliably for every pure
PLC-**library** repo (BROTLib, AstroBROT, MONETcommon, HalfBROT, MONETRoof). `IAG50cm` and
`MONETS` (full telescope-application solutions with TwinSAFE sub-projects) were root-caused via
manual XAE testing: **the code is completely healthy** (XAE's own Rebuild All: 0 errors), the
failure is a genuine TcBuild limitation with multi-project + TwinSAFE solutions, not fixable from
this side (see below) — accepted as a permanent manual-build gap for those two repos specifically.
`ironplc` was ruled out as a near-term fix for that gap, or for anything else here (see below).
**At the user's request, all CI infrastructure on IAG50cm's `Becky` was subsequently torn down
completely** (org runner deregistered, service removed, local directory deleted) — this machine
currently runs no self-hosted runner. Everything needed to stand it back up (on this machine or a
future dedicated VM) is captured in
[twincat-ci-runner-setup.md](../design/twincat-ci-runner-setup.md).

## Fleet-wide build pass across all 8 PLC repos (2026-09-16)

Cloned every PLC repo in the `brotlib` org onto IAG50cm's `Becky` (BROTLib, AstroBROT, IAG50cm,
MONETcommon, MONETS, MONETN, HalfBROT, MONETRoof) and ran `TcBuild build`/`install` against each,
originally to fix the stray `4026.7` visualization-profile mismatch found in `AstroBROT.plcproj`
(see the service-mode section below) but expanded once real library-resolution issues turned up
along the way. Results:

- **BROTLib, AstroBROT, MONETcommon, MONETRoof, HalfBROT** (all pure PLC libraries): all build/
  install cleanly (after the usual cold-start retry or two). Visualization profile corrected to
  `4024` and pushed for BROTLib, AstroBROT, MONETcommon (each as its own commit, `Released` left
  at whatever it already was — see the `Released` flag note below). HalfBROT and MONETRoof needed
  no profile fix (already correct or the field wasn't touched by `install`).
- **Found and fixed a real stale-library problem, not just the profile mismatch:** `MONETS`
  failed to compile against the installed `BROTLib` library (`0.3.0`) — `FB_BaseTelescopeControl`/
  `FB_AltAzTelescopeControl` didn't implement `I_Telescope`'s `CoverAutoOpen` property, even
  though the *current git source* for BROTLib clearly has it. The installed library binary was
  simply out of date relative to the checked-out source. Reinstalling `BROTLib` (`TcBuild install`,
  → `0.4.2`), then `MONETcommon` and `MONETRoof` (which depend on it) against the refreshed copy,
  resolved it — MONETS's interface-mismatch errors disappeared entirely on the next attempt.
- **`IAG50cm` and `MONETS`** (both full XAE telescope solutions with I/O/target config, not pure
  libraries): both consistently fail with exit code 1, warnings only (no `E:` errors), nothing
  written to disk, unaffected by repeated retries — the same wall, hit independently on two
  different solutions. Not yet root-caused; next step is reproducing via XAE's own GUI (Rebuild
  All) to see whatever the Error List shows that TcBuild's console output doesn't. Parked.
- **`MONETN`**: hit a different, real, genuine compile error — `FB_RoofControl` called with
  `min_position`/`max_position` inputs that don't exist on it. This is MONETN's own locally
  vendored (not library-referenced) roof-control code; per
  IAG's own `specs/design/monetcommon-monetn-monets-unification-plan.md`
  MONETN was never migrated to reference MONETcommon's library the way MONETS was (unification PR
  still open). **Left as-is per the user** — known, pre-existing, unrelated to this investigation.

**Service mode re-confirmed working, now for real (2026-09-16, after the fleet-wide pass above):**
switched both `iag50cm-becky` and `brotlib-becky-service` back to Windows service mode and
re-ran BROTLib's workflow. Passed twice cleanly (one transient `RPC_E_SERVERCALL_RETRYLATER` in
between, the known/documented flakiness, unrelated). This closes out the earlier back-and-forth
about service vs. interactive mode: **service mode was never actually the problem.** What looked
like a service-mode-specific failure earlier was the stale `AstroBROT`/`BROTLib.plcproj`
visualization-profile value being wiped by `actions/checkout`'s `clean: true` on every run,
regardless of hosting mode — interactive mode only appeared more reliable because manual retries
in the same uncleaned working directory let the one-time fix persist by accident. Now that the
correct profile is committed to the repos themselves (see the fleet-wide pass above), both modes
work identically. Both runners are left running as services.

**`Released` flag gotcha, found and corrected mid-pass:** `TcBuild build`/`install` needs to save
the project to write the corrected visualization profile, and TwinCAT won't let a project flagged
`Released: true` be saved at all — so the tool flips it to `false` as a side effect. This is not a
bug to blindly revert: a project actually modified after being marked released should honestly
read `false`, not have that flag forced back to `true` by a text edit (which very nearly happened
here, then was caught and undone — see MONETcommon's `b85d090`/`b94ea5d`/`ba31c21` commits). Watch
for this on any future automated `.plcproj` save; it isn't something worth "fixing" by force.

## Service-mode runner confirmed working, on a different machine (2026-09-16)

Registered a repo-level self-hosted runner (`iag50cm-becky`, labels
`self-hosted,twincat,windows,iag50cm`) against `brotlib/IAG50cm` — **on IAG50cm's `Becky`**, the
actual telescope-fleet engineering PC (see the [[brotlib-becky-naming-convention]] gotcha: three
machines share this hostname across the fleet). This is a different machine from *both* of the
ones mentioned earlier in this doc: steps 1–3's test rig (the user's personal Windows laptop, not
part of the fleet at all — see the correction under "Progress (2026-09-15)" below) and the
separate "MONET/S dev machine" TcBuild install. TwinCAT 3.1 Build 4024, XAE Shell 1.17.0.0 already
installed on IAG50cm's `Becky`; TcBuild v1.0.1.0 and PowerShell 7 installed fresh for this.

Tested both hosting modes back-to-back on this runner:
- **Interactive console mode** (`run.cmd` via `Start-Process`, not a service): confirmed working,
  same as the 2026-09-15 result on the other machine.
- **Windows service mode** (`config.cmd --runasservice --windowslogonaccount iag50cm`, i.e. running
  under the operator's own Windows account rather than `LocalSystem`/`NETWORK SERVICE`): **also
  confirmed working** — `TcBuild build IAG50cm.sln` produced the identical output (same compiler
  warnings, same exit code) in service mode as in interactive mode, no new COM/RPC errors. This
  resolves step 4's open question: at least when the service runs under a real user account (not
  a built-in service account), XAE's COM automation interface does not require an interactive
  desktop session. **Not tested:** service running under `LocalSystem`/`NETWORK SERVICE` instead
  of a real user account, or behavior after that user's session is fully logged off (as opposed to
  the service simply running) — still open if that distinction matters operationally.

Also hit and resolved along the way, worth keeping as known gotchas:
- `config.cmd --runasservice --windowslogonaccount ... --unattended` fails outright ("Invalid
  configuration provided for windowslogonpassword") — `--unattended` forbids the interactive
  password prompt but doesn't accept the password any other way in this invocation; drop
  `--unattended` so `config.cmd` prompts for the account password interactively instead.
- Minting a runner registration token (`gh api -X POST .../actions/runners/registration-token`)
  and running an elevated installer (e.g. the TcBuild MSI via `msiexec ... -Verb RunAs`) are both
  actions an AI agent's own auto-mode classifier blocks as credential/elevation-sensitive — had to
  be run by the human operator directly, not automatable end-to-end by an assistant on this
  machine.
- Killing a stray `Runner.Listener` process with `Stop-Process -Force` (e.g. to restart it with a
  refreshed PATH after installing Git) leaves an orphaned session server-side, producing "A
  session for this runner already exists" (`TaskAgentSessionConflictException`, HTTP 409) on the
  next start. Self-heals via the listener's own 30s-backoff retry once the stale session times out
  — no manual intervention needed, just wait ~1-2 minutes.
- A fresh PowerShell session doesn't pick up a PATH change from an install done in a *different*
  PowerShell process/tool call in the same session — each call is its own process reading a
  possibly-stale cached environment. Must explicitly refresh via
  `$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + ...("Path","User")`
  before relying on a just-installed CLI tool (git, gh, etc.) being on PATH. Bit the runner itself
  too: starting it via `Start-Process run.cmd` before refreshing PATH in that shell meant the
  listener process inherited a `git`-less PATH, so `actions/checkout` silently fell back to a slow
  REST-API zip download instead of a real `git clone` — restarting the listener after a PATH
  refresh fixed it.

**New open item, separate from the runner infrastructure question:** `TcBuild build IAG50cm.sln`
itself (as opposed to `BROTLib.sln`, which builds cleanly and reproducibly on this machine)
consistently fails with exit code 1, producing only compiler *warnings* (no `E:` errors) and no
regenerated boot project — both via the runner and run manually at the console. Unlike the
`BROTLib.sln`/exit-1 case documented above, this isn't a cold-start fluke (retried directly, same
result every time) and isn't a stray-XAE-process conflict (confirmed none running). Suspected
cause: IAG50cm.sln is a full XAE solution with a target system (I/O config, NC axes) rather than a
plain PLC-library-only solution like BROTLib, and TcBuild's console output may not surface
whatever's actually failing (e.g. an I/O/target-system check) the way it surfaces IEC 61131-3
compiler diagnostics. Not yet investigated further — parked; next step would be reproducing via
XAE's own GUI (Rebuild All) to see the full Error List.

## First compiled MONETcommon.library attached to a GitHub Release (2026-09-16)

Until now no release ever shipped the actual compiled artifact — `v0.2.0` through `v0.3.0`'s
GitHub Releases (created manually via `gh release create`) had notes only, no binary. Built one
for real via TcBuild on the MONET/S dev machine and attached it to `v0.3.2`:

```
TcBuild install MONETcommon.sln -x MONETcommon -p MONETcommon -l MONETcommon.library
```

(`install`, not `build` — `build` compiles in place; `install` is TcBuild's "save PLC project as
a library" command, the one that actually produces a `.library` file.) Confirmed the build ran at
exactly the `v0.3.2` tagged commit (`d468379` — the tag is annotated, so `git rev-parse v0.3.2`
returns the *tag object's* SHA, not the commit's; `git log v0.3.2` dereferences correctly and
matched `HEAD`). Result: 363,700 bytes, attached via `gh release upload`-equivalent
(`gh release create ... <file>`), confirmed present via `gh release view v0.3.2`.

**Not yet automated** — this was a manual one-off build + manual attach, not part of
`release.yml`. If this is wanted on every version bump going forward, `release.yml` would need a
TwinCAT-capable runner (it currently runs on plain `ubuntu-latest`, which can't run TcBuild at
all) to build and `gh release create`/`upload` the `.library` as part of the same workflow that
already bumps the version and tags.

## Version-bump automation shipped for MONETcommon (2026-09-16)

`MONETcommon` got a `.github/workflows/release.yml` (`workflow_dispatch`, `ubuntu-latest` — no
TwinCAT/build step involved at all) that takes a typed `X.Y.Z` version input, updates
`ProjectVersion` in `MONETcommon.plcproj` and all four numeric fields + `sVersion` in
`GVL_Version.TcGVL` via `sed`, commits to `develop`, fast-forwards `main`, and tags `vX.Y.Z`.
Verified working: `v0.3.1` and `v0.3.2` tags both exist on `origin`, and `GVL_Version.TcGVL`
correctly reads `0.3.2` matching `MONETcommon.plcproj` after the second run.

**This is a different, narrower kind of automation than step 7's original framing** ("stamping it
from `git describe`" at build time) — worth being precise about the distinction:
- **Solved**: the two-file drift risk (`.plcproj` and the GVL going out of sync with each other,
  or someone forgetting to update one) — a single typed input now keeps both in lockstep.
- **Not solved**: the version number itself is still a human decision, typed by hand on each
  dispatch — it's not derived automatically from commit count/`git describe`/any git metadata.
  Nothing here reads git history for the version; it only writes the operator-supplied value
  wherever it needs to go.
- **Gap found**: the workflow does `git tag` + push only, not the GitHub Releases API — `v0.3.1`/
  `v0.3.2` exist as raw tags but have no GitHub Release object (`gh release list` still shows
  `v0.3.0` as "Latest" from the earlier manual `gh release create` calls). Not necessarily wrong,
  but worth deciding deliberately whether release notes/objects are wanted per bump or if tags
  alone are the intended end state.
- Independent of, and not yet connected to, the TcBuild work below — this workflow never invokes
  TcBuild or verifies the project actually compiles at the bumped version; it's pure text
  substitution plus git operations.

## TcBuild installed on the MONET/S dev machine (2026-09-16)

Separately from the dedicated test rig above, TcBuild `v1.0.1.0` was installed on the actual
MONET/S working machine (not a test/CI box) — no runner, no workflow, just the CLI, to confirm it
works here too and as a manual local-build option independent of the CI investigation's outcome.

- Installer MSI pulled directly from `JustusRijke/TcBuild`'s `main` branch (`TcBuildInstaller/Release/TcBuild_Installer.msi`, 5,809,664 bytes — matches this doc's "~5.8 MB" note) — confirms it's still not published via GitHub Releases or NuGet.
- Hit the exact same `Error 1303` (insufficient privileges) this doc already documented when run non-elevated; installed successfully once run elevated (`msiexec /i ... /qn`, silent — gives **zero visible feedback even on success**, worth knowing so a successful silent install isn't mistaken for a no-op).
- **New gotcha found**: the first `TcBuild build BROTLib.sln` attempt failed with **exit code 1** (undocumented in this doc's exit-code notes so far — only 0/2/3 were characterized before) and no diagnostic output beyond a visualization-profile warning. Root cause: a **stray `TcXaeShell.exe` process left running from earlier, unrelated activity** on this machine. Killing it and retrying succeeded immediately (exit 0, fresh `.tpzip` timestamp confirming a real build, not a no-op). Consistent with this doc's existing "persistent XAE process" caching findings, but exit code 1 specifically (as opposed to 2 or 3) for "a stray process is interfering" is a new data point — add to the exit-code table if one gets built out.
- `TcBuild --help` / `TcBuild build --help` have no verbose/logging flag — when a build fails without a clear reason, checking for stray `TcXaeShell`/`devenv` processes first is the cheapest diagnostic step before assuming a real compile error.
- **Clarified the scope of the gotcha above (2026-09-16):** it's specifically a *stray/orphaned* process from an unrelated earlier build, not "TcXaeShell running at all." Ran `TcBuild install MONETcommon.sln ...` while the operator's own TcXaeShell session was actively open (mid-way through manually deploying `MONETS` to the live PLC) — succeeded cleanly (exit 0, fresh `.library`), and the operator's session was confirmed untouched afterward (same PID, same start time). TcBuild evidently drives its own separate TcXaeShell instance for the COM automation rather than reusing or conflicting with an already-open one. So: an active, in-use XAE session is fine; a leftover one nobody's using anymore is the actual risk.

## Why

The main motivation is CI in the general sense — an automated build (and ideally test) step on
every push, which none of these repos currently have (checked: no `.github/workflows/`, no
`.gitlab-ci.yml` in BROTLib, MONETcommon, MONETS, MONETN, HalfBROT). Catching a broken build or
a regression before it reaches a telescope controller is valuable on its own, independent of
anything version-related.

Automated version stamping is a secondary motivation that happens to need the same
infrastructure. Custom TwinCAT libraries (BROTLib, MONETcommon, HalfBROT) have no live version
signal — unlike Beckhoff's own `Tc2_*`/`Tc3_*` libraries, which publish a `Global_Version` GVL
readable live via ADS (confirmed working against MONETN's controller, see IAG's own
`specs/design/monetn-hardware-inventory.md`, kept private). The proposed fix is a
matching version GVL per custom library, populated from `git describe`/commit SHA — but that
only avoids drift (the same problem the roof-counter plan's stale status line had) if the
stamping happens automatically at build time rather than being hand-typed, which is itself a CI
step.

Note this only covers code that's a real library reference — MONETN vendors local copies of
MONETcommon's FBs rather than referencing the library (see
IAG's own `specs/design/monetcommon-monetn-monets-unification-plan.md`),
so a version GVL added to MONETcommon wouldn't appear in MONETN's vendored copies until that
unification (PR open, not yet merged) lands.

## Prior attempt (failed)

A dedicated Windows runner with TwinCAT XAE was tried before this conversation. It failed:
controlling TwinCAT XAE *remotely* wasn't possible, because XAE doesn't implement some of the
Visual Studio automation-interface endpoints that remote driving would need. This is the reason
significant work is already going into **ironplc** (see peer session `ironplc-1b`) — an
independent, non-Beckhoff-dependent IEC 61131-3 toolchain that sidesteps the automation
interface entirely rather than working around its gaps. Status of that work is not covered by
this doc; check with that session directly.

## New angle: TcBuild, run locally rather than remotely

[TcBuild](https://github.com/JustusRijke/TcBuild) is a community (not Beckhoff-official) CLI —
`TcBuild build SomeSolution.sln` — that requires TwinCAT v3.1.4024 or higher installed
stand-alone, which matches these repos' target build (`3.1.4024.66`). Checked its README
directly (not just a search summary): it still goes through TwinCAT's COM Automation Interface
underneath — its exit-code table includes code `3`, "Unhandled COM exception (tricky COM issue,
try again)" — so it is **not** a different mechanism from what failed before, just a narrower
one (standalone XAE Shell, not full Visual Studio).

The architectural difference that might matter: the prior failure was about a CI *runner on one
machine remotely driving XAE on another*. Running TcBuild as a local process on the same box
that has XAE installed — e.g. invoked by a self-hosted GitHub Actions runner living on that
box — isn't remote control, it's the same kind of local invocation as building by hand at that
keyboard.

**Unverified risk:** VS/XAE's COM automation interface typically needs an interactive desktop
session to function; it can fail in a non-interactive context (a GitHub Actions runner installed
as a Windows service, or a disconnected — not just backgrounded — RDP session). If the prior
attempt's runner was configured as a service, that could be the same underlying problem
resurfacing under a different name. **Confirm how the prior runner was configured before
concluding this is a genuinely different path.**

Also found, not yet evaluated: [zkbuild-action](https://github.com/Zeugwerk/zkbuild-action), a
GitHub Action purpose-built for building/unit-testing TwinCAT PLC projects in CI.

## Progress (2026-09-15)

A Windows machine with TwinCAT XAE Shell already installed was identified — **the user's personal
Windows laptop, not any of the fleet's `Becky` engineering PCs** (TwinCAT **3.1.4026.16** — not an
exact match for the `3.1.4024.66` target stated above, but TcBuild worked against it regardless;
worth re-checking if a build ever behaves oddly). Confirmed 2026-09-16: this is a separate machine
from the "TcBuild installed on the MONET/S dev machine" note further down, and separate again from
IAG50cm's `Becky` used in the service-mode work below — so the `4026.16`/`4024.66` mismatch noted
here says nothing about version drift *within* the telescope fleet itself, only that this laptop
differs from the fleet's target version. (Actual fleet-internal drift was found independently,
between the checked-in `AstroBROT.plcproj`'s embedded profile — `4026.7` — and IAG50cm's `Becky`'s
installed `4024` — see the service-mode section below. Still unknown which real machine last wrote
that `4026.7` value, or what MONET/S's and MONET/N's own `Becky` PCs are running; no route or
access from IAG50cm's `Becky` to check either.

**MONET/S's own `Becky` checked directly, 2026-09-16** (this machine has that access): TwinCAT
3.1 Build 4024 (`3.1.4024.66`), XAE Shell `1.17.0.0` — an exact match to IAG50cm's `Becky`, and to
this repo family's stated target build. **Rules out MONET/S's `Becky` as the source of the
`4026.7` value** embedded in `AstroBROT.plcproj`. Checked via the method now documented in
[checking-twincat-xae-version.md](../steering/checking-twincat-xae-version.md).

**MONET/N's own `Becky` also checked, 2026-09-16** (see IAG's own
`specs/design/monetn-hardware-inventory.md`, kept private): same result — TwinCAT
3.1 Build 4024 (`3.1.4024.66`), XAE Shell `1.17.0.0`. **Rules out MONET/N's `Becky` too.**

**All three fleet `Becky` machines (IAG50cm, MONET/S, MONET/N) now confirmed on identical
tooling** (Build 4024 / XAE Shell 1.17.0.0) — none of them wrote the stray `4026.7` value, so this
was never fleet-internal drift after all. **Likely explanation:** the personal Windows laptop used
for steps 1–3 of this very investigation (see "Progress (2026-09-15)" above) was recorded at
TwinCAT **3.1.4026.16** — the `4026` matches, and `.plcproj`'s embedded profile format may just be
a shorter representation than the full Programs-and-Features version string. Plausible that
`AstroBROT.sln` was opened or built on that laptop at some point outside the fleet, leaving its
`.plcproj` stamped with a non-fleet profile value that nothing since has reset. Not proven (would
need to check that laptop's exact `.plcproj`-embedded profile format to confirm the `4026.16` →
`4026.7` mapping), but no fleet machine is a better fit, and the mystery no longer implies any
real cross-telescope version drift to worry about operationally.)

**TcBuild install gotcha:** the README's `TcBuild build SomeSolution.sln` CLI usage is correct,
but TcBuild is **not** a dotnet tool/NuGet package — `dotnet tool install --global TcBuild`
silently grabs an unrelated same-named NuGet package (Total Commander plugin wrapper DLLs) and
fails with a confusing `DirectoryNotFoundException`. The real install is the MSI checked into
the repo's own tree: `TcBuildInstaller/Release/TcBuild_Installer.msi` (unsigned, ~5.8 MB, no
GitHub Releases published). It must be run **elevated** — running it non-elevated fails with
MSI Error 1303 (insufficient privileges on `C:\Program Files\...`). Installed successfully via
`msiexec /i TcBuild_Installer.msi /qn` run as admin → `TcBuild.exe` v1.0.1.0 at
`C:\Program Files\Industrial Brains B.V\TcBuild\`.

**Step 2 result: success.** Ran `TcBuild build BROTLib.sln` at the physical console session
(not RDP — confirmed via `query session` showing `console`/`Aktiv`) against BROTLib (no
MONETcommon checkout was available on this machine, so BROTLib substituted — same class of
custom library). Exit code 0, and `BROTLib\_Boot\TwinCAT RT (x64)\CurrentConfig\BROTLib.tpzip`
was freshly rewritten with a matching timestamp, confirming a real build ran rather than a
silent no-op.

This does **not** yet touch the prior failure mode — it's a local, interactive, by-hand build,
same category as "building by hand at that keyboard" from the architectural-difference note
above. Steps 3–4 (self-hosted runner, interactive mode, post-RDP-disconnect) are what actually
test the remote-COM-automation risk and are still outstanding.

**Error reporting confirmed working.** Tested against a scratch copy of BROTLib (not the real
checkout) with a deliberate syntax error injected into `F_IsNumericValue.TcPOU`'s
implementation. TcBuild returned **exit code 2** (not 0) with real compiler diagnostics —
file path, line number, and genuine TwinCAT compiler error codes (`C0009 Unexpected token`,
`C0189 ';' expected`), the same errors XAE's own IDE would show. So TcBuild is a legitimate CI
gate, not a pass-through that always exits 0.

**Confirmed TcBuild requires XAE, via COM automation, concretely.** Watching processes during a
build shows TcBuild spawning a full `TcXaeShell.exe` process and driving it — not compiling
independently. This is the exact mechanism the "Unverified risk" note above warns about: since
it's COM automation against a real XAE Shell process, it inherits XAE's need for an interactive
desktop session, which is precisely what steps 3–4 need to test (self-hosted runner in
interactive mode vs. service mode, and behavior after an RDP disconnect).

## Step 3 result: success, plus a discovered prior CI attempt (2026-09-15)

BROTLib/BROTLib's `origin/develop` and `origin/main` already had a `build.yml` +
`.github/scripts/Build.ps1` from 2026-07-17 (the user's own earlier work) — a much more
thorough direct-DTE-automation approach (proper `IMessageFilter` for COM "server busy" retries,
`ITcPlcIECProject2.CheckAllObjects()`, timeout + Error List dump on failure, kills stray
`devenv`/`TcXaeShell` processes at startup). This is almost certainly the **prior attempt**
referenced at the top of this doc. Per the user: it never worked end-to-end. It also
auto-triggered on `push`/`pull_request` to `main`/`develop`, which — combined with `runs-on:
[self-hosted, windows, twincat]` overlapping the labels given to the new test runner below —
would have exposed that runner to PR-triggered runs on this public repo. Removed both files
(commit `82f6811`; still recoverable from git history) rather than just disabling triggers,
per the user's choice, since the TcBuild-wrapper approach supersedes it.

Registered a repo-level self-hosted runner (`brot-test-console`, labels
`self-hosted,twincat,windows,test`) against `BROTLib/BROTLib` — org-level registration would
cover all repos at once but needs `admin:org` token scope, not available with the current `gh`
auth (`repo`, `workflow`, `read:org`, `gist` only); revisit once ready to cover the other repos.
Installed the official `actions-runner-win-x64-2.337.0` (sha256-verified), configured it, and
started it via `run.cmd` **interactively** (`Start-Process`, not a Windows service) in the
console session — this is the lever the "Unverified risk" note above called out as most likely
to matter.

Added `.github/workflows/tcbuild-test.yml` (`workflow_dispatch` only, so it can't be triggered
by PRs/pushes) and triggered it via `gh workflow run`. First attempt failed only on `shell:
pwsh` — this machine has no PowerShell 7, only Windows PowerShell 5.1 (the same gotcha the
removed `Build.ps1`'s own comments had already flagged). Fixed to `shell: powershell` and
re-ran: **the workflow succeeded end-to-end** — GitHub's own scheduler dispatched the job to
this runner, `TcBuild build BROTLib.sln` ran and passed, job completed in ~55s
(run `35002470345`). This is a materially stronger result than the earlier local-console test:
it's a real GitHub-triggered run through the full self-hosted-runner pipeline, still from an
interactive (non-service) desktop session.

Note: `workflow_dispatch` workflows are only invocable once present on the repo's **default
branch** — had to fast-forward `main` to `develop` (clean fast-forward, no divergence) to
unblock this; worth remembering for any repo where `main`/`develop` do diverge.

This machine is intended as a **test rig only** — real deployment is planned for a different
machine — so treat the runner/workflow here as disposable, not as the final setup.

## Multi-package dependency build investigation (2026-09-15)

Question: can TcBuild build a package that depends on another custom library (e.g. HalfBROT,
which references BROTLib)?

**Mechanism confirmed.** HalfBROT's `.plcproj` references BROTLib via a `PlaceholderReference`
(`BROTLib, * (BROT)`), a standard TwinCAT **library reference** resolved against installed
libraries — not a source/project reference to a sibling checkout. `TcBuild build HalfBROT.sln`
succeeded (exit 0, fresh `.tpzip`) because BROTLib was already installed as a library on this
machine (`BROT/BROTLib`, versions 0.3.0 and 0.4.0, installed manually back on 2026-07-17 — not
by anything in this investigation). `TcBuild build` does **not** install library dependencies
as a side effect; that's a separate command (`TcBuild install Library.sln -x <XAE project> -p
<PLC project>`, not yet tested here). **A real CI pipeline for a dependent package needs an
explicit two-step order: `TcBuild install` the upstream library first, then `TcBuild build` the
dependent solution** — otherwise a clean runner that's never had the dependency manually
installed will fail to resolve it.

**Important caveat — the "does it actually fail without the dependency" test was inconclusive,
and the reason why is itself a useful finding.** Attempted to prove the negative case by
removing BROTLib's availability and rebuilding HalfBROT:

1. First, editing the `.plcproj` text (`PlaceholderReference`/`PlaceholderResolution`) to point
   at a nonexistent version, then a nonexistent library name entirely — build still succeeded
   both times. **TcBuild does not read library resolution from the raw `.plcproj` XML** — it
   drives the real TwinCAT XAE project state via COM automation, which resolves references
   through its own internal/cached state, not the text on disk.
2. Renaming away the actual installed library folder
   (`C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries\BROT\BROTLib` →
   `..._temp_hidden`, then restoring immediately after, reversible) — build *still* succeeded.
   Root cause: a **persistent `TcXaeShell.exe` process had stayed alive since an earlier build
   in this same session** and had BROTLib cached in memory, so the on-disk removal didn't
   matter. Killing that process and retrying (still renamed away) — still succeeded, because of
   a **second, separate cache**: TwinCAT also keeps a **project-local `_Libraries/` cache**
   (`HalfBROT/HalfBROT/HalfBROT/_Libraries/BROT/BROTLib/0.4.0/BROTLib.library`, confirmed
   **not** git-tracked — pure local build state) that had already been populated by earlier
   successful builds this session and was checked independently of the global repository.
3. Cleared *both* caches (killed the XAE process, deleted the local `_Libraries/` dir) and
   reran with BROTLib's global install still renamed away — build **still succeeded** (exit 0),
   and this time confirmed via the regenerated `_Libraries/` cache that BROTLib genuinely was
   **not** re-resolved (every other library — System, Tc2_*, CAA, CODESYS, 3S — reappeared in
   the cache; no `BROT/` folder did).
4. That pointed at the real explanation: `grep`-ing HalfBROT's POUs for `BROTLib.`-qualified
   type usage found **zero matches**. HalfBROT declares the BROTLib reference but its currently
   active code doesn't use any BROTLib symbols, and TwinCAT (standard IEC 61131-3 compiler
   behavior, not TcBuild-specific leniency) does not hard-fail on an unresolved-but-unused
   library reference.

**Net takeaway:** confirmed TcBuild *can* build a dependent package once its library
dependencies are installed, and confirmed the two-cache-layer resolution behavior (persistent
XAE process memory + project-local `_Libraries/`) that CI needs to account for (a stale/warm
runner could mask a genuinely missing dependency — same class of risk as the flaky
`RPC_E_SERVERCALL_RETRYLATER`/exit-code-3 seen repeatedly on cold starts throughout this
session, mitigated with a short retry). Did **not** get a clean proof that TcBuild fails when a
*used* dependency is genuinely missing — HalfBROT wasn't a valid test case for that because it
doesn't currently use BROTLib symbols despite referencing it. Re-run this specific test against
a package that provably calls BROTLib types (or add a trivial one) if that proof is still
wanted. (All test mutations were on scratch copies or reversible renames of installed-library
state; the real HalfBROT/BROTLib checkouts were restored to clean `git status` afterward.)

## IAG50cm/MONETS root cause: a real TcBuild limitation, not a code bug (2026-09-16)

Both `IAG50cm.sln` and `MONETS.sln` consistently failed via TcBuild's `build` command — exit 1,
only compiler *warnings* (no `E:` errors), nothing written to disk, immune to retries (see the
fleet-wide pass above). Root-caused by testing manually in XAE:

1. **First, a real (if ultimately unrelated) fix**: `IAG50cm.sln` referenced two projects at
   sibling paths outside the repo entirely — `..\TwinCAT Drive Manager 2 Project1\...` and
   `..\TwinCAT Measurement Project1\...`. `git log` showed these were committed once (Oct 2024,
   "Safety works") but never survived a later "clean up of broken file structure" reorganization
   — genuinely missing from the repo since then, a stale `.sln` reference nobody had cleaned up.
   Removed both `Project()` blocks and their orphaned `ProjectConfigurationPlatforms` entries
   (commit `0fbf958`) — legitimate repo hygiene regardless of what follows, but **did not fix the
   build failure**: identical exit 1/warnings-only result afterward.
2. **The real answer came from testing in XAE directly** (the user ran **Build → Rebuild All**
   manually): **`IAG50cm` compiles with 0 errors, 37 warnings — completely clean.** All 5 projects
   in the solution (`IAG50cm` + the three TwinSAFE sub-projects `ELM7221`/`ELM7212`/`EL1918`)
   built successfully, no password/login prompt for any of them, `Rebuild All: 5 succeeded, 0
   failed, 0 skipped`.
3. **Conclusion: this is a TcBuild automation limitation with multi-project + TwinSAFE solutions,
   not a project bug.** Every repo that built cleanly via TcBuild (BROTLib, AstroBROT,
   MONETcommon, HalfBROT, MONETRoof) is either a single-project library solution, or — in
   MONETRoof's case, which *does* have an embedded TwinSAFE project — was only ever driven via
   `TcBuild install` scoped to the one named PLC project (`-x`/`-p`), never a whole-solution
   `build` that would also touch the TwinSAFE sub-projects. `TcBuild build <solution>` has no
   scoping flag (checked `--help`) — it always targets the entire solution. Tried `TcBuild install`
   as a diagnostic against `IAG50cm.sln` too: different, expected failure ("not a managed library
   ... 'Title' not specified") — `install` fundamentally doesn't apply to an application project,
   only a library one, so there's no working TcBuild CLI verb for this class of solution at all.
4. **No prior report exists**: `JustusRijke/TcBuild` has zero GitHub issues, open or closed —
   checked before concluding this was worth writing up rather than searching further.

**Practical impact, reframed by the user and worth keeping in mind:** this only matters for
catching compile errors automatically — it was never going to produce a release artifact anyway,
since compiled-library-to-release-asset only applies to the library repos (see "First compiled
MONETcommon.library..." above); `IAG50cm`/`MONETS` are deployed straight to their controllers, not
packaged as versioned binaries. So the actual gap is narrower than it first looked: no automated
regression-catch for these two solutions specifically, everything else about the CI setup is
unaffected. **Accepted as a permanent limitation** — manual XAE builds only for these two, CI
covers the rest.

## `ironplc` ruled out as a near-term fix (2026-09-16)

Asked the peer session actively working on `ironplc` (`Ironplc TwinCAT validation`) directly,
rather than guess. Summary of their answer, worth trusting over anything guessed here:

- **No deployment target at all, not just immature**: ironplc's codegen targets its own toy
  interpreter (`ironplc-vm`), not any real Beckhoff runtime. Its own doc comment calls it a
  "steel-thread demonstration" supporting only `PROGRAM`, `INT` vars, assignment, integer
  literals, binary add, variable refs. Not a path to a deployable artifact for *any* of these
  repos, library or application.
- **What it actually is**: a parser/semantic-analyzer/LSP for IEC 61131-3 ST, with some
  TwinCAT/CODESYS dialect extensions gated behind `--allow-*` flags. Useful as a fast pre-build
  linter/validator, never a builder.
- **TwinSAFE is explicitly out of scope** — `.splcproj` entries are detected and *skipped, not
  analyzed*, deliberately. So even as a future validator, it would never cover the TwinSAFE side
  of `IAG50cm`/`MONETS` — only their plain ST logic, which (per the XAE test above) already
  compiles cleanly anyway.
- **Library resolution doesn't match how these repos work**: ironplc only resolves against its own
  bundled stub declarations for known Beckhoff/CODESYS system libraries — no mechanism to load an
  arbitrary custom project (e.g. BROTLib) as a library dependency of another (e.g. AstroBROT)
  unless both happen to be sibling `.plcproj`s under the same `.sln`, which isn't how this family's
  cross-repo library references work.
- **Blocked on core language features these libraries actually use, today**: `PROPERTY` is not
  implemented at all; `IMPLEMENTS`/`ABSTRACT` are hard-rejected (open upstream issue #1692, filed
  by the maintainer, unfixed as of 2026-09-11). Checked BROTLib directly: **75 `PROPERTY`
  declarations across 14 files**, plus `IMPLEMENTS` used throughout the telescope-control
  interface hierarchy (`I_Telescope`, `I_AltAzTelescope`, `I_Axis`, etc.). ironplc would reject
  BROTLib itself today, not just the IAG50cm/MONETS solutions — this isn't a narrow gap, it rules
  ironplc out for the whole family as things stand.

**Future direction, once upstream lands `PROPERTY`/`IMPLEMENTS`/`ABSTRACT` support:** ironplc for
fast textual validation on every push (seconds, no XAE/COM automation needed), TcBuild for actual
builds/artifacts — sensible split in principle, not actionable yet. Revisit by checking #1692's
status before investing here again; don't rediscover this from scratch.

## CI infrastructure: proven, then fully torn down (2026-09-16)

Once BROTLib's CI was confirmed working (fixed `.plcproj` profile committed, service mode
re-verified), consolidated from six separate repo-level runners (one per library repo) down to a
**single org-level runner** (`brotlib-becky-org`, needs `admin:org` `gh` auth scope) covering the
whole `brotlib` org at once — tested working for MONETcommon, HalfBROT, MONETRoof, AstroBROT via
real workflow-triggered builds, all passing. This answers step 6 below and the `zkbuild-action`
comparison (step 5) is moot now that the org-runner approach works reliably.

**Then, at the user's explicit request, all of it was torn down**: all seven runner registrations
across every repo (the six repo-level ones plus the earlier `brot-test-console` test-rig runner)
deregistered via the GitHub API, all Windows services stopped and deleted, all local runner
directories removed. **IAG50cm's `Becky` currently runs no self-hosted CI runner at all** — this
was a deliberate return to a clean slate, not an accident or a failure. The full setup procedure,
distilled from everything learned in this investigation, is captured in
[twincat-ci-runner-setup.md](../design/twincat-ci-runner-setup.md) specifically so
that standing infrastructure back up — on this machine, or (preferably, to avoid the shared-state
concerns raised during this investigation) a dedicated VM — is quick next time.

## Next steps

1. ~~Install TwinCAT XAE standalone (not full Visual Studio) + TcBuild on the machine.~~ Done.
2. ~~Manually run `TcBuild build` against a custom library's `.sln` at the physical/RDP
   console, confirm it succeeds, before involving any CI runner.~~ Done.
3. ~~Install a self-hosted GitHub Actions runner in interactive/session mode, not as a
   service, and confirm a real workflow-triggered build succeeds.~~ Done — see above.
4. ~~Test after disconnecting the RDP session (not just leaving it open).~~ Superseded: tested
   Windows-service mode instead (no interactive session at all, stronger test than a disconnected
   RDP session) — confirmed working, see above.
5. ~~If that holds up, evaluate `zkbuild-action` as an alternative/comparison.~~ Moot — the
   org-level runner approach works reliably; no need for an alternative mechanism.
6. ~~Decide whether to keep building out this machine or move straight to the real deployment
   target, and register runners on the other repos~~ — done for all repos, then all torn down per
   the user's request (see above). Standing it back up (this machine or a dedicated VM) is now a
   quick, documented, mechanical process — see
   [twincat-ci-runner-setup.md](../design/twincat-ci-runner-setup.md).
7. ~~Test `TcBuild install` against a genuinely uninstalled library~~ — effectively done during the
   fleet-wide pass (BROTLib's stale `0.3.0` install was discovered and fixed by reinstalling to
   `0.4.2`, which is exactly this scenario in practice, if not as a clean isolated test).
8. ~~Only after a build path is confirmed working headlessly: add the version GVL to
   MONETcommon (trial), with the build step stamping it from `git describe`.~~ Done, but not the
   way originally framed here — done *without* waiting on a working build path, and stamped at
   release-commit time rather than build time (see "Version-bump automation shipped" above and
   the full design rationale in
   [custom-library-versioning.md](../design/custom-library-versioning.md),
   including why build-time stamping was rejected). Still not built/deployed to real hardware, so
   the live ADS read itself is unverified — and this remains MONETcommon-only, not yet BROTLib or
   HalfBROT.
9. Whenever CI is stood back up: wire `TcBuild install` + `gh release upload` into `release.yml`
   for the library repos, so compiled `.library` artifacts attach to releases automatically
   instead of the current manual one-off process (MONETcommon `v0.3.2` only so far). Not done this
   session — flagged mid-investigation, not yet built.

## Open question — resolved

~~Whether this is worth doing at all if `ironplc` ends up replacing the Beckhoff toolchain for
these repos.~~ **Resolved 2026-09-16: no.** ironplc has no path to a deployable Beckhoff artifact
at all (wrong target entirely, not a maturity gap), and is currently blocked on core language
features (`PROPERTY`, `IMPLEMENTS`, `ABSTRACT`) that BROTLib itself relies on throughout — see
above. TcBuild remains the only viable build mechanism for this family for the foreseeable future.
