# FB_Axis re-home fix: PLC check and the 0.5.5 release (handover)

**Status: checked on the IAG50cm PLC (2026-10-06, see "Result"); release 0.5.5 still to do.** The code change is on `develop` (`6dabd5a`) but unreleased.
This is a handover: everything below is what the next person (or session) needs to finish it.

Repos: BROTLib (the change), HalfBROT / MONETcommon / MONETN / MONETS / IAG50cm (consumers).
Date: 2026-10-06.

## What changed

`FB_Axis.TcPOU`, the homing block near the end of the cycle. Before:

```st
IF Axis_Status.Status.Homed THEN
	Calibrated := TRUE;
	HomeDone := TRUE;
	HomeAxis := FALSE;
```

After: `HomeAxis := FALSE` only `IF NOT Axis_Home.Busy`. Reason: on an axis that is already homed, a new
`HomeAxis` request was cleared in the same cycle `Axis_Home.Execute` went TRUE, so the re-home was dropped
after one cycle. The commit also adds comments (no behaviour change) for two things that look like bugs
but are relied on:

- `HomeDone` is a level (TRUE while homed), not a pulse. IAG50cm's `FB_HourAngleControl` /
  `FB_DeclinationControl` combine it with `FB_LatchHome.Done`.
- The homing reference position is the `Position` input (also the move target). HalfBROT's axes and the
  IAG50cm focus axis set `Position` to the calibration position before homing.

## What is not known (why this needs a PLC)

1. Whether `MC_Home.Busy` is TRUE in the same cycle as the rising `Execute`. The fix assumes it is. If it
   is only TRUE from the next cycle, `HomeAxis` is still cleared in the first cycle and the bug remains.
2. Whether `MC_Home` clears the NC `Homed` flag when it starts. If it does not, an already-homed axis shows
   `Homed` throughout, and the fix only matters for keeping the request alive, not for `Calibrated`.
3. The new `FB_Axis_Tests` suite (7 cases, no NC) has never run: this machine's user-mode runtime crashes
   on activation (see the 2026-09-22 note in the IAG fleet-open-items changelog), and TcBuild only compiles.
   It cannot test homing completion anyway.

## Check on a PLC

Needs a real NC axis and someone on site: **homing moves the axis.** Pick the least risky axis (the focus
axis is the likely candidate; confirm its `HomingMode` and travel first), keep the stop/E-stop within reach,
and do not run this on an axis under load or with the telescope in an unknown position.

Setup: an application that uses the new `FB_Axis` (any consumer rebuilt against the new library, see
"Release" below), online in XAE, `FB_Axis` instance watched (`HomeAxis`, `Calibrated`, `HomeDone`, `Ready`,
`Busy`, `Axis_Home.Busy`, `Axis_Home.Done`, `Axis_Status.Status.Homed`).

| # | Step | Expected with the fix | Without it (for comparison) |
|---|---|---|---|
| 1 | Axis enabled, never homed, set `HomeAxis` | `Axis_Home.Busy` TRUE, axis homes, `Homed` and `Calibrated` TRUE, `HomeAxis` cleared after done | same |
| 2 | Axis already homed, set `HomeAxis` again | `Axis_Home.Busy` TRUE for the homing duration, `HomeAxis` stays TRUE until done, axis moves to the home/reference sequence | `HomeAxis` cleared within one cycle, `Axis_Home` Execute lasts one cycle |
| 3 | Same, watch `Calibrated` during the re-home | note whether it drops (answers unknown 2) | |
| 4 | Set `HomeAxis` while `Ready` is FALSE (axis disabled) | request is kept or cleared; record which (current code clears it when `Homed`, keeps it when not) | |

Record the answers to unknowns 1 and 2 in this doc, in the issue, and fix the comment in `FB_Axis` if
`Busy` turns out to rise one cycle late (then the guard needs the `Execute` edge, not `Busy`).

IAG50cm's HA/Dec axes pass `HomeAxis := FALSE` and home through `FB_LatchHome`, so they do not exercise
this path at all; do not use them for this check.

## Result (2026-10-06, IAG50cm focus axis, CX-92B77E)

Run with a throwaway `FB_RehomeTest` (own `FB_Axis` on the focus `axisRef`, `focusControl` call commented out,
BROTLib built from `develop` as `0.5.4.99`), driven and read over ADS. `HomingMode := MC_ForceCalibration`
with `Position` = the current actual position, so the axis did not move (16.2999 before and after, no error).
Already-homed axis (step 2), one re-home request written to `HomeAxis`, trace per PLC cycle (index 0 = the
cycle of the request):

