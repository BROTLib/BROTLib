# MQTT `focus` command only while the telescope is online (BROTLib#74)

**Status: proposed, 2026-10-20.** Plan only, no PLC code changed. Base commit: `ba2a7db` (`origin/develop`,
"Merge pull request #82", BROTLib 0.8.1 in `BROTLib.plcproj`, not tagged; last release v0.8.0). Nobody else works
on #74 (checked 2026-10-20: no branch, no PR mentions it; HalfBROT#85 "focus hunts around its target" and
HalfBROT#66 are about the focus axis, not about who may command it).

Marking used below: **[verified]** = read in the code at `ba2a7db`, or in the local `develop` checkouts of
HalfBROT, MONETcommon and IAG50cm (and MONETS on `fix/aux-temp-sensor-wire-break`) on 2026-10-20;
**[unverified]** = my reading of how TwinCAT or a client behaves, to be confirmed by a build, the TcUnit run on the
user-mode runtime or the telescope.

## Problem

MONET/S, 2026-10-19: telescope parked, covers closed, hydraulics off, cabinet selector on automatic
(`eTelescopeMode` = 2), focus calibrated and locked at 36.00. `command focus=36.5` on `MONETS/Telescope/SET`
released the brake within ~0.3 s, moved the focus to 36.50 in ~3 s and locked it again 30 s later. No error, no
log entry. Any client publishing to the topic can do this unattended.

## Root cause [verified]

`BROTLib/BROTLib/POUs/Comm/FB_Comm_MQTT_Influx.TcPOU`, `_ApplyField`, lines 154-158:

```st
ELSIF parameter = 'focus' AND Focus <> 0 THEN
	IF _ParseLREAL(parameter := parameter, value := value, fMin := -1.0E6, fMax := 1.0E6, fValue => fValue) THEN
		Focus.Position := fValue;
```

