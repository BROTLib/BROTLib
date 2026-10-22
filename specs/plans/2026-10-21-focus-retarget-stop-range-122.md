# Focus: re-target while moving, `Stop()`, range check (MONETcommon#122)

**Status: implemented and released 2026-10-21; on-site re-test open.** The text below is the plan as proposed; what
was built and where it differs is in "Implementation" at the end. Base commits (at the time of the proposal): BROTLib `c42312e` (`develop`, "Merge
pull request #95", #93/#92 merged, `ProjectVersion` 0.9.0, last release v0.9.0), HalfBROT `60453e2` (develop, tag
v0.5.7), MONETcommon `d9d7a6c` (0.9.3), IAG50cm `2e09ab4`, MONETS `3f3e40d`, MONETN `da8fea5`. All consumers pin
`BROTLib, 0.9.0 (BROT)`, MONETcommon/MONETS/MONETN pin `HalfBROT, 0.5.7`. Related: HalfBROT#85 (focus hunting),
HalfBROT#66 (manual-mode position), HalfBROT#59 (hardware test incl. focus limit polarity), MONETcommon#118
(`SuspendAutomatic` does not stop moving axes), BROTLib#93/#92 (plan `2026-10-21-axis-stop-idempotent-93-92.md`,
implemented on `develop` in #95, not released).

Marking: **[verified]** = read in the code at the commits above on 2026-10-21; **[unverified]** = my reading of
TwinCAT NC / Tc2_MC2 behaviour or of the incident, to be confirmed by CI (TcUnit) or on MONET/S.

## Problem

MONET/S, 2026-10-21 (MONETcommon 0.9.2, BROTLib 0.9.0, HalfBROT 0.5.6), telescope online: `focus=30` works;
`focus=500` is accepted; the focus runs outward at ~0.4 mm/s; `focus=36` (TARGETPOS telemetry then shows 36.0) and
`stop=1` (`bStopped` TRUE) change nothing, MOTION_STATE 1, `IbLimitFar` FALSE; stopped only by disabling the drive
in XAE at 75.2 mm (NC 0x4260, emergency park). After a drive re-enable, `focus=36` worked again.

## Root causes [verified]

### 1. A new target during a move is ignored until the move ends

HalfBROT `HalfBROT/HalfBROT/POUs/FB_FocusControl.TcPOU`:

- Lines 91-97: in automatic mode, calibrated, off target and Ready, `IF NOT bMoveAxis THEN fbAxis.MoveTo(); END_IF
  bMoveAxis := TRUE;`. One `MoveTo()` per FALSE->TRUE of `bMoveAxis`.
- Lines 151-153: `bMoveAxis` is cleared **only** on `fbAxis.MoveDone`. Not on error, reset, abort or stop.
- BROTLib `FB_Axis.TcPOU` lines 208-226: `MC_MoveAbsolute` gets `Position` every call, but takes it only on the
  rising edge of `MoveCommand.Execute` (PLCopen) **[unverified for Tc2_MC2, standard behaviour]**. `MoveTo()` (lines
  364-373, comment line 366) already supports a re-target: "a MoveTo() while moving restarts with the new Position"
  (`FB_AxisCommand` holds `Execute` low for one cycle, then a new edge).
- Telemetry `TARGETPOS` is `THIS^.Position` = `fPosition` (line 389), the *requested* target, not the target of the
  running move. Hence "target 36.0 while moving away".

So `focus=36` would only have been taken after the move to the old target finished. The old target was 100 (see 3),
beyond the far limit switch, so it never finished: when `IbLimitFar` cuts `Enable_Positive` (line 141) the move ends
without `MoveDone` **[unverified: Error or just a halt]**, and `bMoveAxis` stays TRUE for good. IAG50cm
`FB_FocusControl` has the same one-shot (lines 22-36) but clears `bMoveAxis` also on `bReset OR bError` (lines 57-59).

Not explained by the code: how `focus=36` worked after the drive re-enable. `bMoveAxis` is not persistent and only
`MoveDone` clears it; a PLC restart/reset in between would explain it (open question 4).

