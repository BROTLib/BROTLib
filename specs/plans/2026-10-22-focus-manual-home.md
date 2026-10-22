# Focus: manual re-home of a calibrated focus (MONET)

**Status: implemented and released 2026-10-22 (HalfBROT 0.7.1, MONETcommon 0.9.7, MONETS 1.4.4, MONETN 1.4.4); on-site
test open.** All recommendations below were taken. No issue opened (question 9).

Outcome, differences from the plan:
- HalfBROT PR #104 (code, README, visu push switch -> `bManualHome`). The log line for a rejected request had
  `UDINT_TO_STRING(eManualHome)`: one compile warning, which failed the v0.7.0 library build, because the
  `release-library.yml` step ended with tctool's exit code 1 although it treats 1 as success. Fixed in #107 (`INT_TO_STRING(TO_INT(...))`,
  `exit 0` in the step). v0.7.0 is tagged but has no library; **0.7.1** is the release. `main` had also gotten two
  `release-library.yml` commits directly, which conflicted with `develop`'s tctool version: merged in #106 (keeping
  `develop`'s file).
- MONETcommon PR #143: `F_FocusHomeRelease_Tests` (5 cases) and `FB_FocusManualHome_Tests` (18 cases), 166/166 TcUnit
  cases passed in CI; pin `HalfBROT, 0.7.1`; release **0.9.7**.
- MONETS #51/#52 and MONETN #38/#39: pins `HalfBROT, 0.7.1`, `MONETcommon, 0.9.7`; both released as **1.4.4** (same number
  on request; MONETN jumped from 0.4.3). `MAIN` unchanged.
- Not verified, still to check on MONET/S (steps below): whether the NC drops `Calibrated` when homing a homed axis,
  whether `MC_Stop` aborts `MC_Home`, ADS write of `bManualHome` by symbol name.

Original plan text (status "proposed"). Base commits (2026-10-22, `origin`):
HalfBROT `e4208f3` (`develop`, v0.6.0, pins `BROTLib, 0.10.0`), BROTLib `fda0a52` (v0.10.3), MONETcommon `12b7031`
(`develop`, v0.9.6, pins `HalfBROT, 0.6.0`), MONETS `f8c034e` (v1.4.3), MONETN `6fc8023` (v0.4.3). MONETS/MONETN
`develop` pin `HalfBROT, 0.6.0` and `MONETcommon, 0.9.5`. Related: plan
`2026-10-21-focus-retarget-stop-range-122.md` (`FB_MoveFollower`, `I_Focus.Stop()`), HalfBROT#8 (persistent write),
#18 (`MC_Direct`), #80 (`rtHomed`), BROTLib#62/#63 (`Home(fReference)`, command handshake).

Marking: **[verified]** = read in the code at the commits above; **[unverified]** = my reading of TwinCAT NC /
Tc2_MC2 behaviour, to be confirmed on MONET/S.

