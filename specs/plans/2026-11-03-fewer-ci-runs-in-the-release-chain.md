# Fewer CI runs in the release chain (BROTLib -> ... -> MONETS/MONETN/IAG50cm)

**Status: proposed, nothing changed.** Facts read on 2026-11-03 from the local checkouts of BROTLib, AstroBROT, HalfBROT,
MONETRoof, MONETcommon, MONETS, MONETN and IAG50cm (`.github/workflows/*.yml`, `tools/Find-TestedTree.ps1`,
`tools/Install-PinnedLibraries.ps1`, the `.plcproj` pins). The local checkouts are not all at `origin/develop`, so the pin
versions below are a snapshot, not the current state. The run counts are derived from the workflow files, not measured on the
Actions history. Repos: BROTLib, AstroBROT, HalfBROT, MONETRoof, MONETcommon, MONETS, MONETN, IAG50cm (private). Related:
`specs/design/twincat-ci-runner-setup.md`, IAG `specs/plans/2026-09-20-brotlib-github-settings-and-runner-audit.md` (private),
HalfBROT#136/#137 (the release that made the cost visible).

Goal: remove every run on the single self-hosted runner that adds no information. Pins stay exact (TwinCAT has no "at least";
`*` is "newest installed", which `Install-PinnedLibraries.ps1` deliberately avoids for the org libraries). The pin PR stays the
integration test of each consumer.

## 1. The chain

Org-library pins found in the `.plcproj` files (snapshot of the local checkouts; versions differ between repos, which is itself a
sign the manual pin rounds drift):

| Repo | Kind | Pins (org libraries) | Runner work per push / per release |
|---|---|---|---|
| BROTLib | library + TcUnit | AstroBROT (tests) | build+tests / library |
| AstroBROT | library + TcUnit | none | build+tests / library |
| HalfBROT | library, no tests | BROTLib | build / library |
| MONETRoof | library + TcUnit | BROTLib | build+tests / library |
| MONETcommon | library + TcUnit | AstroBROT, BROTLib, HalfBROT | build+tests / library |
| MONETS, MONETN | application, no tests | AstroBROT, BROTLib, HalfBROT, MONETRoof, MONETcommon | build / none (no `release-library.yml`) |
| IAG50cm | application + offline TcUnit (private) | BROTLib (main project); BROTLib, AstroBROT (test project) | build+tests / none |

Order (a pin PR needs the upstream **release asset**, `Install-PinnedLibraries.ps1` downloads `v<version>`):
BROTLib, AstroBROT -> HalfBROT, MONETRoof -> MONETcommon -> MONETS, MONETN; IAG50cm after BROTLib/AstroBROT.

## 2. What a release costs today

The `release.yml`, `tag-release.yml` and `tcbuild.yml` of the eight repos are the same file modulo the project paths and the test
step (diffed 2026-11-03). BROTLib's `release.yml` additionally skips the bump commit when `develop` already carries the version.
R = a run that occupies the runner for a real XAE build; "light" = checkout plus `Find-TestedTree`, seconds.

| Step | Trigger | Runner cost |
|---|---|---|
| Work branch / pin PR push | `tcbuild.yml` on `push` | **R per push** (HalfBROT/MONETS/MONETN cancel the older run, the TcUnit repos queue) |
| Merge into `develop` or `main` | `push` | light: `Find-TestedTree` finds the tested tree (`tests-passed` / `build-passed` status), build and tests skipped |
| `release.yml` bump commit | `gh workflow run tcbuild.yml --ref develop` (a `workflow_dispatch` run is **never** skipped) | **R**, with the TcUnit suites in the four test repos |
| `tag-release.yml` | ubuntu, dispatches `release-library.yml` | none |
| `release-library.yml` (BROTLib, AstroBROT, HalfBROT, MONETRoof, MONETcommon) | `workflow_dispatch` | **R** (library build, needed: it makes the `.library` asset) |

Cost of one BROTLib release **wave** (BROTLib released, every consumer moved to it and released), without the PR that holds the
change itself: BROTLib 2 R (bump, library) + HalfBROT 3 (pin PR, bump, library) + MONETRoof 3 + MONETcommon 3 + MONETS 2
(pin PR, bump) + MONETN 2 + IAG50cm 2 = **17 R**, plus 1 R per fix-up push on any PR branch. Jobs run one after the other on one
runner, so the wave is the sum.

## 3. Findings

