# `FB_Axis.Stop()` idempotent, `Execute` released on an aborted command (BROTLib#93, BROTLib#92)

**Status: proposed, 2026-10-21.** Plan only, no PLC code changed. Base commit: `c1707ba` (`origin/develop`,
"Merge pull request #89", BROTLib 0.9.0). Nobody else works on #92/#93 (checked 2026-10-21: no branch, no PR
mentions them). Both touch `FB_AxisCommand` and the stop path of `FB_Axis`, so they go into one branch, one PR and
one release (0.9.1), as both issues ask. Related: MONETcommon#96 (fixed in MONETcommon by PR #116,
`FB_MonetStopTransaction`), IAG50cm#108 (fixed in IAG50cm by #117, `FB_StopTransaction`), BROTLib#63 (the command
methods).

Marking used below: **[verified]** = read in the code at the base commits listed under "Caller audit", or in the
issues/PRs on 2026-10-21; **[unverified]** = my reading of how TwinCAT NC / Tc2_MC2 behaves, to be confirmed by the
first CI run (TcUnit on the user-mode runtime) or on a telescope. No TwinCAT and no TcUnit are installed on this
machine: **CI is the first compile and the first test run.**

## Problem

### #93: a repeated `Stop()` restarts `MC_Stop`

`BROTLib/BROTLib/POUs/FB_Axis.TcPOU` **[verified]**:

- `Stop()` (lines 395-408) always calls `StopCommand.Request()`.
- `FB_AxisCommand` (body, lines 25-38) turns a request into a rising `Execute`: if `Execute` is still TRUE it is
  held FALSE for one cycle first (line 30), so the MC block sees a new edge.
- `Execute` is released only one call after the MC block reported `Done` (line 35, `Done` is
  `Axis_Stop.Done` of the *previous* cycle, line 262). `MC_Stop` keeps the axis in Stopping while `Execute` is TRUE.
- `StopAllowed` (lines 256-260) does not contain Stopping, so a request made while the axis is Stopping waits
  (`Pending`) and starts as soon as the axis is StandStill.

The loop of MONETcommon#96 / IAG50cm#108, scan by scan (`m` = the scan in which `MC_Stop` reports Done):

| scan | `FB_Axis` | axis control block / caller |
|---|---|---|
| m | `Axis_Stop.Done` TRUE, `StopDone` TRUE, `StopCommand.Execute` still TRUE, axis Stopping | clears `bStopAxis` on `StopDone` |
| m+1 | `StopCommand` sees Done, releases `Execute`; `Axis_Status` (read at the top of the cycle) still Stopping | caller sees `bStopAxis` FALSE and not StandStill, writes `StopAxis := TRUE`: FALSE->TRUE edge, `Stop()`, `Request()` |
| m+2.. | `Pending` until StandStill (Stopping is not in `StopAllowed`) | |
| k | StandStill: `Execute` rises, a new `MC_Stop` on an axis at rest, Stopping again | loop |

A `Stop()` in scan m itself (after the clear) hits `Execute` still TRUE: one cycle low, then a new edge. Either way
the second call starts a second `MC_Stop`. Both telescopes now send one stop per axis and transaction, so neither
loops any more; the library still allows it.

### #92: `Execute` stays TRUE after an aborted command

`FB_AxisCommand` releases `Execute` only on `Done` (line 35) or `Reset` (line 27) **[verified]**. A command aborted by
another one (a move or a homing aborted by `MC_Stop`, a move aborted by a jog or by the setpoint generator) never
reports `Done`, so its `Execute` stays TRUE until the next command of the same kind or `Reset`.

- Seen (MONET/S, 2026-10-20, issue text): `MoveCommand.Execute` TRUE on azimuth and elevation after a `stop` during
  a power-on move. Harmless by itself: the next `MoveTo()` holds `Execute` low for one cycle and starts normally.
- Latent (from the code, never observed): `HomeActive := HomeCommand.Execute OR Axis_Home.Busy` (line 244) stays TRUE
  after a stop during homing, `Home()` is then ignored (lines 384-387) until `Reset`, and the HalfBROT axis blocks
  never clear `bHomeAxis` (`IF fbAxis.HomeDone AND NOT fbAxis.HomeActive`, e.g. `FB_AzimuthControl` line 78). A
  MONET power-on could stay at READY_STATE 0.8 (stage 10).

