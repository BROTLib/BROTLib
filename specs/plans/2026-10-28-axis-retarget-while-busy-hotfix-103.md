# `FB_Axis`: a new move target while a move runs is ignored by the NC, two alternating move instances (HalfBROT#103)

**Status: implemented in BROTLib on branch `fix/axis-retarget-while-busy-103`, 2026-10-28, with the recommendations of the open questions (D2 `FB_MoveChannel`, D5 wait without limit, D6 modulo gets two instances, `nSuperseded` stays internal; step 0 sim check not run, it needs XAE on the CI runner). Not compiled or run locally; CI is the first compile. Not tested on hardware (MS-73 repeat open).** Original text of the plan follows. Plan only. **Nothing implemented, compiled or run**: no PLC code changed, no XAE,
TwinCAT, tctool or TcUnit run started for this plan, nothing committed. Base: BROTLib `origin/develop` `0ddbc9f`
(0.15.0; the local checkout is 4 commits behind at `e6c0858`, `FB_Axis`/`FB_AxisCommand`/`FB_MoveFollower` are the same
in both), HalfBROT `origin/develop` `2bf4d2b` (0.9.0 tagged, 0.10.0 on the pin branch), IAG50cm `origin/develop`
`0df040e`, MONETcommon 0.10.0 tagged (0.11.0 on the pin branch). The issue lives in HalfBROT, the fix in BROTLib, so the
plan lives here (like `2026-10-21-focus-retarget-stop-range-122.md`). Related: MONETcommon#122 (the follower), BROTLib#92
(release on abort), #93 (idempotent stop), #101 (`ExtActive` gate), HalfBROT#108/#111 (focus enable).

Marking used below: **[verified]** = read in the code at the commits above, in the issue thread or in the MS-73 record;
**[unverified]** = my reading of how TwinCAT NC / Tc2_MC2 behaves, to be confirmed on a simulated axis or on the telescope.
The Beckhoff InfoSys pages for Tc2_MC2 could not be read for this plan (the fetch returned only the frameset page) and the
installed Tc2_MC2 3.3.69.0 is a compiled library, so nothing below about Tc2_MC2 internals is from the documentation.

## Problem

### What the issue shows [verified]

HalfBROT#103: a new focus target while the focus moves is stored but the running move is not changed. The focus first
reaches the old target, then moves to the new one (2026-10-22 and 2026-10-25, a wrong 40 -> 1 mm move could not be
corrected for about 2 min).

The MS-73 run on MONET/S (2026-10-28, HalfBROT 0.7.2 / BROTLib 0.10.4, 10 ms task, ADS on-change notifications, about
4000 events, script `ms73.ps1`, not in a repo yet) ruled out both earlier suspects:

| time | what happened |
|---|---|
| t0 | `focus=33` from 36 mm: `bStartMove` one cycle, `Axis_Move.Execute` TRUE, `Axis_Move.Busy` TRUE, the focus moves down at 0.2 mm/s |
| t0 + 2.5 s (12:07:17.86) | `focus=38`: `fbFollower.fTarget` 38, `bStartMove` and `bRestarted` one cycle, `MoveCommand.Execute` and `Axis_Move.Execute` FALSE for exactly one cycle then TRUE, `Axis_Move.Position` = 38 at that moment |
| after | `Axis_Move.CommandAborted` and `fbAxis.CommandAborted` never TRUE, `Axis_Move.Busy` stays TRUE, the focus keeps moving down to 33 |
| 12:07:30.49 | `MoveDone` (33 reached); the follower is off target, `bStartMove`, the focus moves up |
| 12:07:55.76 | done at 38, about 38 s after the second target was sent |

### Root cause

The chain library side is correct **[verified]**:

- `FB_MoveFollower` (`BROTLib/BROTLib/POUs/FB_MoveFollower.TcPOU:92-97`) raises `bStartMove`, sets `bRestarted`, takes
  the new `fMoveTarget` when the target moves by more than `fTolerance` while `bMoving`.
- HalfBROT `FB_FocusControl` (`HalfBROT/HalfBROT/POUs/FB_FocusControl.TcPOU:155-160`) calls `fbAxis.MoveTo()` for it;
  IAG50cm `FB_FocusControl` (`IAG50cm/POUs/FB_FocusControl.TcPOU:55-57`) does the same.
- `FB_AxisCommand` (`FB_AxisCommand.TcPOU:40-46`) holds `Execute` low for one cycle, then raises it; `FB_Axis`
  (`FB_Axis.TcPOU:228-233`) passes it and the new `Position` to the one `MC_MoveAbsolute` instance `Axis_Move`.

