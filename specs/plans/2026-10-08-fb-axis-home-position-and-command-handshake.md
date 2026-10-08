# FB_Axis: mandatory homing reference and command methods

**Status: proposed (2026-10-08).** Nothing implemented. Design:
[fb-axis-command-interface.md](../design/fb-axis-command-interface.md). Breaking changes accepted, all repos are
updated together (decision 2026-10-08). Issues: BROTLib #62 (homing reference), #63 (command flags);
HalfBROT #46, IAG50cm #21 (migration); IAG50cm #20 (focus reference decision).

Repos: BROTLib, HalfBROT, IAG50cm (code); MONETcommon, MONETS, MONETN (rebuild and telescope checks only).

## Decisions needed before step 2

- [ ] **IAG50cm focus reference** (design A): `telescopeConfig.focusHome`, a persistent last known position, or a
      reference switch. Until decided the migration keeps today's behaviour (`fPosition`) with a TODO.
- [ ] **B2 or B1** for the command flags: the design recommends B2 (command methods). Confirm.

## Steps

1. **Check the facts the design relies on** (no code):
   - [ ] `VAR_IN_OUT CONSTANT` on an FB and on a method builds with the TwinCAT version on the engineering PCs and
         the runner, and an omitted assignment is a compile error (small probe project; Tim runs it in XAE, or a
         branch build on the runner).
   - [ ] Re-grep all repos for direct writes to `fbAxis.MoveAxis`/`HomeAxis`/`StopAxis`/`Jog_*` outside the call
         and for other `FB_Axis` instances (2026-10-08: none, seven call sites, see the design).

2. **BROTLib** (branch `feature/fb-axis-command-methods`, PR to `develop`, not merged before step 3 is ready):
   - [ ] `FB_Axis`: `Move`, `Home(fReference)` (`VAR_IN_OUT CONSTANT`), `Stop` methods latching a request; the body
         turns requests into rising `Execute`s and clears them on done/error; command `VAR_INPUT`s removed except
         the jog levels; `Axis_Home.Position := ` the stored reference. Remove the "do not change without migrating
         callers" note.
   - [ ] `FB_BaseAxis`: adapt to the new `FB_Axis` (it holds `fbAxis`); `I_Axis`/`I_BaseAxis` unchanged.
   - [ ] TcUnit: the request/edge/clear logic in a pure function or a small FB, like `F_SetpointEnableExecute`
         (#61), so it is tested without an NC axis: request -> one rising edge; done clears; error clears and does
         not retry; `Home` keeps its reference.
   - [ ] README and `specs/design/fb-axis-command-interface.md` status.

3. **HalfBROT** (branch with the same name): azimuth, elevation, derotator, focus call `fbAxis.Move/Home/Stop`
   from the `I_Axis` setters and their own logic; drop `bMoveAxis`/`bHomeAxis`/`bStopAxis` bookkeeping; references
   per the design table (`fCalibPosition`; focus `SEL(fLastPposition > 0.0, fHomingPosition, fLastPposition)`).
   CI: build against the BROTLib branch (install it on the runner first, see below).

4. **IAG50cm** (same branch name): hour angle, declination (`Home` never called; homing stays `FB_LatchHome`),
   focus (`Home(<decision from above>)`); move from `BROTLib, 0.5.5` to the new version. Also takes BROTLib 0.6.x's
   changes (RA telemetry in degrees, timestamped retained lines): deploy the 50 cm PLC together with consumers that
   expect degrees (pybrotlib >= 1.5.0 without `ra_in_hours`).

5. **Merge and release together**, in this order, without other BROTLib merges in between:
   - [ ] BROTLib PR merged, immediately HalfBROT PR (CI on HalfBROT `develop` breaks in between, because the
         runner's test job installs BROTLib `develop` and HalfBROT resolves `BROTLib, *`).
   - [ ] MONETcommon, MONETS, MONETN: rebuild on CI against the new BROTLib and HalfBROT (no code change expected;
         MONETcommon only uses `I_Axis`).
   - [ ] Releases: BROTLib 0.7.0, HalfBROT next minor, MONETcommon (rebuild), IAG50cm, MONETS, MONETN.

6. **Telescope checks** (each telescope, after deploying):
   - [ ] Homing on every axis that homes: same calibrated position as before (compare `ActualPosition` after homing
         with the value before the update).
   - [ ] Move, stop and jog (pendant) on every axis; stop during a move; re-home on an already homed axis
         (IAG50cm focus, the 2026-10-06 re-home check).
   - [ ] An axis error during a move: the move ends with `Error`, a new `Move` after `Reset` works.

## CI note

Steps 2-4 live on branches. To build HalfBROT's and IAG50cm's branches against BROTLib's branch, the runner needs
that BROTLib installed: run BROTLib's `tests.yml` on the branch (it installs the checked-out BROTLib), then
HalfBROT's/IAG50cm's builds. That also leaves the branch version installed on the runner until the next BROTLib
test run, so do not run other repos' CI in between.

## Issues

- [BROTLib #62](https://github.com/BROTLib/BROTLib/issues/62): mandatory homing reference (design A)
- [BROTLib #63](https://github.com/BROTLib/BROTLib/issues/63): command flags written by both sides (design B)
- [HalfBROT #46](https://github.com/BROTLib/HalfBROT/issues/46): migrate the four axis blocks
- [IAG50cm #21](https://github.com/BROTLib/IAG50cm/issues/21): migrate the three axis blocks, move to the new BROTLib
- [IAG50cm #20](https://github.com/BROTLib/IAG50cm/issues/20): focus homing reference decision
