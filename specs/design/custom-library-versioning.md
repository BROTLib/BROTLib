# Custom TwinCAT library versioning (`Global_Version`)

**Naming note (2026-09-16):** this design shipped first as `GVL_Version.TcGVL`/`stVersion`, then
was renamed to `Global_Version.TcGVL`/`stLibVersion_<LibraryName>` the same day once testing
showed the rename merges into the compiler's own auto-generated symbol rather than colliding with
it. The "Design" section below and everything through "Next steps" describes the **current**
(renamed) state. The `## Prior art` / `## Resolved` / `## Tested` sections further down are kept
as a historical record of how that decision was reached — they reference the old `GVL_Version`/
`stVersion` names because that's what was true when each test ran.

Repos: BROTLib, MONETcommon, HalfBROT, AstroBROT, IAG50cm, MONETN, MONETS, MONETRoof (implemented
in all eight as of 2026-09-16)

## Problem

Beckhoff's own `Tc2_*`/`Tc3_*` libraries publish a live, ADS-readable version signal: TwinCAT
auto-generates a `Global_Version.stLibVersion_<Name>` symbol (type `ST_LibVersion`) for every
Beckhoff library a project references. Confirmed independently by inspecting BROTLib's own
compiler-generated `.tmc` output (not by trusting prose): BROTLib references 10 libraries — 9
Beckhoff ones plus the custom library AstroBROT — and `Global_Version` contains
`stLibVersion_*` entries for all 9 Beckhoff ones but **no** `stLibVersion_AstroBROT`. So this is
a genuine compiler feature (`ST_LibVersion` is marked `TcBaseType="true"` — a built-in system
type, not something a specific library declares), but it silently excludes custom libraries.

Result: BROTLib, MONETcommon, and HalfBROT have no live version signal at all. The only version
that exists is `<ProjectVersion>` in each `.plcproj`, which is not readable via ADS — you can
only see it by opening the project file, so there's no way to ask a running controller "what
version of MONETcommon is this?"

## Design

A hand-authored `Global_Version.TcGVL` per library, using Beckhoff's own exact naming convention
(`Global_Version` GVL, `stLibVersion_<LibraryName>` constant) and reusing the same `ST_LibVersion`
base type (no extra library reference needed, since it's a built-in):

```
VAR_GLOBAL CONSTANT
	stLibVersion_MONETcommon : ST_LibVersion := (
		iMajor := 0,
		iMinor := 3,
		iBuild := 2,      // maps to semver patch
		iRevision := 0,   // unused, always 0
		nFlags := 1,      // matches Beckhoff's observed convention; exact bit meaning unconfirmed
		sVersion := '0.3.2'
	);
END_VAR
```

Naming this exactly like Beckhoff's own auto-generated entries isn't just cosmetic: confirmed via
real XAE testing (see "Tested: renaming..." below) that it **merges into the compiler's own
auto-generated `Global_Version` symbol in any consumer**, giving custom libraries the same
first-class visibility as real Beckhoff libraries — a consumer doesn't need to know to look for a
separately-named GVL.

Kept in sync with `<ProjectVersion>` in the same `.plcproj` — both values must always agree, by
construction, because they're written together in the same release step (see below), not typed
independently by hand.

**Rejected alternative: stamping in CI at build time instead of at the release commit.**
Considered making a CI build step run `git describe` and template it into the GVL source right
before `TcBuild build`. Rejected because deployment to real hardware is (and stays) a manual
step — someone opens TwinCAT XAE and builds/downloads from `main` by hand. Whatever a CI build
produces is never what's actually deployed, so stamping inside a CI build artifact would have no
effect on what's live. What actually matters is that `main`'s *source* is already correct before
that manual build happens — which means the stamp has to land in a commit on `main`, not in a
build artifact. Hence: stamp at release-commit time, not build time.

**Known gap, accepted:** if an untagged/ad hoc dev build ever gets deployed directly to hardware
between releases (normal during active TwinCAT development), `GVL_Version` will show the last
*released* version, not the exact code actually running. This is a deliberate trade-off, not an
oversight — closing it would require every deployment to go through a tagged release, which
isn't how development on these repos works.

**MONETN caveat:** this only helps for a real library reference. MONETN vendors local copies of
MONETcommon's FBs rather than referencing the library (see IAG's own specs,
`design/monetcommon-monetn-monets-unification-plan.md`), so `GVL_Version` added to MONETcommon
won't appear in MONETN's vendored copies until that unification lands.