1. **The bump-commit build is redundant.** `release.yml` changes only `ProjectVersion` and the four `Global_Version` constants on
   top of a `develop` head that already carries the `build-passed`/`tests-passed` status. The dispatched run rebuilds it (and
   re-runs the TcUnit suites) only to put a `build` status on the bump commit so the release PR is not blocked (IAG#6). For the
   five library repos `release-library.yml` compiles the same tree again from the tag. BROTLib's "version already on develop"
   case has the same redundancy: no bump commit, but the dispatch still builds the unchanged, tested tree.
2. **The same-tree skip already works** for merges; it is not the problem. It does not apply to a `workflow_dispatch` run by design,
   which is exactly finding 1.
3. **There is no pin automation.** `ci/pin-brotlib_0.16.0` (HalfBROT#134) was made by hand; nothing edits `DefaultResolution` in a
   consumer. A consumer's pin round also has no fixed order, so a consumer is often pinned several times (one per upstream release)
   instead of once per wave.
4. **The application repos need no release per pin bump.** MONETS/MONETN/IAG50cm release for deployment; the pin PR alone already
   tests the new library. After change 4.1 a release there costs no run anyway.

## 4. Changes

### 4.1 The bump commit gets its `build` status without a run (saves 1 R per release in every repo)

In each `release.yml`, replace the `Start CI on the bump commit` step by one that:

1. Reads the statuses of the pre-bump `develop` head: requires a `success` status `build-passed` (HalfBROT, MONETS, MONETN) or
   `tests-passed` (the TcUnit repos; `Find-TestedTree`'s two contexts). `tests-passed` is posted only when the tests really ran,
   so a head built while the license or runtime was down does **not** qualify and the old dispatch path runs instead.
2. Checks that the bump commit (if there is one) changes only the version files (`git diff --name-only`). BROTLib's
   "already on develop" case: no bump commit, the head itself must carry the status.
3. If both hold, posts the commit statuses `build` (success, "version bump of a tested tree, no rebuild") and the proof status on
   the bump commit with `gh api repos/.../statuses/<sha>`, so the later `Find-TestedTree` on the merge to `main` still skips.
   Otherwise falls back to `gh workflow run tcbuild.yml --ref develop`.

`release.yml` needs `statuses: write`. The library is still compiled once from the tag by `release-library.yml`, which is the real
check of the released artifact; a compile problem there fails the release before anybody pins it. The application repos have no
such second compile, but the bump changes no code, and the last pin PR built the identical tree.

Open check (look at `IAG tools/github-rulesets.sh`, private): the required check on `main` is named `build` and today satisfied by
a commit status (tcbuild posts `build` as a status for the dispatched run). If the ruleset demands an Actions check run from a
specific app, the status route does not satisfy it and 4.1 needs a tiny ubuntu job that exposes `build` instead.

### 4.2 Pin PR automation, in wave order

A `pin-consumers.yml` in each library repo (trigger: `workflow_dispatch`, later `workflow_run` of `Release library` on `main`):

- Opens `ci/pin-<lib>-<ver>` in each consumer of section 1 and edits the `DefaultResolution` of that library in **all** plcproj
  files of the consumer (library project and test project; `*` stays). It **dispatches `tcbuild.yml` on the branch** (a push with
  `GITHUB_TOKEN` starts no workflow) and reports `build` like `release.yml` does.
- A consumer's PR bumps **all** upstream libraries to what its already released upstream consumer pinned, read from the tagged
  plcproj files (MONETS/MONETN take the HalfBROT, BROTLib and AstroBROT pins of the new MONETcommon release), so the consumers
  cannot end up with mixed versions and a wave needs one pin PR per consumer, not one per upstream release.
- Needs a token that can push branches and open PRs in the other repos (fine-grained PAT or GitHub App secret, the kind of
  `TCTOOL_TOKEN`); the default `GITHUB_TOKEN` cannot cross repos.

### 4.3 Batching (decides when 4.2 fires)

- The pin PRs wait for the `release-batch` label on the upstream release PR (or a manual dispatch), so several fixes ride in one
  wave.
- MONETS, MONETN and IAG50cm: merge the pin PR, **cut a release only when a version goes to the telescope**.
- Wave order is enforced by the workflow (a consumer's PR is created only when every upstream it pins has its release asset).
  Example HalfBROT#136: HalfBROT 0.11.0 + the `FB_HomeRequest_Tests` suite in one MONETcommon PR, one MONETcommon release, one pin
  PR each in MONETS/MONETN.

### 4.4 Smaller items (after 4.1 and 4.2 are measured)

- A cheap ubuntu `plan` job that runs the `Find-TestedTree` logic through the API and an `if:` on the self-hosted job, so a merge to
  `develop`/`main` never takes a runner slot. Check that a skipped job still satisfies the required `build` check first.
- `cancel-in-progress: false` stays in the TcUnit repos (a killed test run leaves a stray TcXaeShell).
- Fewer fix-up pushes on PR branches (squash locally, one `git push`); with Auto-fix on, every CI-fix push is an R.
- Fix the pin drift when the automation first runs (for example IAG50cm's test project pins BROTLib 0.15.1 while its main project
  pins 0.16.0; MONETRoof pins 0.15.0 and 0.16.0): the first wave aligns all of them.

## 5. Result (wave from a BROTLib release, same counting as section 2)

| | today | with 4.1 |
|---|---|---|
| BROTLib | 2 R | 1 |
| HalfBROT | 3 | 2 |
| MONETRoof | 3 | 2 |
| MONETcommon | 3 | 2 |
| MONETS | 2 | 1 |
| MONETN | 2 | 1 |
| IAG50cm | 2 | 1 |
| **Wave** | **17 R** | **10 R** |

With 4.2/4.3 the 10 R need no manual pin edits and no repeated pin rounds. The application repos' releases (deferred, 4.3) cost no
run. A wave that starts in HalfBROT (as #136: HalfBROT release, MONETcommon pin/test PR and release, MONETS, MONETN) is 9 R today and
5 R after 4.1 (without the PR of the change itself). Measure on the first real wave with
`gh run list --workflow tcbuild.yml --json createdAt,updatedAt,headSha`.

## 6. Order and risks

1. **4.1 first**: largest saving, a small, identical change in eight files. Try it on MONETN or MONETS (a release costs only the
   bump build there), then the library repos, BROTLib's variant last (it has the "already on develop" branch).
2. **4.2** after 4.1, manual dispatch only; turn on the `workflow_run` trigger after one clean wave.
3. **4.3** is a process decision (labels, when to release an application repo), no code beyond 4.2.

Risks: (a) a version-only commit that is not really version-only (guarded by the file-list check in 4.1.2); (b) a cross-repo
token with write access is a new org secret (scope it to the eight repos, pull requests and contents only); (c) `workflow_run`
workflows must not run with that secret for fork events: trigger only on `Release library` of the same repo and branch `main`;
(d) IAG50cm is private and needs `actions: read` for `Find-TestedTree` (already set there), the other repos are public;
(e) any workflow change here can only be tested by running it, which means runs on the CI runner: every test release needs the
owner's go-ahead.