### 2. Nobody stops the focus

- `I_Focus` (`BROTLib/BROTLib/Interfaces/I_Focus.TcIO` line 4) is `INTERFACE I_Focus EXTENDS I_BaseAxis` with no own
  members; `I_BaseAxis` has no `Stop` (only `Reset` as a method). `FB_BaseAxis` has no stop either.
- HalfBROT `FB_FocusControl` never calls `fbAxis.Stop()` or `CancelMove()` (whole file).
- MQTT `stop` (`FB_Comm_MQTT_Influx.TcPOU` lines 103-104) calls `Telescope.Stop()` only. MONETcommon
  `FB_MonetTelescopeControl.Stop` (lines 2126-2135) sets `bStop`; `_StopTelescope` (lines 1784-1826) stops tracking,
  moves and `StopAxis` of azimuth, elevation, derotator only. `fbFocus : I_Focus` (line 6) cannot be stopped through
  its interface.
- IAG50cm `FB_TelescopeControl._StopTelescope` (lines 1921-1955): hour angle and declination only.

### 3. Range: clamped, not rejected, and the default limits are wrong for MONET

- `FB_Comm_MQTT_Influx._ApplyField` lines 154-162: after the #74 gate (`_FocusAllowed`, READY_STATE 1) only
  `_ParseLREAL(fMin := -1.0E6, fMax := 1.0E6)`; the comment says "the focus axis enforces its limits".
- HalfBROT `FB_FocusControl` line 78: `fPosition := LIMIT(fMinPosition, fPosition, fMaxPosition)`, defaults 0 / 100
  (lines 6-7). So `focus=500` became a silent move to **100**, no log.
- MONET/S `MAIN.TcPOU` lines 150-156 and MONET/N `MAIN.TcPOU` lines 148-152 do not set `fMinPosition`/`fMaxPosition`:
  both run with 0..100.
- The far limit switch is the homing cam: `bCalibrationCam := IbLimitFar` (line 145), `fHomingPosition := 92.02 //
  104.02 - 12.00` (MONETS MAIN line 152). So the switch sits at ~92.0 mm and the clamp limit 100 lies beyond it.
- NC soft limits are off for the focus: MONETS `MONETS.tsproj` line 2618 `<SoftEndMaxControl Range="100"/>` (no
  `Enable`), MONETN `MONETN.tsproj` lines 2622-2623 (axis "Fokus", min 15 / max 100, no `Enable`).
- IAG50cm clamps too (`FB_FocusControl` line 16, 1.0..17.0, its own defaults).

## Design

### D1. Re-target on change (recommended) vs. an "update" mode in `FB_Axis`

- **A (recommended): re-target in the focus block.** Remember the target the running move was started with
  (`fMoveTarget`). While moving, if `ABS(fPosition - fMoveTarget) > fTolerance`, call `fbAxis.MoveTo()` again and
  store the new `fMoveTarget`. Uses the existing `MoveTo()` restart; no change to `FB_Axis`, so no effect on the
  mount axes. Comparing with `fMoveTarget` (not `fActualPosition`) means the ±0.04 mm hunting of HalfBROT#85 does
  not cause restarts.
- **B: "continuous update" in `FB_Axis`** (restart `MC_MoveAbsolute` whenever `Position` changes while a move runs).
  Rejected: azimuth/elevation/derotator write `Position` on their own (tracking, turn selection), it would change
  their behaviour, and Tc2_MC2 `MC_MoveAbsolute` has no ContinuousUpdate input **[unverified]**.

The follow logic is the same in HalfBROT and IAG50cm, and HalfBROT has no test project. Proposal: a small pure-logic
block in BROTLib, testable in `BROTLibTests`, used by both focus blocks:

