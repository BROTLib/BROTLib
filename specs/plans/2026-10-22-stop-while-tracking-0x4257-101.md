# Stop and retarget while tracking: wait for the setpoint generator to be off (BROTLib#101)

**Status: proposed, 2026-10-22.** Plan only, no PLC code changed. Base: BROTLib `develop` (0.10.3), MONETcommon `develop`
(0.9.7), HalfBROT `develop` (0.7.1). Related: MONETcommon#84 (stop during a slew, the change that introduced the
same-scan stop), MONETcommon#96 (`FB_MonetStopTransaction`), BROTLib#93/#92 (stop idempotent, `FB_AxisCommand`),
BROTLib#25 / MONETcommon#36 (state machine unification).

Marking used below: **[verified]** = read in the code or the issues on 2026-10-22; **[hypothesis]** = my reading of
how the NC behaves, to be confirmed by a test run or on a telescope. No TwinCAT runs on this machine: **CI is the
first compile and the first test run.**

## Problem

`stop=1` while the telescope is tracking intermittently puts all three axes into error 0x4257 ("Motion commands are
not allowed for external setpoint generated axis", CmdType 4096) two milliseconds after `STOP commencing`. The axes
lose enable, `emergency park started: axis error` follows but moves nothing, and `reset=1` or `power=1` clears it. The
same error occurs when a new `track` is sent while tracking. A `stop` during a slew always works.

Tally of `stop=1` while tracking (MONET/S): worked after 12 min of tracking (2026-10-21 14:05:54); failed after 2.5
min, after 4 min and after 40 s (the last one on MONETcommon 0.9.7 / HalfBROT 0.7.1). So it is intermittent and not
tied to the tracking time, and the refactors of MONETcommon 0.9.5/0.9.6 do not cause it: the first failure is older.

## Cause

**[verified]** in code:

1. `FB_MonetTelescopeControl._StopTelescope` (MONETcommon, around line 1857) does everything in one scan: `Tracking :=
   FALSE` on the three axes, `MoveAxis := FALSE`, `fbStopTx.Begin()` / `fbStopTx()` and `StopAxis := TRUE`. It does so
   since MONETcommon 0.8.5 (`25459d5`, #84, "all stops in one scan"). Before, it ran in stages and `MC_Stop` came at
   least one scan after the Tracking drop. The `StopAxis` setter (HalfBROT `FB_AxisControl`) calls `fbAxis.Stop()` at
   once, i.e. `StopCommand.Request`.
2. In the same PLC cycle `FB_Axis` (BROTLib) runs: `Axis_SetpointDisable(Execute := NOT Tracking)` (line 203) gets its
   rising edge, and about 60 lines later `StopCommand` turns the request into `Execute` and `Axis_Stop` (`MC_Stop`)
   rises. `Axis_SetpointDisable.Done/Busy/Error` are read nowhere: not in `Busy`, `Error` or `ErrorID`, not in
   `StopAllowed` (which only looks at the PLCopen states, line 257).
3. `MoveCommand` is not gated on the generator either (`Allowed := Ready AND Calibrated`, line 208). A `track` while
   tracking takes the same path: `_AcceptMove` sets `bSupersedeRequest`, the supersede block sets `bMoveAbortPending`,
   and that branch runs `_StopTelescope`. `SuspendAutomatic` (pendant) does the same (drop Tracking, then
   `_StopTelescope()`).
4. IAG50cm still has the staged `_StopTelescope` and does not show the error.

**[hypothesis]**: the NC sees `MC_Stop` while the generator is still enabled, because the disable and the stop reach
it in the same cycle through separate ADS commands, and rejects the stop with 0x4257. This fits all three axes failing
together, the 2 ms gap, and the intermittence (order of arrival), and it fits that a stop during a slew works (no
generator active). It is not provable from code. A second contributor may explain the 12 min success: the stop
transaction only sends `MC_Stop` to axes that are not StandStill, so an axis that reported StandStill while tracking
gets no stop. The 10 Hz log at 14:05:54 would show that. Also unverified: that CmdType 4096 is the stop, and that
`ExtSetPointGenEnabled` is a field of `ST_AxisStatus` (check in XAE).

**Related, found while reading:** the abort-stop branch (`ELSIF bMoveAbortPending`) also clears `bTrack`, so after a
retarget the new track is probably dropped. Needs its own check (see step 4).

## Design

Two changes, the library one is the real fix:

### A. BROTLib `FB_Axis`: no motion command while the generator is on (recommended, covers all callers)

- New pure function `F_MotionAllowed` (next to `F_SetpointEnableExecute`, same style): inputs the PLCopen-allowed flag
  of the command, `ExtActive` (the generator is on or still disabling) and `DisableBusy`; output the `Allowed` for the
  stop, move and jog channels. Pure logic so BROTLibTests can pin it without an NC axis.
- `ExtActive` is `Axis_Status.Status.ExtSetPointGenEnabled` if that field exists in the status struct; otherwise a latch
  in `FB_Axis`: TRUE from `Axis_SetpointEnable.Execute`/`Done` until `Axis_SetpointDisable.Done`.
- Gate `StopCommand(Allowed := StopAllowed AND NOT ExtActive ...)`, `MoveCommand(Allowed := Ready AND Calibrated AND
  NOT ExtActive ...)` and the jog inputs. `FB_AxisCommand` already keeps a request pending until `Allowed`, so the stop
  simply starts once the disable has completed. The stop timeout of the transaction blocks (15 s, MONETcommon) stays
  the backstop.
- `Axis_SetpointDisable.Error/ErrorID` join `Error` and `ErrorID` (otherwise a failed disable leaves the stop pending
  without an error until the 15 s timeout).
- The Enable side already has `NOT StopCommand.Execute AND NOT StopCommand.Pending` in its request (line 178), so a
  pending stop cannot be pre-empted by a new enable. The gate adds the other direction.
- No change to the interfaces of `FB_Axis` for callers, and no change in the HalfBROT and IAG50cm axis blocks.

### B. MONETcommon `_StopTelescope`: restore the one scan gap (belt and braces)

If any axis is tracking, drop `Tracking` and `MoveAxis` and `RETURN` before `fbStopTx.Begin()`; the transaction then
begins in the next scan (`bStopTxBegun` stays FALSE). Same for `SuspendAutomatic`. This narrows the race but cannot
remove it (one scan is no guaranteed ADS round trip), so it comes second and is not a substitute for A. Existing test
`Stop_Drops_The_Moves_In_The_First_Scan_And_Stops_By_The_Second` only covers a slew and stays valid.

### Decisions to confirm

- **D1: A or A + B.** Recommended: A + B, A first, because A is the actual guarantee and B is cheap.
- **D2: `ExtActive` source.** Recommended: the status field if it exists (what the NC says), the latch only as a
  fallback; the latch can drift if the NC drops the generator by itself on an error.
- **D3: the retarget `track` that is dropped (step 4).** Whether to fix in the same release or separately.

## Steps

Each step is one branch off `develop`, one PR, merged by Tim. No behaviour change outside the stop and retarget while
tracking.

0. **Evidence (no code).** Pull the 10 Hz logs of 14:05:54 (pass) and 14:09:12 / 10:25:44 / 11:22:42 (fail) and
   compare `StandStill`, `InMotion`, `Tracking` per axis; check `ExtSetPointGenEnabled` in the status struct in XAE.
   Output: a comment on #101. Decides D2 and tells whether the "no stop sent" path is real.
1. **MONETcommon: failing test first.** Extend the mock axis (`FB_AxisMockCore` and `FB_AzimuthMock`): input
   `bTracking`, output `bExtActive` (TRUE on Tracking, FALSE `nDisableScans` scans after Tracking falls, default 1),
   in motion while tracking, `isTracking` written; `InjectError(16#4257)` when a stop or move rises while
   `bExtActive`. New `MonetStopWhileTracking_Tests`: (a) power on, `Track`, a few scans of tracking, `Stop()`: no
   0x4257 on any axis, no error park, one stop edge per axis, the stop settles; (b) the same with a retarget `Track()`;
   (c) `SuspendAutomatic` while tracking. Pinned by mock: say so in each test comment. The mock skips `SUPER^()`, so
   the real `FB_Axis` body does not run here: these tests pin B, not A. They must fail on today's code. A failing test must not reach `develop`: the PR
   holds step 1 and step 2 together (the tests are red in the first commit, green in the last).
2. **MONETcommon: fix B** (this repo only). Tests of step 1 green, all 143 existing cases green. Release MONETcommon
   0.9.8 with the usual chain (Cut release, PR, Tim merges, Tag, Release library), pin in MONETS/MONETN by the other
   agent's release flow (not by me).
3. **BROTLib: fix A.** `F_MotionAllowed` plus tests (stop is held while `ExtActive`, released on the falling edge, a
   failed disable shows as `Error`), the gate in `FB_Axis`, `FB_Axis_Tests` for the wiring that does not need an NC
   axis. Release BROTLib 0.10.4 (library chain), then the pin bumps in HalfBROT, MONETcommon, IAG50cm, MONETS, MONETN
   as in the earlier chains. IAG50cm last, with an on-site check.
4. **Retarget `track` dropped after the abort stop.** Add a test (a retarget `Track()` while tracking ends in tracking
   the new target, or in a clear rejection) in `MonetStopWhileTracking_Tests`; if it fails, fix in MONETcommon in the
   same release as step 2 or a following one (D3). This can be part of step 1/2 if the test shows it.
5. **On-site checks (remote is enough).** On MONET/S then MONET/N: `stop=1` while tracking, at least 10 times,
   covering short (under 1 min) and long (over 10 min) tracking; `track` while tracking to a different target; pendant
   switch to manual while tracking. Pass = no 0x4257, the axes stop, tracking can be restarted without a reset. Then
   IAG50cm after step 3 (stop while tracking, retarget). Record in this file and as a comment on #101.

## Tests

- MONETcommon: `MonetStopWhileTracking_Tests` (step 1), mock extended as above. The whole MONETcommon suite must stay
  green (143 cases at 0.9.7).
- BROTLibTests: `F_MotionAllowed_Tests`, additions to `FB_Axis_Tests`; the whole suite stays green.
- Not testable off the telescope: whether the NC really rejects the stop that way, and how long the disable takes.
  That is what step 5 is for.

## Risks

- **The hypothesis is wrong.** If the race is not the cause, A and B change nothing visible. Step 0 and the mock tests
  would not tell; step 5 would, after step 2. Mitigation: step 2 (MONETcommon only, small) is released first and tested
  on site before step 3 is built on it.
- **A hold on the stop.** If the generator never reports off (NC error or a lost status), a stop would stay pending.
  The disable error joins `Error`, the transaction timeout (15 s, MONETcommon) and the 2 min IAG drop remain; add a
  test for a disable that never completes.
- **IAG50cm.** It takes fix A through the library pin only; its own staged stop does not change. IAG50cm#101 (the
  same 0x4257 on a different path, track over track) should be rechecked there after step 3.
- **Release load.** Two library releases and the pin chain on top of the refactor release of this week. The other
  agent prepares the MONETS/MONETN releases; I do not.

## Open questions

1. Does the status struct expose `ExtSetPointGenEnabled` (D2)? Answer from XAE.
2. Is the disable guaranteed to complete in one NC cycle, or can it take several (then fix B alone is useless)?
3. Does the 12 min pass come from an axis in StandStill (no stop sent)? Answer from the 10 Hz log (step 0).