The issue mentions a test `Aborted_Keeps_Execute` that pins the old rule. It does not exist: `FB_AxisCommand_Tests`
has 7 cases, the closest is `Error_Keeps_Execute` (no Done = error), which stays valid **[verified]**.

## Caller audit [verified 2026-10-21]

Repos and commits read: BROTLib `c1707ba`, HalfBROT `60453e2` (develop; the local checkout is at ProjectVersion
0.5.6, tag v0.5.7 exists), MONETcommon `d9d7a6c` (0.9.3), IAG50cm `2e09ab4` (develop), MONETS `3f3e40d`,
MONETN, MONETRoof `d951af9`, AstroBROT. Searched all `.TcPOU` for `.Stop()`, `StopAxis`, `StopDone`, `MC_Stop`,
`MC_Halt`, `HomeActive`, `CommandAborted`.

**Who calls `FB_Axis.Stop()`:** only the `StopAxis` property setters of the axis control blocks, on a FALSE->TRUE
edge of the level:

- HalfBROT `FB_AxisControl.StopAxis.Set` (lines 258-262) and IAG50cm `FB_AxisControl.StopAxis.Set` (lines 97-101),
  identical: `IF StopAxis AND NOT bStopAxis THEN fbAxis.Stop(); END_IF bStopAxis := StopAxis;`. The level is cleared
  only on `fbAxis.StopDone` (HalfBROT `FB_AzimuthControl` 86, `FB_ElevationControl` 111, `FB_DerotatorControl` 90;
  IAG50cm `FB_HourAngleControl` 117, `FB_DeclinationControl` 117, `FB_FocusControl` 69). Not on Reset, not on Error.
- The other `.Stop()` hits are not `FB_Axis`: `FB_Comm_MQTT_Influx` calls `Telescope.Stop()` / `Dome.Stop()` /
  `Roof.Stop()` (interfaces), MONETRoof calls `roofs[i].Stop()` (roof blocks), MONETcommon `FB_MockStopAxis` is a test
  double.

**Who writes `StopAxis := TRUE`:**