```
aExecute     111.....
aBusy        11......
aDone        ..1.....
aHomeAxis    11......
aHomed       1111111111...
aCalibrated  1111111111...
```

- Unknown 1: `MC_Home.Busy` is TRUE in the same cycle as the rising `Execute`. The `Busy` guard is correct and
  `HomeAxis` stays alive until `Busy` drops (the old code would have cleared it in cycle 0).
- Unknown 2: `MC_Home` does not clear the NC `Homed` flag when it starts; `Calibrated` stays TRUE throughout.
  On an already-homed axis the fix only keeps the request alive.
- Not covered: only `MC_ForceCalibration` (done in 2 cycles, no motion). A homing mode that moves has a longer
  `Busy` phase; same-cycle `Busy` should hold but was not shown. The old 0.5.4 behaviour was not run for
  comparison, and steps 1, 3 and 4 were not run.
- Also seen: `FB_FocusControl` only requests homing while `NOT Calibrated`, so the focus axis never re-homes
  through it; this path needs a caller that uses `FB_Axis.HomeAxis` directly.

## Release

BROTLib flow (see `.github/workflows/release.yml`): the version is bumped on `develop`, a PR to `main` is
opened, merging it triggers `tag-release.yml`, and `release-library.yml` (manual, input: the tag) builds the
`.library` on the runner and attaches it to the GitHub Release.

1. Actions -> **Cut release** on BROTLib, version `0.5.5`. Merge the PR it opens.
2. Run **Release library** with tag `v0.5.5`. Check the `.library` is attached.
3. Install it on the PLC machine (`IAG50cm/tools/Update-Libraries.ps1`, run elevated; see
   `IAG/specs/design/fleet-library-update-automation.md`).
4. Consumers:
   - `HalfBROT`, `MONETcommon`, `MONETN`, `MONETS` resolve `BROTLib, * (BROT)`, so they take whatever
     BROTLib is installed on the machine that builds them. Rebuilding MONETN/MONETS after installing 0.5.5
     is what puts the change on a telescope.
   - `IAG50cm` pins BROTLib (`0.5.4` in `IAG50cm.plcproj`). Bump the pin to `0.5.5` only if you want it
     there; its HA/Dec axes are unaffected by this change (see above), only its focus axis uses `HomeAxis`.
5. CI: `tcbuild.yml` runs on every push to every repo (builds only, no artifact). All eight were green on
   2026-10-06 with `develop` as of that day. The runner is the `Becky` desktop (`DESKTOP-5RB4PCR`); it
   shares the machine with your XAE, so a build can hit exit code 3 (COM busy) while XAE is busy, the
   workflow retries.

## Not part of this

The other open `FB_Axis` findings (modulo-wrap tracking, stale on-target feed velocity,
`Axis_SetpointDisable` missing from `Error`/`Busy`) and the BROTLib#9 items are in
[2026-09-23-fb-axis-latching-and-self-mutation-fixes.md](2026-09-23-fb-axis-latching-and-self-mutation-fixes.md).
The modulo-wrap one is pinned by `FB_Axis_Tests.IsTracking_Modulo_Wrap_Known_Limitation` and the test must
be flipped together with its fix. Do not bundle them into 0.5.5 unless the PLC check also covers them.

## Findings 5 and 6 re-checked (2026-10-06): no code change

- **Stale feed velocity on target: harmless today.** The behaviour comes verbatim from `FB_Axis3` (its history
  even has a no-op `TrackVelocityRef := TrackVelocityRef;` in that branch). The feed velocity is
  `Direction * TrackVelocity`, and the only callers that track (IAG50cm HA/Dec) pass `TrackDirectionRef := 0`,
  so on target `Direction = 0` and the fed velocity is 0 whatever `TrackVelocity` holds; HalfBROT leaves the
  default 0. The sidereal rate comes from the moving `Position`, not from the feed velocity. It only
  matters for a caller using `TrackDirectionRef <> 0`; there is none. Left as is.
- **`Axis_SetpointDisable` missing from `Error`/`ErrorID`/`Busy`: not changed, needs a PLC.** `Execute` is
  `NOT Tracking`, so the block fires once at startup on every axis that is not tracking, possibly before
  the axis is powered or the generator is enabled. If the NC answers that with an error, adding it to
  `Error` would raise a spurious error on every non-tracking axis (MONETN/MONETS/HalfBROT park on `bError`).
  Check what `Axis_SetpointDisable.Error`/`ErrorID` do at startup and when disabling an already-disabled
  generator during the on-site check above, then decide.
- **Modulo-wrap tracking: still open**, needs a decision on how to wrap (shortest way, +-180 deg) and a
  check of which axes are modulo; pinned by `IsTracking_Modulo_Wrap_Known_Limitation`.