```st
// Follows a target with MoveTo() (MONETcommon#122): starts a move when off target, restarts it when the target
// changes by more than fTolerance while moving, ends on MoveDone, abort, error or stop. No NC access.
FUNCTION_BLOCK FB_MoveFollower
VAR_INPUT
	fTarget, fActual, fTolerance	: LREAL;
	bActive			: BOOL;	// automatic positioning allowed (automatic mode, calibrated, not homing)
	bReady			: BOOL;	// fbAxis.Ready
	bMoveDone, bAborted, bError, bStopDone	: BOOL;	// from FB_Axis (last call)
END_VAR
VAR_OUTPUT
	bStartMove		: BOOL;	// call fbAxis.MoveTo() this cycle
	bMoving			: BOOL;	// a move to fMoveTarget is running or pending
	bNeedEnable		: BOOL;	// off target but drive not ready (the focus enables itself, HalfBROT line 99)
	fMoveTarget		: LREAL;
END_VAR
```

Plus a method `Stop()` that sets an internal `bStopping` (no start/restart until `bStopDone`, or until a new target
differs from the held one). The focus block keeps the NC calls (`fbAxis.MoveTo()`, `fbAxis.Stop()`) itself. If Tim
prefers no new library block: inline in both `FB_FocusControl`s, with tests only in IAG50cmTests (open question 1).

`bMoveAxis`/`bMoving` cleared on `MoveDone OR bAborted OR bError OR StopDone` (HalfBROT today: `MoveDone` only).
After an error the block holds: `fPosition := fActualPosition` (if calibrated), so a reset does not resume the old
move by itself.

### D2. `I_Focus.Stop()` and who calls it

`BROTLib/BROTLib/Interfaces/I_Focus.TcIO`, new method:

```st
// Stop a running focus move (MC_Stop) and hold the position reached: the target becomes the actual position at
// StopDone, so the automatic positioning does not restart the move. A new Position afterwards moves again.
// No-op (returns FALSE) when the drive is not enabled: a stop pending on a disabled axis would run after the next
// enable (FB_Axis, see plan 2026-10-21-axis-stop-idempotent-93-92.md). MONETcommon#122.
METHOD Stop : BOOL
```

Only on `I_Focus`, not on `I_BaseAxis`: implementers are just HalfBROT `FB_FocusControl` (extends `FB_BaseAxis`),
IAG50cm `FB_FocusControl` (extends IAG50cm `FB_AxisControl`, has `StopAxis`) and `BROTLibTests/FB_FocusStub`
[verified by search]. HalfBROT/IAG50cm `FB_AxisControl` keep their `StopAxis` level as is.

HalfBROT `FB_FocusControl.Stop()`: `fbAxis.CancelMove(); follower.Stop();` and `IF fbAxis.Ready AND NOT
fbAxis.StandStill THEN fbAxis.Stop(); END_IF`; body: on `fbAxis.StopDone` (or at once if nothing was moving)
`fPosition := fActualPosition`. IAG50cm: the same through `THIS^.StopAxis := TRUE` (cleared on `StopDone`, lines 66-68).