Note on line numbers: the local HalfBROT checkout is 10 commits behind `origin/develop` (pre-#96, v0.5.7). All
HalfBROT line numbers below are from `origin/develop` `e4208f3`; the ones in the request (auto-home 110-113,
`IF bHomeAxis` 122-130, clears 158-160/171-173) are from the old checkout. Branch the work from `origin/develop`.

## Goal

A variable that an operator (XAE online write, ADS) or a program can set to make an already calibrated MONET focus
home again on its cam, because its stored position is in doubt. Not an MQTT command.

## Non-goals

- No change to the automatic homing at startup of an uncalibrated focus (body lines 133-137, MONETcommon stage 10).
- No MQTT command, no `I_Focus` member, no BROTLib change, no IAG50cm change (IAG50cm has its own
  `FB_FocusControl` and does not reference HalfBROT [verified: its `.plcproj` pins only BROTLib]).
- No telescope-level interlock (tracking etc.): the person setting the variable is responsible (question 4).
- No measurement of how far the old calibration was off (would need the position jump at the reference; possible
  follow-up).

## Current behaviour [verified]

HalfBROT `HalfBROT/HalfBROT/POUs/FB_FocusControl.TcPOU` (extends BROTLib `FB_BaseAxis`, implements `I_Focus`):

- **Auto-home** (lines 116-138): only in automatic mode, not `bManualUnlock`, `NOT fbAxis.calibrated` and
  `fbAxis.Ready`: `THIS^.HomeAxis := TRUE`. The drive is enabled by MONETcommon (stage 10, below).
- **Homing mode** (lines 145-153): while `bHomeAxis`, every cycle: `fLastPosition > 0` -> `MC_Direct`,
  `fPosition := fLastPosition`; else `MC_DefaultHoming` (cam), `fPosition := fHomingPosition`. `_StartHoming`
  (lines 214-228) makes the same choice once for the reference: `SEL(fLastPosition > 0.0, fHomingPosition,
  fLastPosition)` -> `fbAxis.Home()`. The two choices are taken at different times.
- **Limit bypass** (lines 156, 164): `MC_SetAcceptBlockedDriveSignal(enable := bHomeAxis)`,
  `enable_Positive := NOT IbLimitFar OR bHomeAxis`. Dropping `bHomeAxis` during a cam homing re-blocks the far switch,
  which is the cam (line 168).
- **End of homing**: line 176-179 `rtHomed(CLK := HomeDone AND NOT HomeActive)`, `bHomeAxis := FALSE` on the level;
  180-184 on the edge `bEnable := FALSE`, `fLastPosition := fActualPosition`, `bSaveRequested := TRUE`; 190-192
  `IF (calibrated AND NOT HomeActive) OR bError THEN bHomeAxis := FALSE`; 194-196 `bError` -> `fLastPosition := -1`.
- **Stored position**: lines 130-132, in automatic mode, calibrated and locked: `fLastPosition := fActualPosition`
  every cycle. `_WritePersistentPosition` (243-) writes when it changed, `NOT ObFocusUnlock AND NOT bHomeAxis AND NOT
  fbAxis.Busy`, at most once per 60 s.
- **Follower** (lines 91-100, plan #122): `bActive := automatic AND NOT bManualUnlock AND fbAxis.calibrated` - not
  "not homing", although the `FB_MoveFollower` comment says so. Start moves at 119-121.
- **Brake** (126-128): `IF tonBrakeDelay.Q THEN bEnable := FALSE` inside the calibrated branch.
- **`Stop()`** (324-341): `fbFollower.Stop(); fbAxis.CancelMove();` and `IF fbAxis.Ready AND NOT StandStill THEN
  fbAxis.Stop(); bHoldOnStop := TRUE`.

BROTLib `FB_Axis` (`origin/develop`): `Home()` (lines 382-396) is ignored while `HomeActive`, else
`HomeCommand.Request(); HomePending := TRUE`. Body 236-245: `HomeCommand(Allowed := Ready, ...)`, `HomePending :=
HomeCommand.Pending`, `HomeActive := HomeCommand.Execute OR Axis_Home.Busy`; `FB_AxisCommand` turns Pending into
Execute in the same call, so there is no cycle with neither [verified]. 247-255: `Calibrated` and `HomeDone` are both
the `Status.Homed` level. `Stop()` (405-413) cancels a pending Home and requests `MC_Stop`, which is allowed while
`Status.Homing`. `CommandAborted` (343) includes `Axis_Home.CommandAborted`. `FB_BaseAxis.HomeAxis` setter (BROTLib
`FB_BaseAxis.TcPOU` 153-161): FALSE->TRUE calls `_StartHoming`, FALSE calls `fbAxis.CancelHome()`.

MONETcommon `FB_MonetTelescopeControl.TcPOU` (`12b7031`):

- Stage 10 of `_PowerOn` (1113-1120): elevation calibrated and focus not -> `fbFocus.Enable := TRUE`, once
  `HomeAxis := TRUE`; 1122-1125 waits for `fbFocus.Calibrated`. `_PowerOn` abort (1061-1073) writes
  `fbFocus.HomeAxis := FALSE` - only on stop/park/reset/error during a power-on.
- 661-671: `bHomed` includes `fbFocus.Calibrated`; `bReady := bHomed AND ...`; 684 `Operational := bReady AND ...`.
  `FB_StartupReadiness`: an initialized telescope that loses Operational shows READY_STATE -2 and returns to 1 by
  itself; `AcceptInit` refuses a new init meanwhile. MQTT `focus=` is accepted only at READY_STATE 1 (#74).
- 673-676: `bBusy` includes `fbFocus.Busy`; goto/slew/track/gohome dispatch waits for `NOT bBusy` (553-585), park
  waits for `NOT bBusy` (534).
- `fbFocus.Stop()` in `_StopTelescope` (1873, once per stop transaction) and `Stop()` (2203).

Consumers of `FB_FocusControl`: MONETS `MAIN.TcPOU` (instance line 24, call 151-160), MONETN `MAIN.TcPOU` (24,
148-155), MONETcommonTests `FB_FocusMock` (extends it, does not run its body). MONETcommon itself only sees `I_Focus`.

Found on the way: HalfBROT `VISUs/Focus.TcVIS` has a `PushSwitch` bound to `MAIN.FocusControl.bHomeAxis` (and a
lamp). Writing the field bypasses the `HomeAxis` setter, so since BROTLib#62/#63 it starts no `Home()`; on a
calibrated focus line 190 clears it in the next cycle, on an uncalibrated one it can block the auto-home (the setter
sees no FALSE->TRUE edge). Whether any MONET HMI uses this visu is unknown.

## What goes wrong with the first sketch

The sketch (`bManualHome`; clear it; if not homing, not manual unlock, no error: `fLastPosition := -1`,
`bEnable := TRUE`, `HomeAxis := TRUE`; `AND NOT fbAxis.HomePending` in both clears) is the right core. The
`HomePending` guard is needed and neutral for the auto path (there `calibrated` is FALSE until the homing ran). Gaps:

1. **The follower moves during the re-home.** It is active whenever `calibrated`; while `bHomeAxis` line 151 sets
   `fPosition := fHomingPosition`, so the follower calls `MoveTo()` (allowed: `Ready AND Calibrated`), and a
   `MC_MoveAbsolute` would abort the running `MC_Home` [unverified, PLCopen behaviour] - or before it starts, the move
   to 92.02 runs first. Needs `AND NOT bHomeAxis` in `bActive`.
2. **Placement decides the homing mode.** If the handler runs before line 116, line 131 (still locked this cycle)
   writes `fLastPosition := fActualPosition` back over the -1. `_StartHoming` already passed the cam reference
   92.02, but line 146 then selects `MC_Direct` - an `MC_Home(MC_Direct, Position := 92.02)` sets the focus to 92.02
   without motion, i.e. a wrong calibration. The handler must run after the automatic block, and line 130 should
   also skip while `bHomeAxis`. Better: take the homing mode once, in `_StartHoming`, together with the reference.
3. **Brake release can cancel the enable.** Line 126 clears `bEnable` while `tonBrakeDelay.Q`. On the working focus
   moves that timer is evidently not running while the drive is off (else no move from rest would start), so it is
   probably harmless [unverified: `StandStill` of a disabled axis]; `AND NOT bHomeAxis` makes it independent of that.
4. **Abort leaves `bHomeAxis` stuck** if the NC drops `Homed` at the start of `MC_Home` [unverified] and the homing
   is then stopped (`I_Focus.Stop()` from a telescope stop) or never starts: `HomeActive`/`HomePending` FALSE,
   `calibrated` FALSE -> nothing clears it; the far switch stays bypassed and the auto-home sees no edge. Today only
   the MONETcommon power-on abort clears it. A manual re-home needs its own end detection.
5. **The focus does not come back.** After the homing `fPosition` is 92.02, clamped to `fMaxPosition` 91.5 on
   MONET: the focus parks at 91.5 and the observer's focus value is lost.
6. **No feedback** when a request is ignored.

## Design questions (recommendation first)

**Q1. Name, kind, visibility.** `bManualHome : BOOL` as **`VAR_INPUT`**, set TRUE, cleared by the block (one-shot),
not passed in the `MAIN` call. A `VAR` (like `bManualUnlock`) is writable online and by symbol over ADS, but not by
another POU (`'is no input of'`, as `FB_FocusMock` notes for `FB_Axis` outputs); `VAR_INPUT` covers all three.
It is a self-clearing input like `bReset`/`bHomeAxis` in the same block (the pattern BROTLib#9 flags as a smell, but
consistent here). No `I_Focus` member (would need BROTLib + IAG50cm). Symbol path `MAIN.FocusControl.bManualHome`;
ADS write by name is expected to work like the visu bindings of `bManualUnlock` [unverified for library FB
instances: confirm on site, step 1]. Rebind the visu `PushSwitch` from `bHomeAxis` to `bManualHome`.

**Q2. Cam homing, not `MC_Direct`.** `MC_Direct` would only re-assert the doubted stored position. Set
`fLastPosition := -1.0` at the start (as sketched): if the cam homing fails or is stopped and the axis ends up
uncalibrated, the next homing is a cam homing as well, which is right because the axis moved during the search.
If it ends calibrated (NC kept the old calibration), line 131 re-takes the actual position at rest, so nothing is
lost. Residual risk: the -1 is not on disk until the focus is at rest again (`_WritePersistentPosition` skips while
`bHomeAxis`/unlocked); a power loss during the re-home restores the old stored value and `MC_Direct` uses it.
Recommendation: accept, document (operator re-homes). Alternative: let the invalidation write (`fLastPosition <= 0`)
pass the at-rest guard.

**Q3. When accepted.** Only if: automatic mode, `NOT bManualUnlock`, `NOT bError`, `fbAxis.calibrated`, not homing
(`bHomeAxis`, `HomeActive`, `HomePending`), not moving (`fbAxis.Busy`, `fbFollower.bMoving`). Otherwise: ADS warning
with the reason, variable cleared, nothing else. Manual/pendant mode is excluded because the pendant writes
`fbFocus.Enable := IbEnableButton` every cycle (MONETcommon `FB_MonetPendantControl` 116) and jogs. Not calibrated
is excluded per the requirement (automatic homing handles it), except after an aborted manual re-home (Q6).

**Q4. Telescope state (tracking, park, startup).** No gate in the focus block (it does not know the telescope
state) and none in MONETcommon. Consequences to document: the re-home takes minutes (up to ~92 mm at the homing
velocity); `fbFocus.Busy` holds `bBusy` TRUE, so goto/slew/track/park dispatch waits as for any focus move (a running
track is not dispatched again; whether it keeps running while `bReady` drops is not checked in detail). If the NC
drops `Homed` during `MC_Home` [unverified], `bHomed`/`bReady`/Operational go FALSE: READY_STATE -2, MQTT `focus=`
rejected, REFERENCED 0, then back to 1 by itself after the homing. Do not trigger during a power-on: the
power-on abort writes `HomeAxis := FALSE` mid-homing and re-blocks the cam switch (same as for the startup homing
today). Procedure: only with the telescope idle/online, not observing.

**Q5. Target after the re-home.** Recommendation: restore the target from before the request
(`fPosition := LIMIT(fMinPosition, fRestoreTarget, fMaxPosition)` on success): the value in mm is still the wanted
focus, now in the corrected calibration. Targets written during the re-home are overwritten by line 151 and lost
(documented; MQTT is rejected anyway if READY_STATE drops). Alternative: leave the focus at the clamp (91.5) as after
startup.

**Q6. Stop during the re-home.** `I_Focus.Stop()` (telescope stop) calls `fbAxis.Stop()` -> `MC_Stop` aborts
`MC_Home` [unverified that Tc2_MC2 aborts a homing this way]. Recommendation: a stop stops the re-home. The block then
releases `HomeAxis` (setter FALSE) and logs "aborted". If the axis is still calibrated: old calibration, focus held
where it stopped (`bHoldOnStop`). If not: drive disabled, focus uncalibrated and at rest, READY_STATE -2; the
automatic auto-home (line 134) is blocked by a flag until the next accepted `bManualHome` (allowed in this state) or
until anyone sets `HomeAxis` (MONETcommon power-on). Alternative A: do not block - line 134 restarts a cam homing
within a cycle, i.e. a stop that does not stop. Alternative B: `Stop()` ignores a running re-home.
Gap in today's `Stop()` [verified]: with the drive not yet Ready it only drops the move (`fbAxis.Stop()` is skipped),
so a `Home()` still pending would start after the stop. Add `IF fbManualHome.bRunning THEN fbAxis.CancelHome();
END_IF` to `Stop()`; this ends the re-home without a stop pulse, so `bDone` requires that `HomeActive` was seen.

**Q7. `Calibrated` during the re-home.** Not changed by the plan; it follows the NC (`Status.Homed`). Whether it drops
at the start of `MC_Home` on an already homed axis is the main unknown [unverified], on-site step 3. Both cases are
handled: end detection uses `HomeActive`/`HomePending` plus an abort latch (`CommandAborted OR StopDone OR bError`
while re-homing), not `Calibrated`. `rtHomed` is unchanged and fires at the end in both cases (`HomeActive` goes
TRUE then FALSE), so `fLastPosition` and the persistent write follow the existing path.

**Q8. Where the logic lives and how it is tested.** A pure block `FB_FocusManualHome` plus `F_FocusHomeRelease` in
HalfBROT (no NC access, like `FB_MoveFollower`), tested in MONETcommonTests, which already tests HalfBROT's
`F_OilLevelValid`. HalfBROT has no test project. Alternative: BROTLib + BROTLibTests (needs a BROTLib release and a
HalfBROT BROTLib pin bump; no other user).

## Code changes

### HalfBROT (branch `feature/focus-manual-home` from `origin/develop`)

New `POUs/FB_FocusManualHome.TcPOU` (pure logic):

```st
// Manual re-home of a calibrated focus (bManualHome): decides a request, then follows the homing to its end.
// No NC access; the caller does the axis calls. Tested in MONETcommonTests (FB_FocusManualHome_Tests).
FUNCTION_BLOCK FB_FocusManualHome
VAR_INPUT	// per cycle, after fbAxis()
	bHomeActive, bHomePending, bCalibrated	: BOOL;
	bAbortPulse		: BOOL;	// fbAxis.CommandAborted OR fbAxis.StopDone OR bError
END_VAR
VAR_OUTPUT
	bRunning		: BOOL;	// a manual re-home was accepted and has not ended
	bDone			: BOOL;	// one cycle: ended calibrated, HomeActive was seen, no abort seen
	bAborted		: BOOL;	// one cycle: ended otherwise
	bBlockAutoHome	: BOOL;	// ended uncalibrated: keep the automatic homing off (Q6) until cleared
	fRestoreTarget	: LREAL;
END_VAR
// METHOD Request(bAutomatic, bManualUnlock, bError, bCalibrated, bHoming, bMoving, fTarget) : E_FocusManualHome
//   (Accepted / NotAutomatic / ManualUnlock / AxisError / NotCalibrated / Homing / Moving); bCalibrated may be FALSE
//   while bBlockAutoHome. On Accepted: bRunning, fRestoreTarget := fTarget, bBlockAutoHome := FALSE.
// METHOD ClearBlock: called when HomeAxis is set by anyone else.
```

New `F_FocusHomeRelease(bCalibrated, bHomeActive, bHomePending, bError) : BOOL` := `bError OR (bCalibrated AND NOT
bHomeActive AND NOT bHomePending)` - replaces both clear conditions (lines 177 and 190; `HomeDone` = `Calibrated`).

`FB_FocusControl`:

1. `VAR_INPUT bManualHome : BOOL;` (comment: set TRUE online/ADS/program, cleared by the block, see README);
   `VAR fbManualHome : FB_FocusManualHome; eRequest : E_FocusManualHome;` (new enum DUT with the reasons).
2. Line 95: `bActive := ... AND fbAxis.calibrated AND NOT bHomeAxis`.
3. Line 126: `IF tonBrakeDelay.Q AND NOT bHomeAxis`; line 130: `IF NOT ObFocusUnlock AND NOT bHomeAxis`.
4. Line 134: `IF fbAxis.Ready AND NOT fbManualHome.bBlockAutoHome THEN`.
5. After line 138, before line 145:
   ```st
   IF bManualHome THEN
   	bManualHome := FALSE;
   	eRequest := fbManualHome.Request(bAutomatic := eTelescopeMode = E_TelescopeMode.automatic,
   		bManualUnlock := bManualUnlock, bError := bError, bCalibrated := fbAxis.calibrated,
   		bHoming := bHomeAxis OR fbAxis.HomeActive OR fbAxis.HomePending,
   		bMoving := fbAxis.Busy OR fbFollower.bMoving, fTarget := fPosition);
   	IF eRequest = E_FocusManualHome.Accepted THEN
   		fLastPosition := -1.0;		// cam homing: the stored position is what is in doubt (Q2)
   		bEnable := TRUE;
   		THIS^.HomeAxis := TRUE;		// _StartHoming: reference fHomingPosition
   		(* ADS hint: started at fActualPosition *)
   	ELSE
   		(* ADS warning with the reason *)
   	END_IF
   END_IF
   ```
6. `_StartHoming`: also set `eHomingMode` (one decision with the reference); lines 145-153 keep only the
   `fPosition` part, selected by `eHomingMode`. Same behaviour for the auto path (there `fLastPosition` cannot change
   between the two, line 131 needs `calibrated`).
7. Lines 177/190: `IF F_FocusHomeRelease(...) THEN bHomeAxis := FALSE;` (one place; the level clear, not the setter,
   as today).
8. After the release, `fbManualHome(bHomeActive, bHomePending, bCalibrated, bAbortPulse)`; on `bDone`:
   `fPosition := LIMIT(fMinPosition, fbManualHome.fRestoreTarget, fMaxPosition)`, ADS hint with the position;
   on `bAborted`: `THIS^.HomeAxis := FALSE`, and if not calibrated `bEnable := FALSE`, ADS warning. In the body,
   `IF bHomeAxis AND NOT fbManualHome.bRunning THEN fbManualHome.ClearBlock()`.
9. `Stop()`: `IF fbManualHome.bRunning THEN fbAxis.CancelHome(); END_IF` (Q6).
10. `VISUs/Focus.TcVIS`: `PushSwitch` -> `MAIN.FocusControl.bManualHome` (lamp stays on `bHomeAxis`).
11. README, "Homing": the manual re-home (variable, conditions, cam homing, restored target, stop, READY_STATE).
    `.plcproj`: the new POUs and the DUT.

Not changed: `I_Focus`, `rtHomed`, `_WritePersistentPosition` (unless Q2 alternative), the HalfBROT
BROTLib pin (0.10.0).

### MONETcommon

No library code change. `MONETcommonTests`: tests below, pin `HalfBROT, 0.7.0` (`MONETcommonTests.plcproj` line
165); library pin (`MONETcommon.plcproj` line 132) bumped with it so the pins agree. Optional rig test needs
`FB_AxisMockCore` to model a home on a calibrated axis (drops `bCalibrated` while homing).

### MONETS, MONETN

Pins only (`MONETSRuntime.plcproj` 110/118, `MONETNRuntime.plcproj` 104/112). `MAIN` unchanged: `bManualHome`
is not passed in the call (passing it would overwrite every online write).

## Tests (TcUnit, MONETcommonTests)

`F_FocusHomeRelease_Tests`: `Pending_On_Calibrated_Keeps_Level` (the sketch's bug), `Active_Keeps_Level`,
`Calibrated_Idle_Releases`, `Error_Releases`, `Not_Calibrated_Keeps_Level` (auto path unchanged).

`FB_FocusManualHome_Tests`: `Accepted_When_Calibrated_Idle_Automatic`, one rejection test per reason
(`Manual_Mode`, `Manual_Unlock`, `Error`, `Not_Calibrated`, `Homing_Pending`, `Homing_Active`, `Moving`),
`Done_After_Active_And_Calibrated` (restore target = target at request), `Done_When_Calibrated_Stays_True` (NC keeps
Homed), `Abort_By_Stop_Pulse`, `Abort_By_Error`, `Abort_Before_Start` (pending dropped by `Stop()`, calibrated: no `bDone`),
`Abort_Uncalibrated_Blocks_AutoHome`, `Abort_Calibrated_No_Block`, `Request_Clears_Block`, `ClearBlock`,
`No_Second_Request_While_Running`.

Optional `MonetFocusRehome_Tests` (rig): online telescope, focus mock re-homes: READY_STATE -2 then 1 without a new
init, track dispatch waits for `NOT bBusy`.

Not testable without NC: the wiring in `FB_FocusControl` (the mock skips the body), `MC_Home` on a homed axis,
`MC_Stop` during homing, ADS symbol access. On site.

## Release and pin order

1. **HalfBROT**: PR to `develop`, CI build green; `gh workflow run release.yml -R BROTLib/HalfBROT -f version=0.7.0`
   (new input, minor), merge the release PR, `tag-release.yml` tags, `release-library.yml -f tag=v0.7.0` builds the
   library for consumers.
2. **MONETcommon**: tests + both HalfBROT pins in one PR (the tests do not build against 0.6.0), CI green (CI shows
   only counters; failing test names from a local runtime via ADS), release **0.9.7** (no library behaviour change).
3. **MONETS**, then **MONETN**: pins `HalfBROT, 0.7.0` and `MONETcommon, 0.9.7` (this also takes in 0.9.6, not yet
   pinned on `develop`), release 1.4.4 / 0.4.4. Deploy MONET/S, on-site test, then MONET/N.

## On-site test, MONET/S

XAE attached, `MAIN.FocusControl` online (`bManualHome`, `bHomeAxis`, `fbManualHome`, `eHomingMode`,
`fLastPosition`, `fbAxis.HomePending/HomeActive/Calibrated`, `fbFollower.bMoving`), ADS log, telemetry REFERENCED /
CURRPOS / MOTION_STATE / READY_STATE. Telescope online, idle, focus at rest at e.g. 36. Someone at the focus.

1. Write `bManualHome := TRUE` online in XAE (and once by ADS by symbol name): cleared next cycle, ADS hint
   "started"; `eHomingMode = MC_DefaultHoming`, `fLastPosition = -1`, no `MoveTo()` (`fbFollower.bMoving` FALSE).
2. The focus unlocks, drives to the far switch (cam), `bHomeAxis` stays TRUE through the `HomePending` phase.
3. Record whether `Calibrated`/REFERENCED drops during `MC_Home` (Q7) and READY_STATE (-2 or stays 1).
4. Homing ends: `bHomeAxis` FALSE, `rtHomed`, focus returns to 36, brake locks, `fLastPosition` = position reached,
   persistent write within a minute (no write error event), READY_STATE 1.
5. Rejections: in manual mode, with `bManualUnlock`, during a focus move (`focus=60`), during the re-home: ADS
   warning, nothing moves.
6. Stop: start a re-home, `command stop=1` mid-way: focus stops, "aborted" logged, `bHomeAxis` FALSE, far switch
   effective again. If uncalibrated: drive off, no automatic restart, READY_STATE -2; `bManualHome := TRUE` again
   recovers.
7. Visu `PushSwitch` (if the visu is in use) starts the same sequence.
8. Power cycle (controlled) after step 4: startup takes `MC_Direct` with the new stored position.

MONET/N: steps 1-4 and 6 after its deploy.

## Open questions (for Tim)

1. `VAR_INPUT bManualHome` (recommended) or `VAR` like `bManualUnlock` (XAE/ADS only, no program access)? Name OK?
2. Cam homing with `fLastPosition := -1` and no forced write of the -1 during the re-home (recommended), or force
   that write?
3. Accept only in automatic mode, calibrated, at rest, no unlock/error (recommended)? Also uncalibrated in general?
4. No telescope-state gate (recommended; procedure: telescope idle), or reject while tracking/slewing (needs
   MONETcommon or an `I_Focus` change)?
5. Restore the previous target after the re-home (recommended) or stay at the clamp 91.5?
6. Stop aborts the re-home and an uncalibrated result blocks the auto-home until the next manual request
   (recommended), or let the auto-home restart (A), or ignore stop during a re-home (B)?
7. Logic as a pure block in HalfBROT tested in MONETcommonTests (recommended) or in BROTLib/BROTLibTests?
8. HalfBROT 0.7.0 (recommended) or 0.6.1; MONETcommon 0.9.7 with only the pin/test change?
9. Issue: open one in HalfBROT for this (and one for the dead visu `PushSwitch` if it is to be fixed separately)?