The NC side does not take it: **a rising `Execute` on an `MC_MoveAbsolute` instance that is still `Busy` is ignored**,
even after a full low cycle. No abort, no error, the first command runs to its end. PLCopen describes a re-triggered
busy instance as taking the new command **[unverified, from memory of PLCopen Part 1, not checked against Tc2_MC2]**;
Tc2_MC2 on MONET/S evidently does not. Whether this is the function block (an internal state machine that only looks at
the edge when idle) or the NC (refusing a new command for the same channel) is not known. That difference decides
whether the fix below works, so it is checked first (step 0 below).

`FB_Axis` always had one instance per move type (`FB_Axis.TcPOU:88-89`); the retarget never worked, it was simply not
noticed before the follower (BROTLib 0.10.0, 2026-10-21) started to re-target during a move. The design doc
(`specs/design/fb-axis-command-interface.md` "a `MoveTo()` while moving restarts with the new Position", and the
`MoveTo()` comment `FB_Axis.TcPOU:373-374`) states a behaviour that does not exist.

## Caller audit [verified 2026-10-28]

Searched all `.TcPOU` in BROTLib, HalfBROT, MONETcommon(+Tests), MONETS, MONETN, IAG50cm(+Tests) for `MoveTo(`,
`MoveDone`, `MovePending`, `CommandAborted`, `isModuloAxis`, `Axis_Move`, `Axis_Modulo`, `MoveCommand`, `.Busy`, `.Active`.

**Who re-targets a running move (calls `MoveTo()` while the axis moves):** only the two `FB_MoveFollower` users,
the HalfBROT focus and the IAG50cm focus. These are the only callers that gain anything.

**Who starts moves at rest only:** HalfBROT `FB_AxisControl.MoveAxis` setter (`FB_AxisControl.TcPOU:205-214`, FALSE->TRUE
edge -> `MoveTo()`) used by azimuth, elevation and derotator; MONETcommon `FB_MonetTelescopeControl` writes `MoveAxis :=
TRUE` only with `bStopped AND NOT bBusy` (e.g. lines 995-1005, 1256-1262); IAG50cm `FB_TelescopeControl` (lines 1325-1589,
the same pattern) and `FB_AxisControl` (IAG50cm). For these the change is neutral as long as the routing of `MoveDone`
etc. below keeps today's meaning for a single command.

**Readers of `FB_Axis.CommandAborted`:** HalfBROT `FB_FocusControl:119` (follower `bAborted`) and `:290`
(`FB_FocusManualHome.bAbortPulse := CommandAborted OR StopDone OR bError`); IAG50cm `FB_FocusControl:34` (follower).
Nobody else (IAG50cm `FB_LatchHome` reads its own step blocks).

**Readers of `MoveDone`:** the followers (both focus blocks; IAG50cm also in `bReady := Ready AND NOT MoveDone`), HalfBROT
azimuth/elevation/derotator (clear `bMoveAxis`), MONETcommon and IAG50cm telescope state machines (slew/home/park done),
`FB_AxisControl.MoveDone` getters.

**Readers of `Busy`/`Active`:** `FB_BaseAxis.Busy` (`FB_BaseAxis.TcPOU:58`), MONETcommon telescope (`bBusy` gates,
`aAxis[i].bBusy` for the stop transaction, lines 1904-1920), HalfBROT focus (`bAtRest := StandStill AND NOT Busy` for the
brake, `:183`; manual home `bMoving`, `:221`; persistent write `:388`). `Active` has no reader outside `FB_Axis`.

**Readers of `MovePending`:** HalfBROT focus (`:171` cancels a stale pending move, `:181` enable wanted).

**`isModuloAxis`:** every caller passes FALSE (HalfBROT derotator `:71`, IAG50cm focus `:73`); `Axis_Modulo` never runs
today. It gets the same treatment so the two paths stay alike (D6).

**Internals read from outside:** nothing outside `FB_Axis` references `Axis_Move`, `Axis_Modulo` or `MoveCommand` in code.
MONETcommonTests mocks (`FB_FocusMock`, `FB_AxisMockCore`) write the `fbAxis` *outputs* through pointers and do not run
the `FB_Axis` body, so they are not affected. The ADS paths in `ms73.ps1` and in the IAG test plan (`fbAxis.Axis_Move.*`,
`fbAxis.MoveCommand.*`) change (see On-site checks).

## Decisions

### D1. How a running move gets a new target: recommended A, two instances used alternately