Only a garbage check. The handler gates no command on the telescope state: `park`, `slew`, `track`, `gohome`, ...
call `I_Telescope` methods (lines 68-106) and the **telescope controller** decides. MONETcommon's
`FB_MonetTelescopeControl.Slew`/`Track`/`Home` reject a move with `_AcceptMove` (#83, lines 1857-1931), which looks
at `bIsParked`, `bReady` (`F_CommandAcceptance` lines 49, 52), park/power pending, E-stop, clock. `focus`, by contrast, writes the axis directly, so no
controller ever sees it.

HalfBROT `FB_FocusControl` (used by MONET/S and MONET/N) then moves on its own: in automatic mode, calibrated,
`|fPosition - fActualPosition| > fTolerance` and drive not ready sets `bEnable := TRUE` (lines 89-101), the brake
opens (`ObFocusUnlock`, line 81), the move runs, `tonBrakeDelay` locks it again (lines 86, 103-105). Nothing there
knows the telescope state; `eTelescopeMode` is the cabinet selector, not readiness.

What the handler can see: `FB_Comm_MQTT` holds `Telescope : I_Telescope` (line 12) and `Focus : I_Focus`.
`I_Telescope` has no readiness member (properties `Altitude`, `Azimuth`, `CoverAutoOpen`, `Declination`,
`RightAscension`, methods `Home`/`Init`/`Park`/`Reset`/`Slew`/`Stop`/`Track`). The state exists, but only as
`VAR_OUTPUT fReadyState` of `FB_BaseTelescopeControl` (line 87) and of IAG50cm's standalone `FB_TelescopeControl`
(line 151), both fed by `FB_StartupControl`/`FB_StartupReadiness` (`-1` error, `0` parked, `0.3` parking, `0.7`
initializing, `0.8` calibrating, `1` online, `-2` not operational; `specs/design/telescope-ready-state.md`).

## Where the check goes: the MQTT handler (recommended)

Three places were considered:

| | Check in `FB_Comm_MQTT_Influx` (recommended) | Check in the focus axis | Route through the telescope (`Telescope.SetFocus`) |
|---|---|---|---|
| park `focusPark` | unaffected: MONETcommon park stage 0 writes `fbFocus.Position := telescopeConfig.focusPark` directly (line 1038), IAG50cm too (lines 1279, 1552) [verified] | the axis would have to move at READY_STATE 0.3 for the park but not for a client: it cannot tell who wrote `Position` | unaffected |
| startup | unaffected (MONETcommon homes the focus, line 1205-1208; IAG50cm writes `focusHome`, line 1219) | same problem as park | unaffected |
| pendant | unaffected (jog via `MovePos`/`MoveNeg`; IAG50cm pendant writes `ipFocus.Position` directly) | would block the pendant in some states | unaffected |
| repos to change | BROTLib, plus one property in IAG50cm | HalfBROT and IAG50cm (two `FB_FocusControl`s), plus a readiness input wired in every MAIN | BROTLib, MONETcommon, IAG50cm (new `I_Telescope` method with acceptance logic in both controllers) |
| state source | needs `I_Telescope.ReadyState` (below) | needs a new input | the controller's own state |

The handler check is the smallest change that closes the hole for every client, keeps the park and startup paths
as they are and needs no change in HalfBROT. The telescope route is the most consistent with #83 and stays an
option for later (open decision 5).

## Design

### `I_Telescope.ReadyState` (new, read-only)

`BROTLib/BROTLib/Interfaces/I_Telescope.TcIO`:

```st
// READY_STATE as published (see the interface comment): -1 error, 0 parked, 0.3 parking, 0.7 initializing,
// 0.8 calibrating, 1 online after complete startup, -2 not operational. Read by FB_Comm_MQTT_Influx (BROTLib#74).
PROPERTY ReadyState : LREAL		// Get only
```

`FB_BaseTelescopeControl` (MONETcommon inherits it, no change there [verified: `FB_MonetTelescopeControl` assigns
the inherited `fReadyState`, lines 645, 1271, 1739, and does not declare its own]):

```st
PROPERTY ReadyState : LREAL
// Get
ReadyState := fReadyState;
```

IAG50cm `FB_TelescopeControl` implements `I_Telescope` itself (line 4) and must add the same three lines (its own
`fReadyState`, line 151). `FB_TelescopeStub` (tests) too, see Tests.

### `FB_Comm_MQTT_Influx._ApplyField`, `focus` branch

```st
ELSIF parameter = 'focus' AND Focus <> 0 THEN
	// BROTLib#74: a client may move the focus only while the telescope is online (READY_STATE 1). Parked, parking,
	// starting up, in error, not operational, in manual mode (suspended) or with no telescope connected, the command
	// is rejected and logged. The park and startup sequences write Focus.Position directly and are not affected.
	// The range check only rejects garbage, the focus axis enforces its limits.
	IF _FocusAllowed(sPayloadRcv := sPayloadRcv)
		AND_THEN _ParseLREAL(parameter := parameter, value := value, fMin := -1.0E6, fMax := 1.0E6, fValue => fValue) THEN
		Focus.Position := fValue;
	END_IF
```

New private method:

```st
// TRUE when a 'focus' command may be applied: a telescope is connected and reports READY_STATE 1 (online).
// Logs the reason otherwise (BROTLib#74).
METHOD PRIVATE _FocusAllowed : BOOL
VAR_INPUT
	sPayloadRcv		: STRING(255);
END_VAR
VAR
	fState			: LREAL;
END_VAR
```
```st
IF Telescope = 0 THEN
	ADSLOGSTR( ADSLOG_MSGTYPE_WARN OR ADSLOG_MSGTYPE_LOG, 'MQTT focus rejected: no telescope connected %s', sPayloadRcv);
	RETURN;
END_IF
fState := Telescope.ReadyState;
// FB_StartupReadiness assigns the literal 1.0, so the comparison is exact
IF fState <> 1.0 THEN
	ADSLOGSTR( ADSLOG_MSGTYPE_WARN OR ADSLOG_MSGTYPE_LOG, 'MQTT focus rejected: telescope not online, READY_STATE %s',
		LREAL_TO_STRING(fState));
	RETURN;
END_IF
_FocusAllowed := TRUE;
```

State first, then the number: a parked telescope logs one line ("not online"), not two. `LREAL_TO_STRING(0.3)` may
print `0.3` or `0.29999...` **[unverified]**; cosmetic. Same log style as the other command warnings (ADS log
only; see open decision 4).

Why READY_STATE 1 and not "powered and not parked" (the issue's wording): MONET's `bReady` (lines 631-636) needs
covers open, all axes enabled, brake open and no error, and `_AcceptMove` refuses slews without it; READY_STATE 1
is `bReady AND bMainReady` after a completed startup (line 645-650). So "online" is exactly the state in which the
mount accepts a slew. In 0.7/0.8 the startup itself owns the focus (MONETcommon homes it and `FB_FocusControl`
overwrites `fPosition` while homing, HalfBROT lines 122-130; IAG50cm drives it to `focusHome` and waits for it,
lines 1218-1234), so a client write there would race the startup. See open decision 1.

## Edge cases

| Situation | READY_STATE | Today | With the change |
|---|---|---|---|
| parked, automatic mode (the #74 case) | 0 | focus moves | rejected, logged |
| park running, client sends focus after stage 0 wrote `focusPark` | 0.3 | client value wins, focus parks at the wrong position | rejected, focus ends at `focusPark` |
| startup running / calibrating | 0.7 / 0.8 | value lost when homing overwrites `fPosition`, or races IAG50cm's `focusHome` | rejected |
| online | 1 | moves | moves (unchanged) |
| online, then covers closed (`cover_close`) or main power lost | -2 | moves | rejected (slews are rejected too) |
| error / E-stop | -1 | `FB_FocusControl` moves if the drive is fine | rejected |
| cabinet key on local (manual), MONET MAIN calls `SuspendAutomatic` (MONETS MAIN lines 100-118) | 0 or -2 | `Position` stored, the focus moves **later**, when the selector goes back to automatic | rejected, nothing stored |
| `Telescope` not connected (`Focus` only) | n/a | moves | rejected (open decision 3); no known consumer does this: MONETS, MONETN and IAG50cm wire `Telescope` [verified] |
| `command focus=36.5,slew=1` while parked | 0 | focus moves, slew rejected by the controller | focus rejected here, slew still passed to `Telescope.Slew` (the controller rejects it, as today) |
| `focus=abc` while online | 1 | rejected by `_ParseLREAL` | unchanged |
| `focus=abc` while parked | 0 | rejected by `_ParseLREAL` | rejected as "not online" (one line) |
| focus rejected, telescope comes online a second later | 0.7 -> 1 | n/a | command lost; the client sends it again. Not buffered on purpose |
| IAG50cm parked | 0 | `Position` stored, no motion (its `FB_FocusControl` moves only when enabled, lines 19-55, and park disables it, line 1386); overwritten by `focusHome` at the next startup | rejected; IAG50cm was not exposed to the motion, the change only adds the log |

## Tests

### `BROTLibTests/.../FB_TelescopeStub.TcPOU`

Add `VAR_INPUT fReadyState : LREAL := 1.0;` and `PROPERTY ReadyState : LREAL` (Get: `ReadyState := fReadyState;`).
Required anyway: the stub implements `I_Telescope` and stops compiling without it. Default 1.0 keeps every
existing test meaning the same (none of them sends `focus`).

### `FB_FocusStub` (new, tests)

`FUNCTION_BLOCK FB_FocusStub EXTENDS BROTLib.FB_BaseAxis IMPLEMENTS BROTLib.I_Focus` with an empty
`_StartHoming` (the only abstract member of `FB_BaseAxis`, line 117 [verified]); `Position` get/set come from
`FB_BaseAxis`. Declared as `focus : FB_FocusStub(comm := 0);` **[unverified that FB_BaseAxis, which contains an
`FB_Axis`, instantiates without an NC axis here; `FB_Axis_Tests` suggests it does]**. Fallback: a standalone stub
implementing the 15 members of `I_BaseAxis` (14 properties and `Reset`), recording `Position` writes.

### `FB_Comm_MQTT_Influx_Tests.TcPOU`

Wire `fbComm.Focus := focus;` next to `fbComm.Telescope := stub;` (line 34). `ResetHandler` sets
`stub.fReadyState := 1.0` and `focus.Position := 10.0`. New cases (assert `focus.Position`, delta 1e-9):

1. `Focus_Rejected_While_Parked`: `fReadyState := 0.0`, `'command focus=36.5'` gives 10.0 (the #74 case).
2. `Focus_Rejected_Unless_Online`: the same for 0.3, 0.7, 0.8, -1.0, -2.0.
3. `Focus_Applied_When_Online`: 1.0 gives 36.5.
4. `Focus_Rejected_Without_Telescope`: `fbComm.Telescope := 0`, then restore `stub`; gives 10.0 (or 36.5 if open
   decision 3 goes the other way; the test states it either way).
5. `Focus_Garbage_Still_Rejected_When_Online`: `focus=abc`, `focus=1e7`: 10.0.
6. `Focus_Gate_Does_Not_Touch_Other_Fields`: parked, `'command elevation=50,azimuth=150,focus=36.5,slew=1'`:
   focus 10.0, `stub.nSlew = 1` (the handler still forwards the slew; deciding it is the controller's job).

The ADS log lines are not observable from TcUnit (same as #79); checked by hand. Update the suite's header comment
and the `FB_Comm_MQTT_Influx_Tests` row in `BROTLibTests/README.md` (line 20), and add `FB_FocusStub` to the list
of helpers there. `testing/check_influx_and_logic.py` is not extended: the gate is one comparison, nothing to port.

A property test for `FB_BaseTelescopeControl.ReadyState` is not proposed: it is abstract and returns a variable.
IAG50cm and MONETcommon have no test for it either; the hardware run covers it.

## README

`README.md`, after the list of commands (line 228, "... `MirrorCovers`)."), add:

```markdown
`focus` is applied only while the telescope reports READY_STATE 1 (online, `I_Telescope.ReadyState`); parked,
parking, starting up, in error or with no `Telescope` connected it is rejected with a log entry (BROTLib#74). The
park and startup sequences set the focus themselves and are not affected.
```

and in the interface table (line 111) the `I_Telescope` row becomes "Generic telescope (command interface,
coordinate handling, `ReadyState`, telemetry)".

## Version

A new member of `I_Telescope` breaks every block that implements the interface itself (IAG50cm's
`FB_TelescopeControl`, the test stub) until it adds the property: minor bump to **0.9.0** in
`BROTLib/BROTLib/BROTLib.plcproj` (`ProjectVersion`, line 22, now the unreleased 0.8.1, which then is skipped), as a
separate "Bump version to 0.9.0" commit. All consumers reference `BROTLib, * (BROT)` (newest installed)
[verified in the HalfBROT, MONETcommon, MONETS, MONETN and IAG50cm `.plcproj`]: as soon as 0.9.0 is installed on a
machine, IAG50cm builds there fail until its property is merged **[unverified exact compiler message]**. Order:
IAG50cm PR ready before the BROTLib release, merged right after it.

## Hardware / manual re-test on MONET/S

`C:\Program Files\mosquitto\mosquitto_pub.exe -t MONETS/Telescope/SET -m ...`, someone watching the focus
(`MONETS/Telemetry/telescope` `POSITION.INSTRUMENTAL.FOCUS.CURRPOS` and the brake output), XAE attached for the
Error List (the warning goes to the ADS log, not to `MONETS/Log`):

1. Parked, selector on automatic, focus at 36.00: `command focus=36.5`: no brake release, no motion, one warning
   `MQTT focus rejected: telescope not online, READY_STATE 0`.
2. `command power=1`; while READY_STATE is 0.7/0.8, `command focus=36.5`: rejected; the startup completes normally.
3. Online (READY_STATE 1): `command focus=36.5`: moves to 36.50, no warning. `command focus=36.0`: back.
4. `command focus=36.5`, wait, then `command park=1`; during the park (0.3) `command focus=37`: rejected; the
   focus ends at `focusPark` (36.0) and the park completes.
5. Parked, cabinet key on local (manual): `command focus=36.5`: rejected. Key back to automatic: the focus does not
   move.
6. With pyobs: one focus series while online, to see that a normal client is not affected.

MONET/N: steps 1 and 3 after its next deploy. IAG50cm: steps 1 and 3 after the IAG50cm change (`50cm/Telescope/SET`).

## Other repositories [verified 2026-10-20 unless marked]

- **IAG50cm** (private): `FB_TelescopeControl` needs `PROPERTY ReadyState : LREAL` (Get `ReadyState :=
  fReadyState;`). No other change; its park/startup focus writes are direct. Separate PR, see Version.
- **MONETcommon**: no change (inherits the property). `FB_MonetCabinetControl` and `FB_MonetMqttWatchdog` hold an
  `I_Telescope` but only call `Park()`; MONETcommonTests has no `I_Telescope` implementation [verified by search].
- **HalfBROT**: no change. `FB_FocusControl`'s self-enable stays (the park needs it).
- **MONETS, MONETN**: no change, rebuild against 0.9.0.
- **pyBROT** (`src/pybrotlib/components/focus.py`, line 10): `set()` publishes `command focus=<x>` and returns; it
  does not check READY_STATE. A rejected command looks like a focus that never moves. Whether the pyobs focuser on
  top waits for the position and times out is **[unverified]**; worth knowing before a night with a parked
  telescope and a focus script.
- **Not checked:** dummyBROT (if it emulates the handler, it should reject `focus` the same way), BROTgui and
  BROTweb focus controls (a code search found nothing; not read), Node-RED or scripts on the site machines.

## Open decisions (for Tim)

1. **Gate: READY_STATE = 1 only (recommended), or "powered and not parked/parking/error" (also 0.7, 0.8, -2)?**
   1 matches what the mount accepts for a slew and keeps the startup in charge of the focus. The wider gate
   would allow focusing with covers closed after startup (-2), at the cost of letting clients race the startup.
2. **`ReadyState` on `I_Telescope` (recommended: explicit, breaks IAG50cm's build once, one property to add) or an
   optional interface queried with `__QUERYINTERFACE` (no break, but a consumer without it is either unprotected
   or loses `focus` over MQTT silently)?**
3. **No `Telescope` connected: reject (recommended, fail-safe; no known consumer affected) or keep today's
   behaviour?**
4. **Also publish the rejection on `<telescope>/Log`** so the sender sees it? Same question as #79 decision 2;
   still no command warning does it. Suggest the separate issue for all command warnings.
5. Later, if wanted: move the decision into the controllers (`Telescope.SetFocus()` with `_AcceptMove`-style
   rules, #83), which would also let a site allow focusing in more states. Not needed for #74.

## Not in this plan

- Other commands that move hardware without a telescope gate in the handler: `derotator`/`derotatoroffset`,
  `filter`, `nasmyth`, `cover_open`/`cover_close`, `dome_*`. On MONET only `Roof` is wired besides the telescope and
  focus (MONETS MAIN lines 185-188); worth one look per site in a follow-up, not part of #74.
- Authentication of the command topic (#27).
- The focus hunting around its target (HalfBROT#85) and the stored position in manual mode (HalfBROT#66).