- MONETcommon `FB_MonetTelescopeControl._StopTelescope` (lines 1790-1826) through `FB_MonetStopTransaction`: one
  stop per axis and transaction, a latched level is first written low for one scan (`abWriteLow`) so the next TRUE is
  an edge. The transaction settles when every issued axis reported `StopDone` (a `StopDone` in the scan of the write
  does not count, `abJustIssued`), or on the 15 s timeout (`bForced`, WARN, `nStopForcedCount`). `Stop()` (line 2128)
  calls `fbStopTx.Restart()` on a repeated stop (D2 of #116): new stop only for axes that are `InMotion OR InRamp OR
  Homing` and **not** Stopping. Also used by `SuspendAutomatic` (#118, lines 1330-1410).
- HalfBROT `FB_DerotatorControl` (line 53): `THIS^.StopAxis := TRUE` once on leaving the software range (R_TRIG).
- IAG50cm `FB_TelescopeControl._StopTelescope` (lines 1925-1955) through `FB_StopTransaction`: one stop per axis
  while not StandStill, `Begin()` when `TCS_command` becomes stop (line 746). **No timeout**: the transaction only
  settles when every issued and enabled axis reported `StopDone` (or on `Cancel()` at reset/error/E-stop). No
  `abWriteLow` either: a level latched TRUE from an earlier stop means the write is not an edge and `Stop()` is not
  called.
- Pendants (HalfBROT `FB_PendantControl`, MONETcommon `FB_MonetPendantControl`): jog levels only, no `Stop()`.

**Who relies on a repeated `Stop()` restarting a stop:** nobody depends on the *restart* itself. MONETcommon
`Restart()` (D2) re-sends a stop to an axis that is moving again and not Stopping; at that point the previous
`MC_Stop` has reported Done and its `Execute` was released (with #92 also if it was aborted), so the new `Stop()` is
accepted. Still works.

**Who else can put an axis into Stopping:** no other `MC_Stop` or `MC_Halt` instance on an `FB_Axis` axis in any
repo (the `FB_LatchHome` hit is a comment; it aborts its sweep with `MC_AbortHoming`). So "Stopping without our
own `Execute`" is in practice the tail of our own stop (the scans between the release of `Execute` and StandStill).
Other sources (XAE online commands, NC-internal stops on a limit or a lost `Enable_Positive/Negative`) are possible
but I do not know whether the NC reports them as PLCopen Stopping **[unverified]**.

**Readers of `FB_Axis.CommandAborted`:** none (only `FB_LatchHome`/`FB_RefMarkerSearch` read the outputs of their own
step blocks). **Readers of `HomeActive`:** the HalfBROT axis blocks (azimuth, elevation, derotator, focus), to end the
homing overrides and to clear `bHomeAxis`.

### The consequence for #93: a plain no-op would hang callers

The issue proposes "`Stop()` is a no-op while `StopCommand.Execute` or `Pending` or Stopping". With the setters above,
a call that is ignored latches `bStopAxis` TRUE and then waits for a `StopDone`. If the call came in scan m (after
the Done) or in the Stopping tail (m+1..), the stop it was folded into has *already* pulsed `StopDone`, so no further
`StopDone` comes:

- HalfBROT/IAG50cm axis blocks: `bStopAxis` stays TRUE; the next `StopAxis := TRUE` is no edge and calls nothing.
- MONETcommon: a transaction begun in that window waits for `StopDone`, then settles on the 15 s timeout with
  `bForced` and a WARN ("STOP completed without StopDone from every axis").
- IAG50cm: the transaction never settles (no timeout) until reset/error/E-stop; a gohome waiting for it is dropped
  after 2 min, i.e. the IAG50cm#108 symptom again.

So the guard needs a `StopDone` for the joined call. That is decision 1.

## Decisions

### D1. What an ignored `Stop()` does — recommended: B (no-op plus join)

- **A. Plain no-op (the issue text).** No new `MC_Stop` while `Execute`/`Pending`/Stopping, no `StopDone` for the
  ignored call. Simplest, but hangs the callers in the window above (IAG50cm without timeout, latched `bStopAxis`).
- **B. No-op plus join (recommended).** As A, and a call that arrives while the stop is already finishing (Done seen
  but `Execute` not released yet, or Stopping without our `Execute`) is *joined*: `FB_Axis.StopDone` pulses once more
  when the axis is StandStill. A call while the own `MC_Stop` is still running (`Execute`, no Done yet) is simply
  ignored, its own `StopDone` is still to come. A pending request is kept and starts as before. Every accepted or
  ignored call is therefore followed by a `StopDone`, as today, but without a second `MC_Stop`. The level setters and
  both transaction blocks need no change.
- **C. Leave `FB_Axis` as it is** and rely on the transaction blocks. Rejected: every new caller (HalfBROT
  derotator range stop, future telescopes) has to know the rule.

Effect of B on the loop table: scan m+1 `Stop()` → Stopping → joined, no request; scan k (StandStill) → `StopDone`
pulse → the caller clears `bStopAxis` and sees StandStill, writes nothing. One `MC_Stop` edge in total.

### D2. Where the logic lives — recommended: in `FB_AxisCommand`

The guard and the join are pure logic. In `FB_AxisCommand` (new method `RequestIfIdle`, inputs `Busy`/`Idle`, output
`Joined`) they can be tested in `FB_AxisCommand_Tests` with simulated Stopping/StandStill; `FB_Axis_Tests` cannot
produce Stopping without an NC axis. Alternative: inline in `FB_Axis.Stop()` with a private `StopJoining` flag
(fewer interface lines on `FB_AxisCommand`, but the join then has no test at all). The move and home channels do not
use the new inputs (they stay FALSE).

### D3. `Stop()` after a failed `MC_Stop` — recommended: retry, as today

After an `MC_Stop` error `Execute` stays TRUE (no Done, the Error is kept visible, header lines 8-9). With a plain
"`Execute` → ignore" every later `Stop()` would be ignored until `Reset`. Today a repeated `Stop()` retriggers
(one cycle low, new edge), which can be the only way to try again. Recommended: `RequestIfIdle(Failed :=
Axis_Stop.Error)` falls through to `Request()`. Alternative: ignore until Reset (the axis is in error anyway, the NC
stops it on its own **[unverified]**).

### D4. A join whose axis does not come to rest — recommended: drop it silently

If the axis leaves Stopping into something other than StandStill (Disabled, ErrorStop), the join ends without a
`StopDone`, like an `MC_Stop` that ends in an error today. Alternatives: pulse `StopDone` anyway (it would claim a stop
that did not end at rest), or request a real stop (it would run after the next enable, on an axis at rest). Both
transaction blocks already treat a disabled axis as done.

### D5. Return value of `Stop()` — recommended: TRUE only when a new `MC_Stop` was requested

Same convention as `Home()` (FALSE while `HomeActive`). No caller reads it today.

### D6. #92: what releases `Execute` — recommended: `CommandAborted` only

Release on `Done OR Aborted` (CommandAborted of the MC block from its last call). An error keeps `Execute` as before
(`Error_Keeps_Execute` stays). Whether a stop during homing makes `MC_Home` report CommandAborted or Error is not
known **[unverified]**; if it is Error, `HomeActive` still sticks after #92 (open question 2).

## Change

One branch `fix/axis-stop-idempotent-93-92` off `develop`, one PR, CI green, then release 0.9.1.

### `BROTLib/BROTLib/POUs/FB_AxisCommand.TcPOU` (sketch)

Header comment (lines 4-9): add "`Execute` is also released when the block reports CommandAborted (#92).
`RequestIfIdle()` requests only when the command is not already on its way and joins a command that is finishing
(#93)."

Declaration, additive:

```st
VAR_INPUT
	Allowed		: BOOL;		// unchanged
	Reset		: BOOL;		// unchanged; also ends a join
	Done		: BOOL;		// unchanged
	// CommandAborted of the MC block from its last call: releases Execute like Done (another command took over, #92)
	Aborted		: BOOL;
	// for RequestIfIdle (stop channel): the axis is still finishing a command of this kind (Stopping) ...
	Busy		: BOOL;
	// ... and has finished it (StandStill): a join ends with a Joined pulse (#93). Both FALSE for move and home.
	Idle		: BOOL;
END_VAR
VAR_OUTPUT
	Execute		: BOOL;
	Pending		: BOOL;
	// one cycle: a RequestIfIdle() that was joined to a finishing command has seen the axis come to rest (#93)
	Joined		: BOOL;
END_VAR
VAR
	Requested	: BOOL;
	Joining		: BOOL;		// a joined RequestIfIdle() waits for Idle
END_VAR
```

Body:

```st
Joined := FALSE;
IF Reset THEN
	Requested := FALSE;
	Execute := FALSE;
	Joining := FALSE;
ELSIF Requested THEN
	IF Execute THEN
		Execute := FALSE;		// still TRUE from the last command: one cycle low, so the next TRUE is an edge
	ELSIF Allowed THEN
		Execute := TRUE;
		Requested := FALSE;
	END_IF
ELSIF Done OR Aborted THEN		// #92: an aborted command never reports Done
	Execute := FALSE;
END_IF
// #93: a joined request ends when the axis is at rest; if it leaves Busy any other way (disabled, error stop), no pulse
IF Joining AND NOT Execute AND NOT Requested THEN
	IF Idle THEN
		Joined := TRUE;
		Joining := FALSE;
	ELSIF NOT Busy THEN
		Joining := FALSE;
	END_IF
END_IF
Pending := Requested;
```

`Request()`: add `Joining := FALSE;` (a real command reports its own Done).

New method:

```st
// Request unless this command is already on its way (#93). A pending request starts anyway; a running command
// (Execute, its Done not seen yet, no error) reports its own Done. A command that has finished while the axis is
// still Busy (Done seen but Execute not released yet, or Busy without Execute) is joined: Joined pulses once the
// body sees Idle. A failed command is retried, as Request() does. TRUE only when a new command was requested.
METHOD RequestIfIdle : BOOL
VAR_INPUT
	Busy	: BOOL;		// the axis is still finishing (stop: FB_Axis.Stopping)
	Done	: BOOL;		// the MC block reported Done in its latest call (stop: FB_Axis.StopDone)
	Failed	: BOOL;		// the MC block reports an error (stop: Axis_Stop.Error)
END_VAR
```
```st
IF Requested THEN
	RETURN;					// pending: starts as soon as Allowed
END_IF
IF Execute AND NOT Done AND NOT Failed THEN
	RETURN;					// running: its own Done is still to come
END_IF
IF NOT Failed AND (Busy OR Execute) THEN
	Joining := TRUE;		// finishing: StopDone again when the axis is at rest, no second MC_Stop
	RETURN;
END_IF
Request();
RequestIfIdle := TRUE;
```

`Done`/`Busy` are passed by the caller at call time (the `FB_Axis` outputs of the last body call), because
`FB_AxisCommand` sees `Axis_Stop.Done` only one cycle late: in scan m the body ran before `Axis_Stop` reported Done.

### `BROTLib/BROTLib/POUs/FB_Axis.TcPOU` (sketch)

Line 208:

```st
MoveCommand(Allowed := Ready AND Calibrated, Reset := Reset, Done := Axis_Modulo.Done OR Axis_Move.Done,
	Aborted := Axis_Modulo.CommandAborted OR Axis_Move.CommandAborted);	// #92
```

Line 235:

```st
HomeCommand(Allowed := Ready, Reset := Reset, Done := Axis_Home.Done, Aborted := Axis_Home.CommandAborted);	// #92
```

Lines 262-266:

```st
StopCommand(Allowed := StopAllowed, Reset := Reset, Done := Axis_Stop.Done, Aborted := Axis_Stop.CommandAborted,
	Busy := Axis_Status.Stopping, Idle := Axis_Status.StandStill);
Axis_Stop(
	Axis := 	AxisRef,
	Execute := 	StopCommand.Execute,
	Done => 	StopDone);
// #93: a Stop() joined to a stop that was already finishing reports StopDone once the axis is at rest
StopDone := StopDone OR StopCommand.Joined;
```

`Stop()` (lines 396-406):

```st
// Stop the axis (MC_Stop). Also drops pending MoveTo()/Home() requests, so they do not start after the stop.
// Idempotent (#93): while a stop is pending, running or still finishing (Stopping), no second MC_Stop is started and
// the call returns FALSE; StopDone still follows (from the running stop, or once the axis is at rest). After an MC_Stop
// error the stop is retried. TRUE when a new MC_Stop was requested.
METHOD Stop : BOOL
```
```st
MoveCommand.Cancel();
HomeCommand.Cancel();
MovePending := FALSE;
HomePending := FALSE;
Stop := StopCommand.RequestIfIdle(Busy := Stopping, Done := StopDone, Failed := Axis_Stop.Error);
```

The cancelling of pending moves/homes stays on every call (the issue asks to keep it; a repeat is harmless).

Comments: `CommandAborted` output (line 57-58): "one or two cycles after the abort: `Execute` is released on it
(#92)" **[unverified: how long Tc2_MC2 shows CommandAborted after Execute falls]**. `HomeActive` (lines 52-54): "also
ends when the homing is aborted (#92)". Declaration comment line 98: `StopCommand: FB_AxisCommand; // Stop(), idempotent (#93)`.

Unchanged on purpose: `StopAllowed`; the tracking gate `NOT StopCommand.Execute AND NOT StopCommand.Pending`
(line 178, a join does not block tracking; the axis is Stopping then anyway); `Reset` handling.

### Docs

- `specs/design/fb-axis-command-interface.md` lines 177-181 and 190: "released on `Done` or CommandAborted (#92)";
  "`Stop()` is idempotent: no second `MC_Stop` while one is pending, running or finishing; `StopDone` follows every
  call (#93)".
- `README.md` `FB_BaseAxis` / `FB_Axis` bullet (line 183 ff.): one sentence on idempotent `Stop()`.
- `BROTLibTests/README.md`: the `FB_Axis_Tests` row (line 15) gets "`Stop()` repeat"; add an `FB_AxisCommand_Tests`
  row (missing today).
- `specs/plans/index.md`: entry for this plan.

## Tests

### `FB_AxisCommand_Tests.TcPOU` (pure logic, all runnable on CI)

Each `fbCmd(...)` call is one cycle, as in the existing cases. Existing 7 cases unchanged (they leave the new inputs
FALSE). New:

1. `Aborted_Releases_Execute` (replaces the `Aborted_Keeps_Execute` the issue names): Request, call (Execute TRUE),
   call with `Aborted := TRUE` → Execute FALSE, Pending FALSE; another call → still FALSE.
2. `Request_After_Abort_Starts_At_Once`: after 1, Request → next call Execute TRUE (no low cycle needed).
3. `Request_Wins_Over_Aborted`: Execute TRUE, Request, call with `Aborted := TRUE` → one cycle low, then TRUE.
4. `Error_Keeps_Execute`: unchanged, header comment "no Done and no abort".
5. `RequestIfIdle_Twice_In_One_Scan`: two `RequestIfIdle()` before the call → TRUE, FALSE; count rising edges of
   Execute over 6 calls with Done after 3 → exactly 1.
6. `RequestIfIdle_Each_Scan_While_Running`: Request; then every scan `RequestIfIdle(Busy := TRUE, Done := FALSE)`
   before the call, Done after 3 calls → Execute never drops before Done, 1 edge.
7. `RequestIfIdle_While_Pending`: `Allowed := FALSE`; `RequestIfIdle` twice → TRUE, FALSE; Pending stays TRUE.
8. `RequestIfIdle_After_Done_Joins` (scan m): Execute TRUE; `RequestIfIdle(Busy := TRUE, Done := TRUE)` → FALSE;
   call (`Done := TRUE, Busy := TRUE`) → Execute FALSE, Joined FALSE; call (`Busy := TRUE`) → Joined FALSE; call
   (`Idle := TRUE`) → Joined TRUE; next call → Joined FALSE; no new edge, Pending never TRUE.
9. `RequestIfIdle_While_Stopping_Joins` (scan m+1, the #96 case): no Execute, `RequestIfIdle(Busy := TRUE)` →
   FALSE; Joined at the first call with Idle; no edge.
10. `RequestIfIdle_At_Rest_Gives_New_Edge` (the issue's "after StandStill again gives a new one"): full stop
    (Request, Done, released), then `RequestIfIdle(Busy := FALSE, Done := FALSE)` → TRUE, next call Execute TRUE.
11. `RequestIfIdle_After_Error_Retries`: Execute TRUE, `RequestIfIdle(Failed := TRUE)` → TRUE, one cycle low, then
    TRUE.
12. `Join_Dropped_Without_Rest`: joined, then a call with `Busy := FALSE, Idle := FALSE` → no Joined, and none later
    with `Idle := TRUE`.
13. `Reset_And_Request_End_A_Join`: joined, `Reset` → no Joined at Idle; joined, `Request()` → no Joined, a normal edge.
14. `Stop_Loop_Of_96_Gives_One_Edge` (scan model, optional but cheap): the level setter (`IF b AND NOT bLevel THEN
    RequestIfIdle(..)`), the caller rule of MONETcommon 0.9.0 (write TRUE on every scan not StandStill), and a small
    MC_Stop model (Stopping from the rising edge, Done after 3 scans, StandStill one scan after the release), 40 scans:
    exactly 1 edge, the level ends FALSE. Same model as MONETcommon `FB_MockStopAxis`; with `Request()` instead of
    `RequestIfIdle()` the same model gives several edges (MONETcommon#116 measured 7 for Done after 3 scans), which the
    test comment should quote, not assert.

### `FB_Axis_Tests.TcPOU` (no NC axis)

Without an NC the MC blocks report errors and `StopAllowed` is FALSE (all `Axis_Status` bits FALSE **[unverified:
assumed from the existing header comment]**), so a stop request stays pending. What can be checked:

15. `Stop_Twice_In_One_Scan`: `Stop()` → TRUE, `Stop()` → FALSE.
16. `Stop_Repeated_Next_Scan`: `Stop()`, `fbAxis(..)`, `Stop()` → FALSE (pending or running, whichever the runtime
    gives).
17. `Ignored_Stop_Still_Cancels_Move`: `Stop()`, call, `MoveTo()`, `Stop()` (FALSE) → `MovePending` FALSE.

Header comment: add that the join and the Stopping/StandStill side are covered in `FB_AxisCommand_Tests` and on the
telescopes. The Execute edges themselves are not observable here (`StopCommand` is private); not adding a test-only
output.

### MONETcommon (follow-up, optional)

`FB_MockStopAxis` and `StopLoop_Sim_Tests` call `BROTLib.FB_AxisCommand` directly with `Allowed/Reset/Done` and
model `Stop()` as `fbCmd.Request()`. They compile unchanged against 0.9.1 (new inputs default FALSE) and keep their
numbers. To pin the library guard there too: model `Stop()` as `RequestIfIdle(Busy := bStopping, Done := bStopDone)`
plus the `Joined` StopDone, and add one case "0.9.0 caller rule with the 0.9.1 library: 1 edge". Not required for
the release.

## Behaviour change

- A repeated `Stop()` while a stop is pending, running or finishing starts no second `MC_Stop` (#93). `StopDone`
  still follows: from the running stop, or as an extra one-cycle pulse when a joined axis reaches StandStill. A
  caller can therefore see two `StopDone` pulses for one stop (the real one, then the joined one); both setters and
  both transaction blocks only set or clear flags on it, so a second pulse is harmless **[verified by reading]**.
- `Stop()` returns FALSE when ignored (was always TRUE). No reader.
- `Execute` of an aborted move/home/stop is released (#92): `MoveCommand.Execute` no longer stays TRUE after a stop;
  `HomeActive` ends after a stop during homing if `MC_Home` reports CommandAborted; `FB_Axis.CommandAborted` becomes a
  short pulse instead of a level (no reader). HalfBROT axis blocks now clear `bHomeAxis` after such an abort once the
  axis is calibrated (`(bCalibrated AND NOT HomeActive)`), and the re-home of an uncalibrated axis can start again
  without a `Reset`.
- Unchanged: a stop on an axis at rest still runs `MC_Stop` and gives `StopDone` (the transaction blocks count on
  it); a stop on a disabled axis still waits pending; errors still keep `Execute`.

## Release and pins

1. BROTLib PR to `develop` (CI: TcBuild + TcUnit, first run of everything above), merge.
2. Release 0.9.1: `gh workflow run release.yml -f version=0.9.1` (bumps `ProjectVersion`, opens the release PR to
   `main`; merging tags `v0.9.1`). 0.9.1 = patch as the issues say; it is a behaviour change, but additive in the
   interface (new inputs/output/method, no removal) and fixes. Whatever else is on `develop` then goes along; today
   that is only CI changes after 0.9.0 (#79 and #74 are still plans).
3. Pin bumps (`DefaultResolution` `BROTLib, 0.9.1 (BROT)` in the `.plcproj`, CI reinstalls the pinned libraries),
   one PR each, no code change: HalfBROT (`HalfBROT/HalfBROT/HalfBROT.plcproj` line 102), then MONETcommon (line
   125, plus HalfBROT if HalfBROT is re-released), MONETS (`MONETSRuntime.plcproj` line 106), MONETN
   (`MONETNRuntime.plcproj` line 100), each with its usual patch release (MONETcommon after 0.9.3, MONETS after
   1.4.2, MONETN after 0.4.2).
4. IAG50cm last, after the on-site check below (`IAG50cm/IAG50cm.plcproj` line 224), as its own PR and release (after
   v0.4.0).

## On-site checks

ADS watcher or XAE online view on the axis instances; the private `StopCommand`/`MoveCommand`/`HomeCommand` of a
library `FB_Axis` should be readable online **[unverified for ADS symbol access of library internals; XAE watch works]**.
Someone watching the telescope.

### IAG50cm (needed before the IAG50cm pin, the issue asks for it)

Record per axis: `fbAxis.StopCommand.Execute`, `.Pending`, `.Joined`, `fbAxis.StopDone`, `fbAxis.Stopping`,
`fbAxis.StandStill`, `bStopAxis`, `fbStopTx.bActive`, `StateDWord` bit 29, `TCS_command`.

1. T33 step 8 of #108: track 5+ min (HA outside its target window), `gohome=1`: `TCS_command` 3→5→1 within seconds,
   one `Execute` edge per axis, `bStopAxis` back to FALSE, home starts. No "timeout during STOP".
2. Slew, `stop=1`, and `stop=1` again within 0.5 s: one edge per axis, transaction settles.
3. `stop=1` at rest: one `MC_Stop` per axis as before (StopDone, settles).
4. Stop during the calibration sweep (#113): sweep aborted, READY_STATE -2, next power-on sweeps again.
5. Focus move, `stop` during it: `fbFocus.fbAxis.MoveCommand.Execute` FALSE afterwards (#92), the next focus move runs.

### MONET/S (with the MONETS pin)

1. Step 5 of `MONETcommon/specs/plans/2026-10-20-stop-during-poweron-hang-96.md` (uncalibrated axes after a TwinCAT
   restart): `stop=1` during the stage 10 homing sweep, then `power=1`. Record `HomeCommand.Execute`, `HomeActive`,
   power-on stage. Expected with 0.9.1: `HomeActive` FALSE after the stop, power-on gets past 0.8. If `HomeActive`
   stays TRUE, `MC_Home` reported Error, not CommandAborted (open question 2). Best run once on 0.9.0 first (that is the
   pending check of #92) and once on 0.9.1.
2. `stop` during a power-on move: `MoveCommand.Execute` FALSE on azimuth and elevation (the 2026-10-20 observation).
3. `stop=1` twice during a slew: one edge per axis, `nStopForcedCount` stays 0.
4. Derotator out of range (if it can be provoked safely): one stop, `bStopAxis` cleared.

## Risks

- **The join is new behaviour on the stop path.** If Stopping/StandStill do not behave as assumed (e.g. a sample with
  neither bit between them **[unverified]**), a join is dropped without `StopDone` and the caller waits: MONETcommon
  settles on the timeout (`nStopForcedCount` > 0 shows it), IAG50cm hangs until reset. The on-site checks look for
  exactly this; `Joined` is visible online.
- `Busy := Axis_Status.Stopping` comes from `MC_ReadStatus` at the top of the cycle, `Stop()` uses the `Stopping`
  output of the last call: both one cycle old, which is what the join is built for, but nothing here was run.
- `CommandAborted` timing in Tc2_MC2 (held while Execute TRUE, how long after the release) **[unverified]**: a
  release one cycle later than assumed only delays it.
- A stop arriving while an axis is Stopping for a reason other than our `MC_Stop` is joined, not executed. No such
  source exists in the code; if the NC reports a limit stop as Stopping, the join still waits for StandStill, which
  is what the caller wants.
- Two `StopDone` pulses for one stop (see Behaviour change). Checked against all current readers; a future reader
  that counts pulses would be surprised. Documented in the `Stop()` comment.
- Everything is first compiled and tested on CI.

## Open questions (for Tim)

1. D1: join (B, recommended) or the plain no-op of the issue (A)? A needs a timeout in IAG50cm `FB_StopTransaction`
   and a latch fix in both `FB_AxisControl` setters first.
2. If `MC_Home` reports Error (not CommandAborted) when `MC_Stop` interrupts a homing, should `HomeActive` ignore an
   errored `HomeCommand.Execute` (`(HomeCommand.Execute AND NOT Axis_Home.Error) OR Axis_Home.Busy`)? Not in this plan;
   decide after MONET/S step 1.
3. D3: retry `Stop()` after an `MC_Stop` error (recommended, as today) or ignore until Reset?
4. HalfBROT: re-release for the pin only, or let MONETcommon/MONETS/MONETN pin BROTLib 0.9.1 directly and keep
   HalfBROT 0.5.7?
5. Should the axis blocks also clear `bStopAxis` on `bReset`/`bError` (today only on `StopDone`)? Independent of this
   plan; with the join the latch can no longer come from a repeated `Stop()`, but an `MC_Stop` error still latches it.

## Not in this plan

- Removing or simplifying `FB_MonetStopTransaction` / IAG50cm `FB_StopTransaction`: they stay, now a second line of
  defence (settling, timeout, `Restart`). A shared BROTLib transaction block was considered in #93 and not proposed.
- Making `StopAllowed` include Stopping (it would restart `MC_Stop` during the stop).
- The stale pending stop on a disabled axis (runs after the next enable), unchanged.