Interaction with #93/#92 (on `develop`): `fbAxis.Stop()` is idempotent, so repeated focus stops (MONETcommon
`Restart()`, D2 of #96) start no second `MC_Stop`; a joined stop may give two `StopDone` pulses, harmless here
(`fPosition := fActualPosition` twice). #92 releases `MoveCommand.Execute` on CommandAborted; the follower does not
read `Execute`. Risk **[unverified]**: if a re-triggered `MC_MoveAbsolute` reports CommandAborted for the old
motion one cycle after the new edge, `FB_AxisCommand` (`ELSIF Done OR Aborted THEN Execute := FALSE`) would drop
`Execute` of the new move. PLCopen keeps a running move when `Execute` falls, so it should still reach its target and
pulse `MoveDone`, but this is the first thing to watch on site (step 3) and in CI. Requires 0.9.1 (#93/#92) in the
same or an earlier release than this change.

Callers:

- **MONETcommon** `_StopTelescope`: `fbFocus.Stop()` inside `IF NOT bStopTxBegun THEN` (lines 1802-1805), i.e. once
  per stop transaction; and in `Stop()` (line 2131) next to `fbStopTx.Restart()` for a repeated stop. The focus is
  not added to `FB_MonetStopTransaction` (settling stays on the three mount axes). Also worth adding to
  `SuspendAutomatic` (#118), not part of this plan.
- **IAG50cm** `_StopTelescope`: `IF fbFocus <> 0 THEN fbFocus.Stop(); END_IF` on the first call of a stop.
- **Not** in `FB_Comm_MQTT_Influx` (`stop` stays `Telescope.Stop()`), so stop semantics live in one place per
  telescope (open question 2).

Park/emergency park: stage 0 writes `fbFocus.Position := focusPark` (MONETcommon line 1097, IAG50cm 1279/1552). With
D1 this now redirects a running focus move to the park position instead of being ignored.

### D3. Range: reject in the handler (recommended), clamp stays as a backstop

- New read-only properties on `I_Focus`: `MinPosition : LREAL`, `MaxPosition : LREAL` (Get from
  `fMinPosition`/`fMaxPosition` in both `FB_FocusControl`s; stub: inputs, default ±1E6).
- `_ApplyField`, `focus` branch, after `_ParseLREAL`:

```st
	ELSIF fValue < Focus.MinPosition OR fValue > Focus.MaxPosition THEN
		ADSLOGSTR( ADSLOG_MSGTYPE_WARN OR ADSLOG_MSGTYPE_LOG, 'MQTT focus rejected: outside the focus range %s',
			CONCAT(CONCAT(CONCAT(CONCAT(value, ' not in '), LREAL_TO_STRING(Focus.MinPosition)), '..'),
			LREAL_TO_STRING(Focus.MaxPosition)));
	ELSE
		Focus.Position := fValue;
```

  Same style as the other rejections (ADS log only, nothing on `<telescope>/Log`; same open point as #74 decision 4).
  The old target is kept, so a running move continues.
- Why reject, not clamp: a clamp turned `focus=500` into an unattended run to the end of travel, which is what a
  client never asked for. A rejection leaves the focus where it is and logs why. The `LIMIT` in both focus blocks stays
  for writers other than MQTT (park config, pendant code, IAG50cm startup).
- Site limits: MONETS and MONETN `MAIN` set `fMinPosition`/`fMaxPosition` to the real travel (e.g. max 91.5, below
  the cam at 92.02; min from the near switch); values from Tim (open question 3). Optionally enable the NC soft ends
  (`SoftEndMinControl/SoftEndMaxControl Enable="true"`) as a hardware-near backstop.

## Version, merge and release order

`I_Focus` gets three members: every implementer breaks until it adds them, so this is a **minor** bump.

1. **BROTLib**: release 0.9.1 (#93/#92, already on `develop`) first as its own plan says, or let it ride along
   (open question 5). Then branch `fix/focus-retarget-stop-range-122`: `I_Focus` (`Stop`, `MinPosition`,
   `MaxPosition`), `FB_MoveFollower`, `_ApplyField` range check, `FB_FocusStub`, tests, README (`I_Focus` row, the
   `focus` command paragraph). CI green, release **0.10.0** (`gh workflow run release.yml -f version=0.10.0`).
   Consumers are pinned to 0.9.0, so nothing breaks until each bumps its pin.
2. **HalfBROT**: pin `BROTLib, 0.10.0` (`HalfBROT.plcproj` line 102) + `FB_FocusControl` (follower, `Stop`,
   properties, `bMoveAxis` cleared on abort/error/stop, hold on error) in one PR, release **0.6.0**.
3. **MONETcommon**: pins BROTLib 0.10.0 (line 125) + HalfBROT 0.6.0 (line 129), `fbFocus.Stop()` in
   `_StopTelescope`/`Stop`, release 0.9.4 (or 0.10.0 if Tim counts the stop behaviour as minor).
4. **MONETS, MONETN**: pins (MONETS `MONETSRuntime.plcproj` lines 106/110/118, MONETN lines 100/104/112) + focus
   limits in `MAIN`, releases after 1.4.2 / 0.4.2.
5. **IAG50cm**: pin BROTLib 0.10.0 (`IAG50cm.plcproj` line 224) together with `FB_FocusControl` (follower, `Stop`
   via `StopAxis`, properties) and `fbFocus.Stop()` in `_StopTelescope`; one PR (the pin alone does not build), own
   release after v0.4.0. Can run in parallel with 2-4.

## Tests (TcUnit)

**BROTLibTests** (`FB_MoveFollower_Tests`, new):
`Start_When_Off_Target`, `No_Start_Within_Tolerance`, `No_Start_When_Not_Ready_Requests_Enable`,
`Retarget_While_Moving_Restarts`, `Retarget_Within_Tolerance_No_Restart`, `Hunting_Does_Not_Restart` (actual
oscillates ±0.04, target fixed; HalfBROT#85), `MoveDone_Ends_Move`, `Abort_Ends_Move`, `Error_Ends_Move`,
`Stop_Blocks_Restart_Until_New_Target`, `Stop_While_Pending_Drops_Start`, `Inactive_Never_Starts`.

**BROTLibTests** (`FB_Comm_MQTT_Influx_Tests`, stub gets `fMinPosition`/`fMaxPosition` inputs and an `nStop`
counter): `Focus_Above_Max_Rejected`, `Focus_Below_Min_Rejected`, `Focus_At_Limits_Applied`,
`Focus_OutOfRange_Keeps_Old_Target`, `Focus_Range_Not_Checked_When_Not_Online` (gate first, one rejection),
`Stop_Command_Does_Not_Stop_Focus_Directly` (`nStop = 0`; pins D2). Log lines are not observable (as #74/#79).

**IAG50cmTests**: `FB_FocusControl_Stop_Tests` only if the block can be instantiated without an NC axis
**[unverified]**; otherwise covered by `FB_MoveFollower_Tests` plus on-site checks.

**MONETcommonTests**: none; the controller is not instantiated in tests (the stop tests use pure functions and
`FB_StopRig`). On site.

**HalfBROT**: no test project; covered by `FB_MoveFollower_Tests` and on site.

## On-site re-test, MONET/S

`mosquitto_pub -t MONETS/Telescope/SET`, someone at the focus, XAE attached (ADS log, `FocusControl.fbAxis`
online: `MoveCommand.Execute`, `MoveDone`, `StopDone`, `follower.bMoving`, `fMoveTarget`), telemetry CURRPOS /
TARGETPOS / MOTION_STATE. Telescope online, focus at 36.

1. `command focus=500` and `focus=-5`: rejected with the range warning, no motion, TARGETPOS unchanged.
2. `command focus=60`, after ~5 mm `command focus=40`: the focus reverses at once and settles at 40, TARGETPOS = 40
   during the move, `MoveDone` arrives, brake locks after `ptBrakeDelay`.
3. Repeat 2 several times quickly (60, 45, 55, 36): every new target taken, `MoveCommand.Execute` TRUE during each
   move (the #92 risk), no axis error.
4. `command focus=60`, after ~5 mm `command stop=1`: focus stops within the ramp, TARGETPOS = position reached, no
   restart, brake locks; then `command focus=36`: moves back.
5. `stop=1` twice during a focus move: one `MC_Stop` edge, same end state.
6. `stop=1` with the focus at rest and brake locked: no motion, no pending stop after the next enable (a later
   `focus=37` moves normally).
7. `command focus=60`, then `command park=1`: the focus is redirected to `focusPark` 36 and the park completes.
8. Focus at rest at 36: hunting check of HalfBROT#85 unchanged or better (no restarts while hunting).
9. (with care, only after the limits are set) jog toward the far switch to confirm `IbLimitFar` stops the axis and
   where it sits relative to 92.02 (HalfBROT#59 "focus limit polarity").

MONET/N: steps 1, 2, 4 after its deploy. IAG50cm: steps 1, 2, 4, 5 on `50cm/Telescope/SET` with its own limits.

## Open questions (for Tim)

1. Shared `FB_MoveFollower` in BROTLib (recommended, testable, one implementation) or inline in both focus blocks?
2. Focus stop only through the telescope's stop (recommended) or also directly in the MQTT `stop` branch
   (`Focus.Stop()`, works without a telescope controller)?
3. Real focus travel for MONET/S and MONET/N (`fMinPosition`/`fMaxPosition`), and should the NC soft ends be
   enabled?
4. The incident's recovery: was the PLC reset/restarted between the drive disable and `focus=36`? By the code
   `bMoveAxis` should have stayed TRUE.
5. Release 0.9.1 (#93/#92) on its own first (recommended, separate on-site checks) or fold it into 0.10.0?
6. Range rejection: ADS log only, or also `<telescope>/Log` (same question as #74/#79)?

## Not in this plan

- `power=0` rejected over MQTT ("want 1 or 2", `FB_Comm_MQTT_Influx` line 77): separate issue.
- `bIsParked` TRUE after an emergency park that never reached the park position: separate MONETcommon issue.
- Focus hunting (HalfBROT#85), stored position in manual mode (HalfBROT#66), `SuspendAutomatic` stopping the focus
  (#118).

## Implementation (2026-10-21)

| Repo | PR | Release |
|---|---|---|
| BROTLib: `I_Focus.Stop/MinPosition/MaxPosition`, `FB_MoveFollower`, range check in `FB_Comm_MQTT_Influx` | #96 | **0.10.0** (includes the unreleased #93/#92 fixes, so no 0.9.1) |
| HalfBROT: `FB_FocusControl` | #96 | **0.6.0** |
| MONETcommon: `fbFocus.Stop()` in `_StopTelescope` and `Stop()`, test `FB_FocusMock` | #128 | **0.9.4** |
| MONETS, MONETN: focus limits, pins | #41, #30 | **1.4.3**, **0.4.3** (#42, #31) |
| IAG50cm: `FB_FocusControl`, `Stop()` in `FB_TelescopeControl.Stop()`, pin | #140 | **0.4.1** (#141) |

Open questions as decided:

1. Shared `FB_MoveFollower` in BROTLib (13 TcUnit cases).
2. Focus stop only through the telescope's stop; the `stop` branch of the MQTT handler is unchanged (a test pins it).
3. Travel: the limit switches sit at 0 and at the homing position 92.02 mm (Tim). `fMinPosition := 0.5`,
   `fMaxPosition := 91.5` in MONETS and MONETN `MAIN`, 0.5 mm inside the switches. NC soft ends not changed (MONETN's
   disabled minimum of 15 in the tsproj does not match a near switch at 0 and was left alone).
4. How `focus=36` worked after the drive re-enable stays unexplained by the code; not needed for the fix.
5. #93/#92 were folded into 0.10.0.
6. Range rejection logs to ADS only.

Differences from the proposal:

- `FB_MoveFollower` ignores the `CommandAborted` that a restart causes for the old move (`Abort_Of_Old_Move_After_Restart_Is_Ignored`)
  and starts nothing while `bError` is set; `Stop()` returns whether a move was running.
- `Stop()` in the focus blocks: with the drive not enabled it only drops the pending target (no `MC_Stop` that would
  run after the next enable). After an error the target is set to the position reached.
- IAG50cm keeps `bMoveAxis` (a level `FB_AxisControl` exposes) and sets it from `bMoving`; its enable comes from the
  telescope, so `bNeedEnable` is unused. `fbFocus.Stop()` is in `Stop()` (the explicit stop), not in `_StopTelescope`:
  the automatic stops of the mount leave the focus alone.
- Test fallout: MONETcommon `FB_FocusMock` used `bMoveAxis` (it never moved, now `bMove := FALSE`); IAG50cm's mock and
  BROTLib's `FB_FocusStub` implement the new members. No MONETcommon or HalfBROT unit test for the stop call.
- Found on the way: `Join_Dropped_Without_Rest` (`FB_AxisCommand_Tests`) was red on `develop` since #95, a test bug
  (BROTLib#98); `tcbuild.yml` retries TcBuild 8 times instead of 4 against the XAE busy error (BROTLib#97, as in
  MONETcommon).

Still open: the on-site re-test (steps above, MONET/S first, then MONET/N and IAG50cm), the CI result of the three
telescope repos after their release merges, and closing MONETcommon#122 after the re-test.