- **A. Two `MC_MoveAbsolute` (and two `MC_MoveModulo`) instances, each new command on the other one (recommended).**
  A rising `Execute` on an idle instance is an ordinary new command; with `BufferMode` `MC_Aborting` (the Tc2_MC2 default
  **[unverified]**) the NC aborts the running move of the other instance, which reports `CommandAborted`, and the axis
  blends into the new move without stopping **[unverified for this NC, standard PLCopen behaviour; this is exactly how
  `MC_Stop` or `MC_Jog` abort a move today, and #92 relies on that `CommandAborted`]**. Cost: one more instance per move
  type and the routing of the outputs (D3). Pure logic, testable without NC (D2).
- **B. `MC_Halt`/`MC_Stop` first, then the new move.** Works with one instance, but every retarget ramps to zero and
  starts again (seconds on the focus, wrong for a fine correction), and a stop pulses `StopDone`, which ends the move in
  both followers (`bStopDone`) and `bHoldOnStop` paths. Rejected.
- **C. Make the same instance accept the retrigger** (another `Execute` timing, a different Tc2_MC2 version or NC
  setting). Nothing in the record suggests a setting; the low cycle is already there. Not plannable without the
  documentation; kept as a question to Beckhoff/InfoSys (open question 1), not as the fix.
- **D. A dedicated "change target" command.** I know of none in Tc2_MC2 for a running `MC_MoveAbsolute` **[unverified]**;
  if InfoSys shows one, it would replace A. Same open question.
- **E. Hold `Execute` low longer.** The instance stays `Busy` for the whole move, so any number of low cycles changes
  nothing (MS-73 had a full cycle). Rejected.

### D2. Where the logic lives: recommended, a new pure FB `FB_MoveChannel` that owns the move `FB_AxisCommand`

The alternation, the "free slot" gate and the routing of `Done`/`Aborted` back into the command are pure logic. In a
new BROTLib FB `FB_MoveChannel` (inputs: the outputs of the two MC instances from their last call; outputs: the two
`Execute`s and the active slot) they can be tested in `FB_MoveChannel_Tests` with an MC mock, and a scenario test can run
the real `FB_AxisCommand` and the real `FB_MoveFollower` against it. `FB_Axis` keeps only the MC calls and the wiring.
Alternative: inline in `FB_Axis` (fewer files, but untestable without an NC, which is how the bug went unnoticed).
`FB_AxisCommand` stays unchanged (home and stop use it as is, its 21 test cases stay valid).

### D3. Which instance feeds which `FB_Axis` output: only the active slot, except `Busy`/`Active`/`Error`

| `FB_Axis` output / input | today | new |
|---|---|---|
| `MoveCommand.Done` / `.Aborted` (release of `Execute`) | `Axis_Modulo.X OR Axis_Move.X` | active slot only (`FB_MoveChannel`) |
| `MoveDone` | `Done` of the instance called | active slot `Done` **AND NOT `MovePending`** |
| `CommandAborted` | OR of all MC blocks | active move slot, home, jog, stop; **not** the superseded slot |
| `Busy`, `Active` | OR | OR of both slots (the axis is busy while either runs) |
| `Error`, `ErrorID` | OR | OR of both slots (an error is reported whichever slot has it) |
| `MovePending` | `MoveCommand.Pending` | `MoveChannel.Pending` (same meaning, also TRUE while waiting for a free slot, D5) |

Why the superseded abort must not leave `FB_Axis`: the follower ignores an abort only in the cycle after the restart
(`bRestarted`, `FB_MoveFollower.TcPOU:53-56`). The abort of the old slot can arrive at the earliest two cycles after the
restart: scan n the caller calls `MoveTo()` and the body holds `Execute` low; scan n+1 the new slot gets its edge; the
NC answer is seen by the old slot's call in n+2 or later **[unverified: how many cycles the NC needs]**; the follower
reads it in n+3 or later. With today's OR the follower would end `bMoving`, start again (off target, ready) with
`MoveTo()`, which switches slots again and aborts the move it just started: a restart every few cycles until arrival.
Routing only the active slot removes that path completely, whatever the latency. The follower's `bRestarted` guard stays
as a harmless second line. The existing test `Abort_Of_Old_Move_After_Restart_Is_Ignored` models the abort in cycle n+1,
which the real chain cannot produce; its comment gets a note.

Why `MoveDone AND NOT MovePending`: a `Done` of the old move in the cycles between `MoveTo()` and the edge on the new slot
(the old move arrives just as the new target comes) would otherwise reach the follower as the end of the new move
(`fMoveTarget` already new: counted as a miss and retried, or for a state machine "slew done" for a target not reached).
Once the new slot is active the old slot's `Done` is not routed at all. Same race exists today with one instance.

`CommandAborted` of the active slot still ends the move (stop, jog, reset, the setpoint generator), as today.

### D4. Keep the one-cycle `Execute` low of `FB_AxisCommand`

With two slots the edge on the new slot does not need it, but `FB_MoveChannel` uses the rising edge of the command's
`Execute` as "a new command" (one edge per `MoveTo()` is what `FB_AxisCommand` guarantees). Keeping it costs one cycle
(10 ms) per retarget and leaves `FB_AxisCommand` untouched for all three channels. The old slot gets `Execute` FALSE from
that cycle on; a falling `Execute` does not stop a running Tc2_MC2 move (MS-73 shows it: the move went on through the
low cycle) **[verified for this NC]**.

### D5. Both slots busy: wait

Each new command goes to the other slot, and only when that slot is not `Busy` (gate in `Allowed`). After a retarget the
old slot is busy until the NC has aborted it; a third target within that time (a few cycles **[unverified]**) waits as
`MovePending` and starts as soon as the slot is free. If the NC never aborts the old slot (D1 A does not work), the third
target waits for the end of the first move: no worse than today. No timeout in this plan (open question 4).

### D6. Modulo: same two slots

`Axis_Modulo` becomes `ARRAY[0..1] OF MC_MoveModulo` with the same channel; only one of the two arrays runs
(`isModuloAxis`). No caller uses modulo today, so it is untested on hardware (open question 5: remove modulo instead).

## Change

One branch `fix/axis-retarget-while-busy-103` off `develop`, one PR, CI green (first compile and test run), then release.

### New `BROTLib/BROTLib/POUs/FB_MoveChannel.TcPOU` (sketch)

```st
// The move channel of FB_Axis (HalfBROT#103). The NC ignores a rising Execute on an MC_MoveAbsolute that is still Busy,
// so a new target during a move never took effect. Two MC instances (slots) are used alternately: each new command
// (rising Execute of the inner FB_AxisCommand, one per Request()) goes to the other slot, whose edge aborts the running
// move in the NC (MC_Aborting). Done/Aborted that release Execute come from the active slot only, so the abort of the
// superseded slot neither releases the new command nor reaches the caller. A new command waits (Pending) while the
// other slot is still Busy. Pure logic, tested without an NC axis (FB_MoveChannel_Tests).
FUNCTION_BLOCK FB_MoveChannel
VAR_INPUT
	Allowed		: BOOL;		// Ready AND Calibrated AND NOT ExtActive
	Reset		: BOOL;
	// outputs of the two MC instances from their last call
	aDone		: ARRAY[0..1] OF BOOL;
	aAborted	: ARRAY[0..1] OF BOOL;
	aBusy		: ARRAY[0..1] OF BOOL;
END_VAR
VAR_OUTPUT
	aExecute	: ARRAY[0..1] OF BOOL;	// for the two MC instances
	nActive		: INT;		// slot of the latest command (0 before the first)
	Pending		: BOOL;		// a request waits for Allowed, for the other slot to be free, or for the one-cycle low
	nSuperseded	: UDINT;	// diagnostics: aborts of a superseded slot (one per retarget that worked)
END_VAR
VAR
	Command		: FB_AxisCommand;
	rtExecute	: R_TRIG;
	rtOldAborted: R_TRIG;
END_VAR
```
```st
Command(Allowed := Allowed AND NOT aBusy[1 - nActive], Reset := Reset,
	Done := aDone[nActive], Aborted := aAborted[nActive]);
rtExecute(CLK := Command.Execute);
IF rtExecute.Q THEN
	nActive := 1 - nActive;		// a new command: the other slot, which is idle (gate above)
END_IF
aExecute[nActive] := Command.Execute;
aExecute[1 - nActive] := FALSE;	// the superseded slot keeps running until the NC aborts it
rtOldAborted(CLK := aAborted[1 - nActive]);
IF rtOldAborted.Q THEN
	nSuperseded := nSuperseded + 1;
END_IF
Pending := Command.Pending;
```

Methods `Request()` and `Cancel()` forward to `Command` (and set `Pending` like `FB_AxisCommand.Request`). `Reset`
releases `Command.Execute`, which releases both slots (both `aExecute` FALSE), so both MC blocks drop their errors.

Notes: `aDone[nActive]` in the switch cycle is the new slot's last (idle) value: FALSE, as wanted; `FB_AxisCommand` is in
its `Requested` branch then and ignores `Done` anyway. The gate uses `aBusy` of the last call; only the active slot can
become busy, so a stale value never frees a busy slot.

### `BROTLib/BROTLib/POUs/FB_Axis.TcPOU` (sketch)

Declaration, lines 88-89 and 96:

```st
	Axis_Move:		ARRAY[0..1] OF MC_MoveAbsolute;	// used alternately, see FB_MoveChannel (HalfBROT#103)
	Axis_Modulo:	ARRAY[0..1] OF MC_MoveModulo;
	...
	MoveChannel:	FB_MoveChannel;	// MoveTo()/CancelMove() (#63), retarget while moving (HalfBROT#103)
	MoveSlot:		INT;			// loop index
	aMoveDone, aMoveAborted, aMoveBusy:	ARRAY[0..1] OF BOOL;
```

Body, replacing lines 216-234:

```st
// outputs of the move instances from their last call
FOR MoveSlot := 0 TO 1 DO
	IF isModuloAxis THEN
		aMoveDone[MoveSlot] := Axis_Modulo[MoveSlot].Done;
		aMoveAborted[MoveSlot] := Axis_Modulo[MoveSlot].CommandAborted;
		aMoveBusy[MoveSlot] := Axis_Modulo[MoveSlot].Busy;
	ELSE
		aMoveDone[MoveSlot] := Axis_Move[MoveSlot].Done;
		aMoveAborted[MoveSlot] := Axis_Move[MoveSlot].CommandAborted;
		aMoveBusy[MoveSlot] := Axis_Move[MoveSlot].Busy;
	END_IF
END_FOR
MoveChannel(Allowed := Ready AND Calibrated AND NOT ExtActive, Reset := Reset,
	aDone := aMoveDone, aAborted := aMoveAborted, aBusy := aMoveBusy);
MovePending := MoveChannel.Pending;
FOR MoveSlot := 0 TO 1 DO
	IF isModuloAxis THEN
		Axis_Modulo[MoveSlot](Axis := AxisRef, Execute := MoveChannel.aExecute[MoveSlot], Position := Position,
			Velocity := Velocity, Direction := MC_Shortest_Way);
	ELSE
		Axis_Move[MoveSlot](Axis := AxisRef, Execute := MoveChannel.aExecute[MoveSlot], Position := Position,
			Velocity := Velocity, BufferMode := MC_Aborting);	// explicit; the default [unverified]
	END_IF
END_FOR
// only the active slot's arrival, and not while a new MoveTo() waits (the old move's Done is not this one's)
IF isModuloAxis THEN
	MoveDone := Axis_Modulo[MoveChannel.nActive].Done AND NOT MoveChannel.Pending;
ELSE
	MoveDone := Axis_Move[MoveChannel.nActive].Done AND NOT MoveChannel.Pending;
END_IF
```

The order of the two slot calls inside one cycle (0 then 1) means the NC sees the new command when the new slot is called;
whether the old slot is called before or after it in that cycle only shifts its abort by one cycle, which nothing reads.

Lines 303-309 (`ErrorID`), 326-331 (`Busy`), 333-342 (`Error`), 344-349 (`Active`): `Axis_Move[0].X OR Axis_Move[1].X OR
Axis_Modulo[0].X OR Axis_Modulo[1].X` (ErrorID: each of the four in turn, as today).

Lines 351-355:

```st
// the abort of a superseded move slot (a retarget, HalfBROT#103) is not reported: it is not the end of the move
IF isModuloAxis THEN
	CommandAborted := Axis_Modulo[MoveChannel.nActive].CommandAborted;
ELSE
	CommandAborted := Axis_Move[MoveChannel.nActive].CommandAborted;
END_IF
CommandAborted := CommandAborted OR Axis_Home.CommandAborted OR Axis_Jog.CommandAborted OR Axis_Stop.CommandAborted;
```

Methods: `MoveTo()` -> `MoveChannel.Request()`; `Stop()` line 416 and `CancelMove()` line 429 -> `MoveChannel.Cancel()`.
`MoveTo()` comment (373-374): "a `MoveTo()` while moving goes to the other move instance, which aborts the running move
in the NC: the axis turns to the new Position without stopping (HalfBROT#103)". `CommandAborted` declaration comment
(line 57): "not for the superseded move of a retarget".

Unchanged on purpose: the stop channel and #93 join (`StopCommand`, `Stop()` still cancels a pending move), `HomeCommand`,
the tracking section and the `ExtActive` gate (#101, it now sits in `MoveChannel.Allowed`), `StopAllowed`, `Reset`.

Stop during a retarget: `MC_Stop` aborts whatever runs; the active slot reports `CommandAborted` -> released, reported, the
follower ends the move as today. If the old slot is still busy too, its abort is counted in `nSuperseded` only.

### `FB_MoveFollower` and the callers

No code change needed: the follower already restarts correctly. Comment of `bRestarted` (`FB_MoveFollower.TcPOU:39`):
"defensive: since BROTLib 0.15.1 `FB_Axis.CommandAborted` no longer reports the superseded move". HalfBROT
`FB_FocusControl`, IAG50cm `FB_FocusControl`, the HalfBROT axis blocks and both telescope state machines: no change, only the
pin. HalfBROT `FB_FocusManualHome.bAbortPulse` gets no false abort from a retarget (none happens during a homing anyway).

### Docs

- `specs/design/fb-axis-command-interface.md`, implementation notes: a bullet "Retarget while moving (HalfBROT#103)": two
  instances, routing table of D3, the NC fact from MS-73.
- `README.md` `FB_Axis` bullet: one sentence on retarget; `BROTLibTests/README.md`: row for `FB_MoveChannel_Tests`.
- `specs/plans/index.md`: entry for this plan (done with this plan).

## Tests

No NC in BROTLibTests: the MC blocks are modelled. New test helper `FB_MoveAbsoluteMock` in BROTLibTests (pure,
per slot; a shared `FB_NcAxisMock` owns the axis): models the NC as observed on MONET/S:

- a rising `Execute` on an idle slot starts a move (`Busy` TRUE) toward `Position` at a fixed speed per cycle;
- a rising `Execute` on a **busy** slot is ignored (the #103 behaviour, so the old single-instance wiring can be shown to
  fail in the same rig);
- a new move on the other slot aborts the running one after `nAbortLatency` cycles (`CommandAborted` one cycle while
  `Execute` is FALSE, held while TRUE, `Busy` FALSE);
- `Done` on arrival (held while `Execute`, one cycle after it falls), as Tc2_MC2 **[unverified, the usual PLCopen output
  rule]**.

### `FB_MoveChannel_Tests` (pure logic)

1. `First_Request_Edge_On_One_Slot`: Request, call: exactly one `aExecute` rises, `nActive` that slot, `Pending` FALSE.
2. `Retarget_Uses_Other_Slot`: running on slot a (busy), Request: one cycle both FALSE (D4), then slot b rises, slot a stays
   FALSE, `nActive` b.
3. `Old_Slot_Abort_Does_Not_Release`: after 2, `aAborted[a]` TRUE for 1 and for 3 cycles: `aExecute[b]` stays TRUE,
   `nSuperseded` 1.
4. `Active_Slot_Abort_Releases`: `aAborted[b]` TRUE: `aExecute[b]` FALSE (#92 kept).
5. `Active_Slot_Done_Releases`: `aDone[b]` TRUE: released.
6. `Old_Slot_Done_Ignored`: after the switch `aDone[a]` TRUE: nothing released.
7. `Waits_While_Other_Slot_Busy`: slot b active and busy, slot a still busy, Request: `Pending` TRUE, no edge; `aBusy[a]`
   FALSE: edge on a next call.
8. `Not_Allowed_Waits`: `Allowed` FALSE: Pending, no edge, no switch.
9. `Cancel_Drops_Pending_No_Switch`.
10. `Reset_Releases_Both`: both `aExecute` FALSE, Pending FALSE, next Request starts normally.
11. `Error_Keeps_Execute_Of_Active_Slot` (no Done, no abort, as `Error_Keeps_Execute`).
12. `Three_Requests_Alternate`: a, b, a with the slots freed in between; `nActive` sequence 0/1 correct.

### Scenario tests in `FB_MoveChannel_Tests` (real `FB_AxisCommand` inside, real `FB_MoveFollower`, the mock NC)

The rig composes what `FB_Axis` does (the routing of D3 written once in a small test-side function, or better: the routing
moved into `FB_MoveChannel` outputs `Done`/`Aborted`/`Busy` so the rig and `FB_Axis` use the same code; to settle while
implementing).

13. `Retarget_Reaches_New_Target_Without_Finishing_Old` (MS-73 step 2 in the rig): 36 -> 33, after 250 cycles 38;
    for `nAbortLatency` 0, 1, 2, 5, 20: the position turns within `nAbortLatency + 3` cycles, ends at 38, never reaches 33;
    exactly one follower `bStartMove` for the retarget, `bMoving` TRUE until arrival, `bSettled` at 38, one `MoveDone`.
14. `Old_Wiring_Shows_The_Bug` (documentation, not a gate): the same rig with one slot (Execute straight to slot 0):
    reaches 33 first. Asserted, so the mock is shown to model #103.
15. `Superseded_Abort_Not_Reported`: the routed `CommandAborted` stays FALSE through 13 for every latency.
16. `Old_Done_While_Pending_Not_Reported`: the old move arrives in the scan of `MoveTo()` and in the low cycle: routed
    `MoveDone` FALSE.
17. `Stop_During_Retarget`: stop (modelled as an abort of every busy slot) during the window of 13: routed
    `CommandAborted` once, follower `bMoving` FALSE, no restart until a new target.
18. `Rapid_Retargets`: four targets 3 cycles apart with `nAbortLatency` 5: the last target is reached, none of the others
    is an end point, `Pending` while both slots busy.
19. `Same_Direction_Extension` and `Short_Target_Between`: MS-73 (1) and (3) in the rig.

### `FB_Axis_Tests` (no NC)

Existing 12 cases stay. New: `MoveTo_Pending_Without_Calibration_Then_Cancel` still works with the channel (renamed
internals), `Stop_Cancels_Pending_Move` (MovePending FALSE). The slot alternation itself is not observable here (MC blocks
error without NC).

### `FB_MoveFollower_Tests`

Unchanged; comment on `Abort_Of_Old_Move_After_Restart_Is_Ignored` (the real chain cannot deliver the abort in n+1).
`FB_AxisCommand_Tests`: unchanged (FB unchanged).

### MONETcommonTests / IAG50cmTests

Compile against the new BROTLib with the pins; the mocks write `fbAxis` outputs only. No new cases required.

## Verification before the release (step 0, needs Tim's go-ahead: XAE/TwinCAT on the CI runner)

The whole fix rests on "an edge on a second, idle instance aborts the busy one in this NC". Cheapest check before any
library change, on the CI machine with a simulated NC axis (no hardware): a scratch TwinCAT project with one sim axis,
two `MC_MoveAbsolute`, a 10 ms task: start a long move on instance 0, after 2 s an edge on instance 1 with another
position; record `Busy`/`CommandAborted`/`Done` of both and the set position. Also, same project: retrigger instance 0 with
one low cycle (expect the MS-73 behaviour; if the sim *does* take it, the cause is in the MONET/S setup, not in Tc2_MC2,
and D1 needs rethinking). Note the Tc2_MC2 version and TwinCAT build used. **Not started; this machine is the CI runner,
ask first.** If the sim confirms A, the hardware run below is the acceptance.

## Release and pins

1. BROTLib PR to `develop` (CI: TcBuild + TcUnit), merge.
2. Release **0.15.1** (`gh workflow run release.yml -f version=0.15.1`: bumps `ProjectVersion` and `Global_Version` on
   `develop`, opens the release PR to `main`, merging tags `v0.15.1`). Patch: a fix, additive interface (new
   `FB_MoveChannel`), no removed member; the narrower `CommandAborted` is a behaviour change with two readers, both
   followers, which want exactly that. If something else lands on `develop` first, it goes along (then 0.16.0 if that is a
   feature).
3. Pins per ADR fleet-0001 (`IAG/specs/adrs/fleet-0001-pin-org-libraries-to-releases.md`), release order BROTLib ->
   HalfBROT -> MONETcommon -> MONETS/MONETN; IAG50cm independent. Pin wave to BROTLib 0.15.0 / HalfBROT 0.10.0 /
   MONETcommon 0.11.0 is in flight on branches today (`ci/pin-brotlib-0.15.0` etc.): either let it land first and bump
   again, or retarget those branches to 0.15.1 (open question 3).
   - HalfBROT: `HalfBROT/HalfBROT/HalfBROT.plcproj:132` `BROTLib, 0.15.1 (BROT)`, release 0.10.1 (or with the pending 0.10.0).
     HalfBROT itself has no code change; the issue is closed by this release with a link to BROTLib.
   - MONETcommon: `MONETcommon/MONETcommon.plcproj:128`/`:132` and `MONETcommonTests.plcproj:197`/`:201`, patch release.
   - MONETS: `MONETSRuntime/MONETSRuntime.plcproj:106`/`:110`/`:118`; MONETN: `MONETNRuntime/MONETNRuntime.plcproj:100`/`:104`/`:112`;
     each a patch release. MONETS first (the hardware check is there).
   - IAG50cm: `IAG50cm.plcproj:239`, `IAG50cmTests.plcproj:184`, after its own focus check (below), patch release.
4. Each pin PR: CI only, no code change.

## On-site checks

### MONET/S: repeat MS-73 (IAG `specs/plans/2026-10-12-monet-telescope-test-plan.md`, MS-73 row, line 875)

Build: note `Global_Version` (BROTLib 0.15.1, HalfBROT, MONETcommon, MONETS). Telescope powered, focus calibrated, automatic
mode. Recorder at task rate (ADS on-change, as `ms73.ps1`), new symbol paths: `fbFocus.fbAxis.Axis_Move[0].Execute/.Busy/
.CommandAborted/.Done`, the same for `[1]`, `fbAxis.MoveChannel.nActive`, `.Pending`, `.nSuperseded`,
`.Command.Execute`, plus as before `fPosition`, `fActualPosition`, `fbFollower.fTarget/.fMoveTarget/.bMoving/.bStartMove/
.bRestarted/.bSettled`, `fbAxis.MovePending/.MoveDone/.CommandAborted/.Busy`, `bEnable`, `bError`, `nErrorID`.

Steps (1)-(6) of MS-73 (same direction, reverse, stop short, several targets 2 s apart, wrong target corrected, settle and
brake), plus:

7. The 2026-10-28 sequence exactly: 36 -> 33, after 2.5 s 38. Expect: the focus turns within a few cycles, never reaches
   33, ends at 38; `nActive` switched once; old slot `CommandAborted` once (record the cycle count from the new slot's edge:
   that is the NC abort latency, needed for D5); `fbAxis.CommandAborted` stays FALSE; one `MoveDone`; `nSuperseded` +1.
8. `stop=1` during a move after a retarget: stops, target follows the position (MONETcommon#122 behaviour unchanged).
9. A slew (`goto`) of azimuth/elevation/derotator and a park: unchanged (regression of the single-command path).

Pass: (1)-(5) and 7 follow the last target without finishing the first move, no error, no `MovePending` stuck TRUE.
Fail and what it means: old slot never reports `CommandAborted` and the first move finishes -> the NC refuses the second
instance too (D1 A wrong; fall back to B or ask Beckhoff); repeated restarts (`nSuperseded` climbing, many `bStartMove`)
-> routing leak, check `CommandAborted`/`MoveDone`. Send `stop=1` if the focus heads somewhere wrong.

### IAG50cm (before its pin)

Focus: `focus` command 2-3 mm, a second target after 2 s: turns, ends at the second; one telescope slew as regression.

## Risks

- **D1 A rests on an NC fact not yet seen here** (a second instance aborts the first). Step 0 checks it on a sim axis
  before anything is built; MS-73 step 7 on hardware.
- **Abort latency unknown.** Only D5 depends on it (a third target waits); everything else is routed by slot.
- **Old slot error after supersede** (the NC rejecting the abort, or an error on the old slot): reported through `Error`
  for about one cycle (its `Execute` is FALSE) **[unverified how long Tc2_MC2 shows it]**; a one-cycle `bError` makes both
  focus blocks set `fPosition := fActualPosition`, i.e. the retarget is dropped. Visible as `nErrorID`.
- **`MoveDone AND NOT MovePending`** hides a `Done` while a new `MoveTo()` waits for a long time (axis not Ready). Every
  reader wants the done of its latest command; checked against the readers above.
- **Symbol paths change** (`Axis_Move` is now an array, `MoveCommand` is inside `MoveChannel`): ADS scripts, XAE watch
  lists and the IAG test plan text referencing `fbAxis.MoveCommand.*` must be updated (MS-73 row, B8 at line 651 of the
  test plan, `2026-10-21-focus-retarget-stop-range-122.md` checks).
- Retargets on the telescope axes (none today) would now blend into the new move instead of being ignored; any future
  caller that relied on "a second `MoveTo()` during a slew does nothing" changes behaviour. None found.
- Modulo path untested on hardware (no user).
- Everything is first compiled and tested on CI.

## Open questions (for Tim)

1. Step 0: OK to run a sim-axis check on the CI runner (XAE + a scratch project), or go straight to the library change and
   MS-73? And should someone look up the Tc2_MC2 "general rules" / `MC_MoveAbsolute` page in InfoSys (offline help in XAE)
   for the documented retrigger rule? If Tc2_MC2 documents a change-target block or a retrigger option, it would replace
   two slots.
2. D2: logic in a new `FB_MoveChannel` (recommended, testable) or inline in `FB_Axis`?
3. Pins: let the in-flight 0.15.0 / 0.10.0 / 0.11.0 pin wave land and then bump again, or retarget those branches to
   BROTLib 0.15.1 before they merge?
4. D5: a third target while both slots are busy waits without limit (normally a few cycles). Add a timeout/warning, or
   leave it?
5. D6: give modulo the same two slots (recommended, keeps the paths alike) or drop the unused `MC_MoveModulo` path in a
   separate change?
6. Should `nSuperseded` (or a one-cycle `MoveRetargeted` output) be public on `FB_Axis` for telemetry, or stay an internal
   diagnostic readable online?

## Not in this plan

- Changing `FB_AxisCommand` (the one-cycle low stays, D4) or the stop/home channels.
- The follower's `bRestarted` guard (left as is).
- HalfBROTTests (no such project yet); HalfBROT has no code change.
- Retargeting the telescope axes during a slew (possible after this, not wanted by any caller).