## Prior art: how other projects do this (2026-09-16 web research)

Checked whether this design's naming matches how anyone else has solved "custom TwinCAT
library needs a live version signal." It doesn't, and the mismatch is worth fixing:

- **Beckhoff's own convention is more specific than "reuse `ST_LibVersion`."** The
  auto-generated GVL is literally *named* `Global_Version`, and the constant inside it follows
  `stLibVersion_<LibraryName> : ST_LibVersion` — confirmed on the
  [Tc2_MDP infosys page](https://infosys.beckhoff.com/content/1033/tcplclib_tc2_mdp/178765451.html).
  This repo's design uses `GVL_Version` / `stVersion` instead, which diverges from that
  convention for no reason found in this research.
- **A community tool already does exactly this for custom libraries, using Beckhoff's naming.**
  Beckhoff-USA-Community's "TwinCAT Project Library Creator"
  ([`AAG_Custom-TcPkg-And-Workload`](https://github.com/Beckhoff-USA-Community/AAG_Custom-TcPkg-And-Workload/blob/main/TwinCAT%20Project%20Library%20Creator/ScalingAndConversion/ScalingAndConversion/Version/Global_Version.TcGVL))
  generates a `Global_Version.TcGVL` per custom library with a `stLibVersion_<Name> :
  ST_LibVersion` constant — same fields this design already uses (`iMajor`, `iMinor`, `iBuild`,
  `iRevision`, `nFlags`, `sVersion`), marked `{attribute 'TcGenerated'}` (tool-produced, not
  hand-edited). This confirms the overall approach (mirror `ST_LibVersion` for custom
  libraries) is a known, working pattern elsewhere, not something invented from scratch here —
  but the naming this ecosystem converged on is `Global_Version` / `stLibVersion_<Name>`, not
  `GVL_Version` / `stVersion`.
- **Doesn't shed light on `GlobalVersionStructureIncluded`** (see "Resolved" section below,
  tested negative on real XAE separately from this web research). Nothing found in Beckhoff docs
  or community sources documents that property at all.
- **Separate Beckhoff-native mechanism, not a replacement for this design:** project properties
  has a "POUs for property access" checkbox that generates `F_GetVersion()`, returning
  `ST_LibVersion` populated from the *consuming project's* own version fields (not a library's).
  Known bug in 3.1.4020.28: `sVersion` comes back empty, requiring manual
  `UDINT_TO_STRING`/`CONCAT` reconstruction ([AllTwinCAT writeup](https://alltwincat.com/2017/06/06/project-build-version-in-runtime/)). Relevant only if a future need arises to expose a
  *project's* version rather than a *library's*.
- **Release-automation ecosystem, relevant to "Next steps" item 3 (shared composite Action):**
  the two dominant patterns outside TwinCAT are `changesets` (explicit changeset files, PR-based,
  common in JS monorepos) and `semantic-release` (conventional-commit-driven, fully automatic
  version inference). This repo's `workflow_dispatch -f version=X.Y.Z` manual-trigger approach
  matches neither — consistent with the deliberate manual-deployment stance in "Rejected
  alternative" above. One unrelated gotcha reported by monorepo users: GitHub Actions won't
  trigger on a push of more than 3 tags at once
  ([changesets/changesets#1440](https://github.com/changesets/changesets/discussions/1440)) —
  irrelevant today since MONETcommon/BROTLib/HalfBROT tag independently in separate repos, but
  worth remembering if they're ever consolidated.

**Decision reversed 2026-09-16: renamed after all.** Initially decided against this (see the
original reasoning preserved by git history) on the grounds that the only remaining case was
convention-matching, not correctness, since the collision concern had tested negative. A follow-up
scratch test (see "Tested: renaming..." below) then showed the rename isn't just idiom-matching —
it merges custom libraries into the compiler's own `Global_Version` symbol, a genuine
discoverability improvement. That changed the cost/benefit enough to go ahead: renamed
`GVL_Version`/`stVersion` to `Global_Version`/`stLibVersion_<LibraryName>` across all 8 repos the
same day (mechanical: GVL file + internal `Name=` attribute + constant name, each `.plcproj`'s
`Compile Include`, each `release.yml`'s `sed` target). Not yet re-verified against real hardware
under the new names — the only live ADS confirmation on record (MONET/S, in Status below) predates
this rename and used the old `GVL_Version.stVersion` path.

## Release automation

`.github/workflows/release.yml` (MONETcommon only so far) — `workflow_dispatch` with a `version`
input:

```bash
gh workflow run release.yml -R BROTLib/MONETcommon -f version=0.3.2
```

Steps: validates `version` is `Major.Minor.Patch`; bumps `<ProjectVersion>` and every
`Global_Version.TcGVL` field together via `sed`; commits to `develop`; fast-forwards `main`; tags
`vMajor.Minor.Patch`. No `TcBuild`/build step involved — this workflow only touches source text
in git, on GitHub-hosted `ubuntu-latest` runners, deliberately independent of the (still
unfinished, self-hosted, Windows-only) TwinCAT build pipeline described in
[2026-09-15-twincat-ci-investigation.md](../plans/2026-09-15-twincat-ci-investigation.md).
Now live in all 8 repos, each with its own `stLibVersion_<LibraryName>` constant name substituted
in (the `sed` targets on the numeric/string fields are identical across repos; only the `$GVL`
path and the surrounding constant name inside the file differ per repo).

Known limitations of the workflow, not yet addressed:
- No check that the new version is actually higher than the current one — a typo'd downgrade
  would go through silently.
- Branch names (`develop`/`main`) and file paths are hardcoded for MONETcommon's layout; not yet
  generalized for reuse on BROTLib/HalfBROT.
- Relies on `contents: write` + no branch protection on `main`/`develop` (confirmed both
  unprotected on MONETcommon 2026-09-16); would need a token with bypass permission if protection
  is ever added.

**Built a shared/reusable GitHub Action for this: still not done, and now less clearly right.**
The pattern was replicated to all seven remaining repos by copy-pasting the same workflow file
with per-repo path substitutions (see Status below) rather than factoring out a composite action
first. In hindsight this was the correct order — copying it eight times surfaced real per-repo
differences (missing `<ProjectVersion>` entirely on IAG50cm/MONETN, a 2-segment `0.1` on MONETS,
an already-existing `tcbuild-test.yml` on BROTLib to not clobber) that a premature shared action
would have had to abstract over blindly. Extracting one now is a reasonable next step, but no
longer urgent — the duplication is proven-working, not hypothetical.

## What "install on prod" actually requires

Distinct from building/tagging a release. Once a library artifact exists (see next section),
getting a new version onto a live telescope controller is four separate steps, not one:

1. Install the library's `.library` file into the **engineering PC's** TwinCAT library
   repository (`C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries\<Company>\<Name>\<version>\`)
   — the machine used to build the *consuming* project (e.g. `BECKY` for IAG50cm), not the
   controller itself.
2. Update the consuming project's `PlaceholderResolution` (e.g. whatever actually references
   MONETcommon) to pin the new version — a project-level setting, separate from the library.
3. Rebuild the consuming project against that resolution — produces a new boot project, the same
   mechanism already validated with `TcBuild build` in the CI investigation.
4. Download and activate that boot project on the live CX controller.

Step 4 is a deliberate online change (or restart) to a live telescope's motion/safety control
code. This should stay a manual, supervised action regardless of how far CI automation goes for
steps 1–3 — nobody has proposed, and this design does not propose, automatically deploying to
live hardware.

## Status (2026-09-16)

- `Global_Version.TcGVL` + `release.yml` implemented in **all 8 repos**: BROTLib, MONETcommon,
  HalfBROT, AstroBROT, IAG50cm, MONETN, MONETS, MONETRoof.
- MONETcommon: `v0.3.1` cut manually to validate the pattern, `v0.3.2` cut via `release.yml`
  end-to-end — both under the **old** `GVL_Version`/`stVersion` naming, before the rename.
- **Live ADS re-verified under the new (renamed) path on the real MONET/S controller
  (identifier kept in IAG's private specs), 2026-09-16.** After the rename, rebuilding `MONETS.sln` against the renamed
  MONETcommon hit a real, previously-latent build error unrelated to the rename itself: MONETSRuntime
  is an application project, not a library, so its own hand-authored version constant is never
  referenced internally (it exists to be read externally via ADS) — this project treats SA0033
  (unused variable) as a hard compile error, and this had never actually been build-tested since
  the custom-version-GVL pattern was first added to MONETSRuntime. Fixed with the standard TwinCAT
  suppression pragma, `{attribute 'analysis' := '-33'}`, which only silences the static-analysis
  complaint — the pre-existing `LinkAlways="true"` on the `Compile Include` entry is what actually
  guarantees the constant survives into the downloadable boot project and stays ADS-readable
  regardless. Fix committed to MONETS (`770bc62`, `develop` and `main`). `MONETcommon` `0.3.2`
  rebuilt/reinstalled, `MONETS` rebuilt against it and downloaded to the live controller, then read
  back with IAG's private `tools/Ads-Query.ps1` `Expand-AdsStruct` helper — now returning
  **both** the library's and the application's own version, merged into the same struct as every
  genuine Beckhoff entry:
  ```
  Global_Version.stLibVersion_MONETcommon   -> iMajor=0, iMinor=3, iBuild=2, iRevision=0, nFlags=1, sVersion=0.3.2
  Global_Version.stLibVersion_MONETSRuntime -> iMajor=0, iMinor=1, iBuild=0, iRevision=0, nFlags=1, sVersion=0.1.0
  ```
  Matches exactly. The rename is now confirmed end-to-end on real hardware, not just via scratch
  builds — this closes the "not yet re-verified" gap this section previously flagged.
- `TcBuild install` (the "save as library" command, distinct from `TcBuild build`'s in-place
  compile) **is validated**: a real `MONETcommon.library` (363,700 bytes) was built on the MONET/S
  dev machine at the exact `v0.3.2` tagged commit and attached to that GitHub Release — see "First
  compiled MONETcommon.library attached to a GitHub Release" in
  [2026-09-15-twincat-ci-investigation.md](../plans/2026-09-15-twincat-ci-investigation.md)
  for the exact command. Still a **manual one-off**, not part of `release.yml` — that workflow runs
  on plain `ubuntu-latest`, which can't run TcBuild at all, so wiring this into every version bump
  needs a TwinCAT-capable runner added to the release flow.
- Found and fixed in passing, unrelated to this design: MONETS's `MONETSRuntime.plcproj` had
  `<Name>MONETNRuntime</Name>` (a copy-paste artifact from MONETN) — corrected to
  `<Name>MONETSRuntime</Name>`. Also removed two orphaned pre-rename files from MONETN
  (`MONET.tsproj`, `MONETRuntime.plcproj`) not referenced by `MONETN.sln`.

## Currently installed on MONET/S (2026-09-16)

Full live snapshot, read directly off the real MONET/S controller (identifier kept in IAG's
private specs) via IAG's private `tools/Ads-Query.ps1` `Expand-AdsStruct -InstancePath "Global_Version"`,
after building AstroBROT, BROTLib, HalfBROT, and MONETcommon from current `main` and rebuilding/
downloading `MONETS` against them:

| Library/Application | Live version | Symbol |
|---|---|---|
| AstroBROT | 0.3.0 | `Global_Version.stLibVersion_AstroBROT` |
| BROTLib | 0.4.2 | `Global_Version.stLibVersion_BROTLib` |
| HalfBROT | 0.4.0 | `Global_Version.stLibVersion_HalfBROT` |
| MONETcommon | 0.3.2 | `Global_Version.stLibVersion_MONETcommon` |
| MONETSRuntime (the application itself) | 0.1.0 | `Global_Version.stLibVersion_MONETSRuntime` |

All five sit merged into the same `Global_Version` struct as the Beckhoff `Tc2_*`/`Tc3_*` entries —
this is the first time the full transitive chain (`MONETSRuntime` → `MONETcommon` → `BROTLib` →
`AstroBROT`, plus `HalfBROT`) has been confirmed live at once, not just `MONETcommon` in isolation.
Every one of these version numbers matches that repo's `<ProjectVersion>`/latest git tag as of this
date — see the corresponding GitHub Release for each:
[AstroBROT v0.3.0](https://github.com/BROTLib/AstroBROT/releases/tag/v0.3.0),
[BROTLib v0.4.2](https://github.com/BROTLib/BROTLib/releases/tag/v0.4.2),
[HalfBROT v0.4.0](https://github.com/BROTLib/HalfBROT/releases/tag/v0.4.0),
[MONETcommon v0.3.2](https://github.com/BROTLib/MONETcommon/releases/tag/v0.3.2) — each release now
also carries a freshly-built `.library` artifact attached (`TcBuild install`, built from current
`main`, uploaded 2026-09-16). Note for AstroBROT/BROTLib/MONETcommon specifically: `main` has moved
past these tags (the `Global_Version` rename landed as a plain commit, no version bump), so the
attached `.library` reflects current `main`'s source, not exactly the tagged commit — an already-
accepted trade-off for ad hoc manual builds (see "Known gap, accepted" earlier in this doc).
MONETSRuntime (MONETS itself) has no separate release/tag scheme of its own to reference here.

## Next steps

1. ~~Build MONETcommon with TcBuild and confirm `GVL_Version.stVersion` reads correctly live via
   ADS against a real (or test) controller.~~ Done 2026-09-16 — see Status above. As a side
   effect, the full "install on prod" chain above has now genuinely been walked once for MONET/S
   (steps 1–4), though step 4 (the runner-in-`release.yml` automation) from this list is still
   open — step 5 below still needs that before it's unblocked.
2. ~~Replicate `GVL_Version.TcGVL` + `release.yml` to BROTLib and HalfBROT.~~ Done, and then some
   — replicated to all 8 repos, then renamed to `Global_Version`/`stLibVersion_<Name>` in all of
   them (see "Tested: renaming..." below). ~~Redo the MONET/S live-hardware ADS verification under
   the new symbol path.~~ Done 2026-09-16 — see Status above; also surfaced and fixed a real
   MONETSRuntime build-blocking bug (SA0033) along the way, unrelated to the rename itself.
3. Once duplicated three times, consider extracting the common release-workflow logic into a
   shared composite GitHub Action. Still not done (all 8 are separate copy-pasted workflow files);
   no longer urgent, per the note under "Release automation" above.
4. ~~Validate `TcBuild install`~~ Done (manual one-off, see Status above). Remaining: add a
   TwinCAT-capable runner to `release.yml` (or a follow-on workflow it triggers) so the build +
   `gh release upload` happens automatically on every version bump, not by hand each time. **This
   is not just a config change** — it depends on the still-unresolved self-hosted-runner CI
   investigation
   ([2026-09-15-twincat-ci-investigation.md](../plans/2026-09-15-twincat-ci-investigation.md)):
   there is no trustworthy Windows XAE CI runner yet. The existing one is an explicitly disposable
   test rig (hasn't survived an RDP-disconnect test, no runner registered on MONETcommon/HalfBROT
   at all), and everything built/deployed so far — including the real MONET/S deployment in the
   Status section above — was done by hand on the MONET/S dev machine, not through CI. Don't read
   that manual success as CI readiness.
5. Only after 1–4: write up the actual prod-install runbook (steps 1–3 of "install on prod"
   above) as a `specs/steering/` doc once it's been done for real at least once — not before, per
   this repo's own steering-doc convention (real recurring convention only, not speculative
   content).

## Resolved: `GlobalVersionStructureIncluded` is not the gate (tested 2026-09-16)

Every `.plcproj` checked across BROTLib, MONETcommon, AstroBROT, HalfBROT, MONETN, MONETS, and
MONETRoof has a `<GlobalVersionStructureIncluded>false</GlobalVersionStructureIncluded>` property
— still undocumented (no Beckhoff infosys page found for it) — and it was an open question whether
flipping it to `true` on a custom library would make it start appearing in a consumer's
`Global_Version`, untestable without real TwinCAT XAE access.

**Tested directly, with real XAE + TcBuild access on the MONET/S dev machine:**
1. Baseline: `BROTLib.tmc`'s `Global_Version` contains `stLibVersion_*` for exactly the 12
   Beckhoff libraries BROTLib references (`Tc2_Math`, `Tc2_MC2`, `Tc2_NC`, `Tc2_Standard`,
   `Tc2_System`, `Tc2_Utilities`, `Tc3_DynamicMemory`, `Tc3_EventLogger`, `Tc3_IotBase`,
   `Tc3_IotCommunicator`, `Tc3_JsonXml`, `Tc3_Module`) — no `stLibVersion_AstroBROT`, confirming
   the problem statement above.
2. Set `AstroBROT.plcproj`'s `GlobalVersionStructureIncluded` to `true`.
3. `TcBuild install AstroBROT.sln -x AstroBROT -p AstroBROT` — rebuilt and reinstalled AstroBROT
   as a library with the flag flipped (exit 0).
4. `TcBuild build BROTLib.sln` — rebuilt BROTLib against that new AstroBROT build (exit 0).
5. Re-checked `BROTLib.tmc`: **identical 12 `stLibVersion_*` entries, no `stLibVersion_AstroBROT`
   — no change at all.**

So the flag does nothing observable here, at least via this mechanism (a `.plcproj` property on
the *dependency*, checked in the *consumer's* compiled output). Confirms the "doesn't hold up
against BROTLib's own `.tmc`" reasoning above was right — `false` doesn't suppress
`Global_Version` generation, and `true` on the custom library doesn't add it either. Whatever
actually gates the Beckhoff-vs-custom distinction, it isn't this property. Reverted AstroBROT's
`.plcproj` back to `false` afterward (this was a scratch test, not an intended change).

Given this negative result, `GVL_Version.TcGVL`'s hand-authored approach remains necessary — there
isn't a simpler built-in toggle that solves the "does the compiler have a version" problem for
custom libraries.

## Resolved: identical `GVL_Version`/`stVersion` names across referenced libraries do not collide (tested 2026-09-16)

After the hand-authored `GVL_Version.TcGVL` pattern above was rolled out to 8 repos (BROTLib,
MONETcommon, AstroBROT, HalfBROT, MONETN, MONETS, MONETRoof, plus this one's own release
automation), a concern was raised: every rollout used the exact same GVL name (`GVL_Version`) and
the exact same field name (`stVersion`). Since some of these libraries reference each other
(MONETcommon → BROTLib → AstroBROT; HalfBROT → BROTLib), and Beckhoff's own convention avoids this
by suffixing with the library name (`stLibVersion_<Name>`), the worry was that linking two such
libraries into the same project could produce a duplicate-global-symbol compile error.

**Tested directly, with real XAE + TcBuild access on the MONET/S dev machine:**
1. Confirmed both `BROTLib.plcproj`'s and `AstroBROT.plcproj`'s `GVL_Version.TcGVL` (BROTLib
   references AstroBROT as a library) declare a GVL literally named `GVL_Version` with a field
   literally named `stVersion` — an exact, deliberate match to reproduce the feared collision.
2. `TcBuild build BROTLib.sln` — rebuilt BROTLib (which references AstroBROT) with both GVLs
   present under the identical name.
3. Result: **exit 0, clean build, no duplicate-symbol error** — reproduced twice for stability
   (the first of three attempts returned exit 1 with only the routine visualization-profile
   warning and no error text, consistent with this repo's known "stray/orphaned TcXaeShell
   process" false-negative gotcha rather than a real failure; two subsequent clean re-runs both
   returned exit 0).

**Conclusion: the collision is not real.** TwinCAT scopes a referenced library's global variables
within that library's own namespace rather than merging them into one flat project-wide symbol
table, so two libraries can each declare a `GVL_Version` GVL with a `stVersion` field without
conflict — unlike, say, two POUs or two project-level GVLs sharing a name, which would collide.
This is also consistent with `GVL_Version.TcGVL` declaring `{attribute 'qualified_only'}`: access
must always be qualified by the declaring library's own resolution, so `GVL_Version.stVersion`
unqualified is never ambiguous between BROTLib's and AstroBROT's copies — there was never a shared
namespace for them to collide in.

No rename across the 8 repos is needed. The existing `GVL_Version`/`stVersion` naming can stay as
rolled out.

## Tested: renaming to Beckhoff's own `Global_Version`/`stLibVersion_<Name>` convention (2026-09-16)

Separately from the collision question above, we considered actually adopting Beckhoff's naming
outright — `Global_Version.TcGVL` with a `stLibVersion_<LibraryName>` constant instead of our own
`GVL_Version.TcGVL`/`stVersion` — since every project already has a compiler-auto-generated GVL
literally named `Global_Version` (containing `stLibVersion_Tc2_Math` etc. for Beckhoff references).
Renaming our hand-authored GVL to that same name risked colliding with, or being silently discarded
by, the compiler's own reserved usage of it.

**Tested directly on a scratch copy of AstroBROT (not committed), with real XAE + TcBuild access:**
1. Copied `AstroBROT/GVLs/GVL_Version.TcGVL` to `Global_Version.TcGVL`, renamed the constant inside
   from `stVersion` to `stLibVersion_AstroBROT`, updated the `Compile Include` path in
   `AstroBROT.plcproj` to match.
2. `TcBuild install AstroBROT.sln -x AstroBROT -p AstroBROT` — **exit 0, clean, no warning about a
   duplicate/conflicting `Global_Version` symbol**, even when captured with full stdout/stderr
   redirection (nothing printed beyond the routine visualization-profile line).
3. Inspected the resulting `AstroBROT.tmc`: **our custom entry does not appear there at all** —
   only the 5 Beckhoff-library `stLibVersion_*` entries AstroBROT itself references. Initially read
   as silent shadowing, but this turns out to be expected, not a bug: a library's own `Global_Version`
   only ever lists the libraries *it* references, never an entry about itself (the same reason
   BROTLib's own `.tmc` has never had a `stLibVersion_BROTLib`).
4. Rebuilt the consumer, `TcBuild build BROTLib.sln` (which references AstroBROT as a library) —
   exit 0, clean. Inspected `BROTLib.tmc`: now contains **13** `stLibVersion_*` entries, the usual
   12 Beckhoff ones plus a new `stLibVersion_AstroBROT` — populated with our exact hand-authored
   values (`iMajor=0, iMinor=3, iBuild=0, iRevision=0, nFlags=1, sVersion='0.3.0'`) and even our
   exact source comment text, merged in as a normal `ST_LibVersion` entry indistinguishable in
   structure from a genuine Beckhoff one. Verified no duplicate symbol names anywhere (each of the
   13 appears exactly once).
5. Reverted the scratch `.plcproj` edit and deleted the scratch `Global_Version.TcGVL`, then
   reinstalled AstroBROT from its real committed `GVL_Version.TcGVL` and rebuilt BROTLib against
   that, confirming `BROTLib.tmc` is back to the original 12-entry baseline with no `AstroBROT`
   entry — scratch test fully undone, nothing committed.

**Conclusion: the rename to `Global_Version`/`stLibVersion_<Name>` is safe and works exactly as
intended** — it doesn't collide with or get overwritten by the compiler's own auto-generated
`Global_Version`; instead it merges into the *same* symbol, giving our custom libraries genuine
first-class visibility in a consumer's `Global_Version` alongside real Beckhoff libraries (rather
than a separate, differently-named GVL a consumer has to know to look for specially). This is
strictly better discoverability than the current `GVL_Version`/`stVersion` pattern, at the cost of
a rename across the 8 repos (mechanical: GVL file rename, constant rename to include the specific
library's name, update each `.plcproj`'s `Compile Include`, update `release.yml`'s `sed` targets).
Not yet decided whether to actually do this — this test only established that it's safe to do, per
the original ask.
