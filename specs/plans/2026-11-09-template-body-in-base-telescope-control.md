# Template body in `FB_BaseTelescopeControl` (BROTLib#25 step 5.4, IAG plan step 4)

**Status: proposed, nothing implemented, compiled or run.** Written 2026-11-09 from the code only. It is the plan for the step that
`2026-11-09-iag50cm-command-model-unification.md` keeps as "Step 4 (checkpoint)" and `2026-10-21-telescope-state-machine-unification.md`
calls 5.4: the shared command body of the two telescope controls moves into `FB_BaseTelescopeControl` as a template body with hooks,
and MONETcommon's `FB_MonetTelescopeControl` (AltAz) and IAG50cm's `FB_TelescopeControl` (RaDec) implement only what differs.

**Base commits** (read 2026-11-09): BROTLib `origin/develop` `f9dbde3` (0.19.0), MONETcommon `develop` `3cccad1` (0.18.0 + #232,
pins BROTLib 0.18.0 / HalfBROT 0.13.0), IAG50cm `develop` `94d9a0c` (0.8.0, tagged 2026-11-09 14:02, pins BROTLib 0.19.0), HalfBROT
`3963fcc` (0.14.0, pins BROTLib 0.17.1), MONETS `d6985f8` / MONETN `709ec43` (1.6.4, pin BROTLib 0.19.0, HalfBROT 0.14.0, MONETcommon 0.18.0).

**Marking.** **[verified]** = read in the code at these commits, with `file:line` (`.TcPOU` lines, XML wrapper included);
**[unverified]** = assumption or TwinCAT behaviour, to be settled by CI or on site; **[design]** = proposed here. Short names:
**B** = `BROTLib/BROTLib/BROTLib/Telescope/FB_BaseTelescopeControl.TcPOU`, **A** = `.../Telescope/FB_CommandArbiter.TcPOU`,
**M** = `MONETcommon/MONETcommon/MONETcommon/FB_MonetTelescopeControl.TcPOU`, **I** = `IAG50cm/IAG50cm/POUs/FB_TelescopeControl.TcPOU`,
**MT** = `MONETcommon/MONETcommonTests/.../POUs/`, **IT** = `IAG50cm/IAG50cmTests/.../POUs/`, **P** = `HalfBROT/HalfBROT/HalfBROT/POUs/FB_PendantControl.TcPOU`.

## 1. Purpose and go/no-go summary

Purpose: one copy of the command skeleton (edges, error clear, supersede, arbiter wiring and apply, dispatch, release, snapshot) instead
of two that must be kept in step by hand; the per-telescope code becomes a set of named hooks. Acceptance for every code step: CI green,
**MONETcommonTests (35 suites, about 320 tests) and IAG50cmTests (22 suites, about 120 tests) green with no test edited** (counts from
a grep of `MAIN.TcPOU` and `TEST('...')`, approximate).

| Go condition (IAG plan, Step 4) | State 2026-11-09 | Evidence |
|---|---|---|
| 1. 3C one observing week on IAG50cm, no rollback; both rig suites green unedited | **not met yet**: 3C is in IAG50cm 0.8.0, tagged today; activation and the week are pending [unverified whether activated]. MONETcommon `develop` has #232 unreleased | `git log v0.8.0` |
| 2. Same skeleton order, every difference inside a hook | **met for the order, not for "the hook table"**: the order matches (section 2.2), but the differences need about 30 hooks, not the six names of the IAG plan table. Two differences are a small move each (gate, error park), one becomes one big hook (MONET error reaction) | section 4 |
| 3. No new policy input beyond `bParkWinsOverPowerOn` and the pre-step/post-hook pair | **met by the design**: both pass `bParkWinsOverPowerOn := TRUE` (M:793, I:627); every other hook is structure (where code sits), not a switch | section 3.2 |
| 4. Ripple accepted | **for Tim**; this plan adds two findings: the strict MONETcommon enums keep the acceptance in the subclasses (3.4), and HalfBROT's source is not touched (3.6) | section 6 |
| 5. Cost below keeping two bodies | **for Tim**; about 235 lines of skeleton per body become shared; cost about 9 PRs, 20-30 CI runs, three full on-site checks | section 7 |

**Recommendation: a staged go.** Do the local steps first (S1-S3: each telescope reshapes its own body into exactly the template text
calling local methods, plus the two small IAG moves). They change no library, make go condition 2 checkable by a plain `diff` of the two
bodies, and are useful even if 5.4 stops there. Decide the breaking BROTLib move (S4-S8) when S2/S3 are merged, the diff is empty and
condition 1 is met. **No-go** at any point = stop after S3 (decision 2 of the 2026-10-21 plan allows stopping after the arbiter).

## 2. Current state [verified unless marked]

### 2.1 Inheritance and members

- B is `FUNCTION_BLOCK ABSTRACT ... IMPLEMENTS I_Telescope` (B:4). Its body is only the telemetry cadence (B:129-138); neither subclass
  runs it (no `SUPER^()` in M or I bodies). B already has `METHOD PROTECTED _UpdateClock` (B:254-265), the VARs `rtrigReset`,
  `bInterrupted` (B:66-67), `tonPowerTimeout`, `tonCommandTimeout`, `tonTrackingDelay` (B:71-73), `tonMQTTTimer` (B:86).
- B's default command methods write the inputs: `Home` B:341, `Init` B:348, `Park` B:355, `Reset` B:364, `Slew` B:401, `Stop` B:408,
  `Track` B:421, against the contract B:12-26. M and I override all seven (M:2682-3001, I:2641-2880), so the defaults never run.
  `_PublishTelemetry` still reads the input `bSlew` (B:189, B:205); M works around it (M:1667-1680).
- `FB_AltAzTelescopeControl` and `FB_RaDecTelescopeControl` are `ABSTRACT`, bodies `SUPER^();` (AltAz:31, RaDec:27). M `EXTENDS
  FB_AltAzTelescopeControl` (M:4), I `EXTENDS BROTLib.FB_RaDecTelescopeControl` (I:4).
- `ABSTRACT` methods compile on this build (`FB_BaseAxis.TcPOU:117 METHOD ABSTRACT _StartHoming`, `FB_Comm_MQTT.TcPOU:147`), so do
  `PROTECTED` methods (B:254, HalfBROT `FB_AxisControl.TcPOU:73`). `PROTECTED ABSTRACT` together is not used anywhere [unverified].
- Declared in **both** M and I (name clash when moved): `b*Active` x8 (VAR_OUTPUT, M:86-93, I:161-168), `b*Checked` x8 (M:216-223,
  I:68-69), `bMoveAbortPending` (M:170, I:73), `bParkAfterStop` (M:225, I:120), `bSupersedeRequest`/`eSupersedeKeep` (M:211-212,
  I:78-79), `fbArbiter`, `bRequestIdle` (M:182-183, I:74, 76), `fbStartup` (M:96, I:33), `nTimeDivisor` (VAR_INPUT `UDINT := 1`, M:32,
  I:12), `bSoftwareError` (M:106, I:70), `fbStopTx` (M:180, I:88), `aAxis` (`ARRAY[1..3]` M:174, `[1..2]` I:64), the reject bookkeeping
  (M:201-209, I:122-129). Types differ: `nSoftwareErrorID` UINT (M:107) vs UDINT (I:71); `eLastRejectReason` is MONETcommon's local enum
  in M (M:203) and `BROTLib.E_CommandRejectReason` in I (I:124).
- Same job, different names: `bInterupted` (I:72, 18 uses) vs B's `bInterrupted` (B:67, used by M, 31 uses; I uses none); `bPowerParked`
  (I:103) vs `bPowerAbortedByPark` (M:227); `eLastTimeoutCommand` (I:80) vs `eTimeoutCommand` (M:171).
- All stage machines are `PRIVATE` and their return types differ: `_PowerOn : BOOL` (M:1365) vs `: USINT` (I:1933, I uses the stage it
  returns, I:663), `_HomeTelescope : BOOL` (M:1155) vs `: USINT` (I:1585). `_ReadAxes`, `_HandleReset`, `_LogEvents` are `PRIVATE`,
  no return, in both; `_ComputeTargets` exists only in M (M:2231), I computes its targets inline (I:308-410).
- **MONETcommon still compiles its own acceptance units**: `F_CommandAcceptance`, `ST_CommandState`, `E_CommandDecision`,
  `E_CommandRejectReason`, `F_CommandRejectText` (`MONETcommon.plcproj:25-64`), called unqualified (M:3007, 3045, 2017). They are not a
  copy any more: they add the #72 row `init_required` (MONETcommon `F_CommandAcceptance` vs BROTLib's: three extra lines;
  `E_CommandRejectReason.TcDUT:19`). Both enums are `{attribute 'strict'}`, and MT compares `rig.fbTel.eLastRejectReason` with
  `MONETcommon.E_CommandRejectReason.*` (33 places; 69 more references to `MONETcommon.F_CommandAcceptance`, `ST_CommandState`, `E_CommandDecision`) and has its own `F_CommandAcceptance_Tests`. This corrects the 2026-11-09 brief
  ("both use `BROTLib.F_CommandAcceptance`"): only I does (I:1201).
- Tests read moved members through the instance: `bParkActive` (139 reads), `bStopActive` (72), `bMoveAbortPending` (28),
  `bParkAfterStop` (10), `TCS_command` (11, already a B member), `bSettled` (5, IAG). No test reads `b*Checked`, `bInterupted`,
  `bSupersedeRequest`, `fbArbiter` (grep of `fbTel.` in MT and IT). `FB_MonetTelescopeProbe EXTENDS MONETcommon.FB_MonetTelescopeControl`
  (MT) overrides the body with no `SUPER^()` and only sets `fReadyState`.
- `P:14` holds `fbTelescope : REFERENCE TO FB_AltAzTelescopeControl` and uses `bPower`, `bGoHome`, `bPark`, `bGoto`, `bTrack`, `bReset`,
  `bStop`, `bError`, `fRightAscension(Calc)`, `fDeclination(Calc)`, `fElevationOffset`, `fAzimuthOffset` (P:251-297). None of them moves
  or is renamed. No MONETS/MONETN/MONETcommon POU instantiates HalfBROT's `FB_PendantControl` (IAG50cm has its own).
- I_ interfaces: `I_Telescope` (`Interfaces/I_Telescope.TcIO`: Altitude, Azimuth, CoverAutoOpen, Declination, Home, Init, Park, Reset,
  ReadyState, RightAscension, Slew, Stop, Track), `I_AltAzTelescope`, `I_RaDecTelescope`: no signature changes are proposed.
- Pins today: a runtime project pins a newer library than its libraries were built on and is green (MONETS: BROTLib 0.19.0 over MONETcommon
  0.18.0 built on 0.18.0 and HalfBROT 0.14.0 built on 0.17.1). So the top project's pin decides [inferred from green CI, not proven].

### 2.2 Side-by-side of the bodies (M:342-1038, about 700 lines; I:174-995, about 820 lines)

| # | Block | M | I | Same? |
|---|---|---|---|---|
| 1 | Edges stop, park, reset, power -> methods | 348-359 | 175-186 | same |
| 2 | Move edges (gate, `_AcceptMove`) | 575-597, **after** the error computation | 190-207, **at the top** | **diff 1** |
| 3 | `fbStartup.BeginScan` | 363 | 212 (after `_ReadAxes` 209) | same, order of `_ReadAxes` differs (neutral by reading) |
| 4 | Clock and "no valid time" stop | 376-385 (`bStopActive := TRUE`) | 214-223 (`_AutoStop()`) | same, stop flavour differs |
| 5 | Site inputs | Dut1 369-373, `_MotionConfig` 388, `_ReadAxes` 390, `_StopTxInputs` 392 | cabinet 226-227 | hook |
| 6 | `_HandleReset` | 394 (M:2054-2111) | 229 (I:1333-1421, gated trigger, request part on every edge) | hook (both exist) |
| 7 | Software-config errors, error ID, axis reset, `fSlewTime`, `bError` | 398-449 (first errored axis) | 232-268 (all errored axes, second pass #11/#55/#103) | hook |
| 8 | Error reaction | 451-568: hydraulics ramp, power-failure ramp, timeout park, focus-error park, roof request | 270-275: #100 `bIsPowered` | **diff 3**, one hook |
| 9 | Error clears latches, abort stop, supersede | 599-618 | 277-290 | same; axis disable/cabinet LED is a hook |
| 10 | Brake on elevation error | 620-630 | none | in hook 9 |
| 11 | Error park (`F_ErrorParkRequest`) | 710-722, **after** supersede | 292-305, **before** targets | **diff 2** |
| 12 | Targets | `_ComputeTargets` 635 | inline 308-410 | hook |
| 13 | Guards | horizon 637-644 | calibration lost, horizon and pole limits with #84, target horizon/pole 412-501 | hook |
| 14 | Timers | 646-658 (from the request, `stMotionUsed`) | 504-546 (#75 dispatch-gated, #197 park pending, 2 min home pending, #83 idle park once) | hook |
| 15 | `bInterrupted` auto-clear | 660-676 | none | in hook 14 (M) |
| 16 | Supersede | 680-708 | 551-579 | same; timer restart is a hook |
| 17 | Cover park, E-stop/safety park | 723-771 | none | hook (with 11) |
| 18 | Park pre-step | none | 588-611 | hook, default "not held" |
| 19 | Arbiter wiring, `bRequestIdle`, call | 779-796 | 613-634 (+`bWas*`) | same except `bEmergencyPark`, `bStopped` |
| 20 | Apply clears, interrupts, abort, power-aborted-by-park | 800-847 | 637-705 (+sweep stop #113/#197/#198, park/home end texts) | same; interrupt extras are hooks |
| 21 | Stop ignored in the in-place park (#196) | none | 706-709 | post-hook |
| 22 | `TCS_command`, idle drop | 849-859 (`Tracking` property) | 711-719 (`bTracking`) | same; drop is a hook |
| 23 | Timeout restart on a new command | 863-866 | 722-730 (+`fbStopTx.Begin`) | same; Begin is a hook |
| 24 | Dispatch and per-command timeouts | 868-900 (`stMotionUsed`) | 732-764 (12 h, 30 s, 2 min) | same; values are a hook |
| 25 | After dispatch | stop transaction cancel 901-905, Wake&Shake brake 907-939 | none | hook |
| 26 | Status (`bSlewing`/`bSliding`, tracking delay, `bStopped`, stop monitor, homed/ready/busy) | 941-967 | 767-876, in-place park state 880-922 | hook |
| 27 | READY_STATE update, motion state | 971-984 | 923-936 (`Parking` adds `bSafeParked`; `bSliding`) | same; two small hooks |
| 28 | Stop release, park after stop | 987 (`_StopTxRelease` M:2430-2443) | 941-951 | same by reading; settle test is a hook |
| 29 | Reset release | 995-997 | 954-956 | hook |
| 30 | End-of-scan safety disable | 1000-1007 (`bSafetyStop`, covers stop) | 958-961 (E-stop) | hook |
| 31 | READY_STATE publish | 1011-1013 | 964-966 | same |
| 32 | Telemetry cadence and send | 1014-1023 (0.5/1 s, `_SendTelemetry`) | 969-978 (1/5 s, `_SendTelemetryEquitorial`) | same; period and send are hooks |
| 33 | `_LogEvents` | 1026 | 982 | hook |
| 34 | Snapshot `b*Checked` | 1031-1038 | 985-995 (+`bHomeByCommand` clear) | same; extra is a hook |

## 3. Target design [design]

### 3.1 Template body of `FB_BaseTelescopeControl` (order is final; hooks in *italics*, defaults in section 3.2)

1. Edges: rising `bStop`/`bPark`/`bReset`/`bPower` vs `b*Checked` -> `Stop()`, `Park()`, `Reset()`, `Init()` (M:348-359).
2. `bPowerActive := fbStartup.BeginScan(Power := bPowerActive, Ready := bReady)`; *`_ScanBegin()`*.
3. `IF NOT _UpdateClock() AND (bGotoActive OR bSlewActive OR bTrackActive) THEN` *`_AutoStop()`*.
4. *`_ReadInputs()`*, *`_HandleReset()`*, *`_ReadErrors()`* (sets `nErrorID`, `fSlewTime`, `bError`), *`_ErrorReaction()`*.
5. Move edges (the gate, here for both): `bGoHome` -> `Home()`; `bGoto`/`bSlew`/`bTrack` -> `IF` *`_AcceptMove(e, no_command)`* `THEN`
   *`_OnMoveEdgeAccepted(e)`*; latch `:= TRUE`. Nested IFs as today (no short-circuit in ST).
6. `IF bError THEN` drop goto/slew/track/gohome, `bMoveAbortPending`, `bSupersedeRequest` `END_IF`; *`_ApplyError()`*;
   `IF NOT bError THEN nErrorID := 0`.
7. *`_ComputeTargets()`*, *`_Guards()`*, `tonCommandTimeout()`, *`_Timers()`*.
8. Supersede (M:680-708) with `bInterrupted` one-shot around *`_DoGoHome()`*, *`_DoGoto()`*, *`_DoSlew()`* and
   *`_RestartMoveTimeout(eSupersedeKeep)`*.
9. *`_ParkRequests()`* (error park and the other automatic parks: diff 2 resolved to this place).
10. `bParkHeld := FALSE; IF bParkActive AND NOT bStopActive AND NOT bPowerActive AND NOT fbStartup.Initializing AND NOT (bMoveAbortPending
    AND NOT bError) THEN bParkHeld :=` *`_ParkPreStep()`* (the gate of I:589).
11. Arbiter inputs as M:779-793 with `bPark := bParkActive AND NOT bParkHeld`, `bEmergencyPark :=` *`_EmergencyPark()`*, `bStopped :=`
    *`_AtRest()`*, `bParkWinsOverPowerOn := TRUE`; `bRequestIdle`; `bWas*` (I:630-633); `fbArbiter()`.
12. Apply (M:800-847): `MarkAbortedIfStarting`, clears; `bInterrupted := TRUE`, *`_InterruptPower()`*, *`_InterruptPark()`*,
    *`_InterruptGoto()`*, *`_InterruptSlew()`*, *`_InterruptGoHome()`* (each only if its `bInterrupt*`), `bInterrupted := FALSE`;
    `bMoveAbortPending`, `bPowerAbortedByPark`; *`_AfterArbiter()`*.
13. `TCS_command` from `eCommand`, or idle with *`_DropAxisCommands()`*; on a changed command `tonCommandTimeout(IN := FALSE)`,
    `eTimeoutCommand`, *`_OnCommandChanged()`*.
14. Dispatch `CASE` on `TCS_command` -> *`_DoPowerOn()`* ... *`_DoTrack()`*, *`_DoStop()`*, `tonCommandTimeout(IN := ..., PT :=`
    *`_CommandTimeout(TCS_command)`*`, nDivisor := nTimeDivisor)`, `TCSCTOEvent.OnMessage` (identical strings); *`_AfterDispatch()`*.
15. *`_UpdateStatus()`*; `fReadyState := fbStartup.Update(Error := bError OR bSoftwareError OR bPowerFailure OR bEstopTriggered, Parked :=
    bIsParked, Parking :=` *`_ReadyStateParking()`*`, Operational := bReady AND bMainReady AND NOT bEstopTriggered, AbortExtra :=
    bEstopTriggered)`; motion state from `bStopped`, *`_IsSlewing()`*, `bBusy`, `bTracking`.
16. `_ReleaseStop()` (base method, also called by M's `SuspendAutomatic`, M:1613): `IF` *`_StopSettled()`* `THEN bStopActive := FALSE;
    IF TCS_command = stop THEN bMoveAbortPending := FALSE;` *`_OnAbortStopReleased()`* `END_IF; IF bParkAfterStop AND NOT bStopActive
    THEN` park `END_IF END_IF` (M's form; I's form is equivalent because `bStopActive` is cleared only here, I:942, and a park is queued
    only while a stop is active, I:1236, 2714).
17. *`_ReleaseReset()`*, *`_SafeStateEndOfScan()`*, READY_STATE publish (as M:1011-1013), telemetry with `tonMQTTTimer.PT :=`
    *`_TelemetryPeriod()`* and *`_SendTelemetry()`*, *`_LogEvents()`*, *`_EndOfScan()`*, snapshot `b*Checked := b*`.

M and I bodies become `SUPER^();` explicitly (whether an empty derived body runs the base body is [unverified]; `SUPER^()` through
AltAz/RaDec, whose bodies are `SUPER^();`, reaches B). `FB_MonetTelescopeProbe` keeps working: its body still runs nothing.

### 3.2 Hooks

Abstract (A) = each subclass must implement; default (D) = base body given, override where noted. Hook names that exist today as
`PRIVATE` methods with the same signature keep the name; the subclass changes `PRIVATE` to `PROTECTED`. Stage machines keep their
private names and types; the base calls new wrappers `_Do*` (one line each), so the `BOOL`/`USINT` difference does not matter.

| Hook | Kind, signature | M implements | I implements |
|---|---|---|---|
| `_ScanBegin` | D, empty | `bSuspendStop := FALSE`, Dut1 stale (M:364-373) | - |
| `_AutoStop` | D, `bStopActive := TRUE` | default | override: IAG#84 park queue (I:1231-1238) |
| `_ReadInputs` | A | `_MotionConfig`, `_ReadAxes`, `_StopTxInputs` | `_ReadAxes`, cabinet (I:226-227) |
| `_HandleReset` | A | existing (M:2054) | existing (I:1333) |
| `_ReadErrors` | A | M:398-449 | I:232-268 |
| `_ErrorReaction` | D, empty | M:451-568 (ramps, timeout park, focus park, roof) | I:272-275 (#100) |
| `_AcceptMove(eCommand, eExcludeOwn : E_TCSCommand) : BOOL` | A | existing (M:3034) | existing (I:1190) |
| `_OnMoveEdgeAccepted(eCommand)` | D, empty | `_ClearOffsets()` (#177) | - |
| `_ApplyError` | A | axis disable unless a ramp or park runs, brake on elevation error (M:611-630) | disable, cabinet LED (I:284-288) |
| `_ComputeTargets` | A | existing (M:2231) | new, extracted from I:308-410 (S3) |
| `_Guards` | D, empty | M:637-644 | I:412-501 |
| `_Timers` | A | M:646-676 | I:504-546 |
| `_RestartMoveTimeout(eKeep)` | A | M:699-703 | I:570-574 |
| `_ParkRequests` | D, empty | #86 + exemption, cover park, safety park (M:710-771) | 4.4d error park (I:292-305, moved in S1) |
| `_ParkPreStep : BOOL` | D, `FALSE` | default | I:590-610, returns `bParkHeld` |
| `_EmergencyPark : BOOL` | D, `FALSE` | `bSafetyPark` | default |
| `_AtRest : BOOL` | D, `bStopped` | default | `bSettled` (IAG#98) |
| `_InterruptPower/_InterruptPark/_InterruptGoto/_InterruptSlew/_InterruptGoHome` | D, call `_DoX()` | default | power: stage >= 40 sweep stop (I:663-673); park: end text, `fbSweepStop.Cancel` (I:676-680); gohome: end text (I:689-696) |
| `_AfterArbiter` | D, empty | - | stop ignored (I:707-709) |
| `_DropAxisCommands` | A | M:853-858 | I:715-718 |
| `_OnCommandChanged` | D, empty | - | `fbStopTx.Begin()` on stop (I:727-729) |
| `_DoPowerOn/_DoPark/_DoGoHome/_DoGoto/_DoSlew/_DoTrack/_DoStop` | A | call `_PowerOn()` ... `_StopTelescope()` | same |
| `_CommandTimeout(eCommand) : TIME` | A | `stMotionUsed` fields (M:870-894) | 12 h, 30 s, 2 min (I:734-758) |
| `_AfterDispatch` | D, empty | M:901-939 | - |
| `_UpdateStatus` | A | M:941-967 (incl. `_StopTxMonitor`) | I:767-922 |
| `_ReadyStateParking : BOOL` | D, `bParkActive AND NOT bPowerActive` | default | adds `bSafeParked` (I:926) |
| `_IsSlewing : BOOL` | D, `bSlewing` | default | `bSliding` |
| `_StopSettled : BOOL` | A | `fbStopTx.bSettled` | `bSettled` |
| `_OnAbortStopReleased` | D, empty | `StopAxis := FALSE` x3 (M:2434-2436) | - |
| `_ReleaseReset`, `_SafeStateEndOfScan` | A | M:995-1007 | I:954-961 |
| `_TelemetryPeriod : TIME` | A | 500/1000 ms | 1000/5000 ms |
| `_SendTelemetry : BOOL` | A, public (as M:1661) | existing | calls `_SendTelemetryEquitorial()` (IT calls it directly, 3 places) |
| `_LogEvents` | A | existing | existing |
| `_EndOfScan` | D, empty | - | `bHomeByCommand` clear (I:990-992) |

That is 36 methods (21 abstract). Policy inputs: none new. `bParkWinsOverPowerOn` stays an arbiter input (A:43), passed `TRUE` by the
base (both sites today); if a site ever needs `FALSE`, it becomes a base VAR, not a hook.

### 3.3 State that moves into B, and the name clash

**Moves to B** (same name, same type, same section as today, so every test and ADS path `MAIN.<instance>.<name>` stays valid
[unverified for ADS symbol paths of inherited members; tests already read `TCS_command` that way]): `bPowerActive`..`bResetActive`
(VAR_OUTPUT), `b*Checked` x8, `bMoveAbortPending`, `bParkAfterStop`, `bSupersedeRequest`, `eSupersedeKeep`, `fbArbiter`, `bRequestIdle`,
`bParkHeld`, `bWasPower`/`bWasPark`/`bWasGoHome`/`bWasMove`, `bPowerAbortedByPark`, `eTimeoutCommand`, `fbStartup`, `nTimeDivisor`
(VAR_INPUT `UDINT := 1`), `bSoftwareError`.

**Stays in the subclasses:** `aAxis`, `fbStopTx` and its wiring (3 vs 2 axes; unifying the two stop-transaction lifecycles, row 23/25 of
2.2, is a follow-up), the state-machine timers (gating differs, decision-3 items), `nSoftwareErrorID` (UINT vs UDINT), and the acceptance
and reject bookkeeping (3.4).

**Clash plan.** A redeclared base member is a compile error in the subclass [unverified; IAG50cm#213 deleted 74 base declarations for
the same reason]. The BROTLib release that adds the members is used by nobody until a consumer re-pins it, and **each consumer deletes its
declarations in the same commit as the pin bump** (S6, S8). A runtime project must not pin the new BROTLib with an old MONETcommon (CI
compile error, no runtime risk). Renames before the move, in S1 (IAG only, M already uses the target names): `bInterupted` ->
`bInterrupted` (B:67; the IAG declaration I:72 is deleted, 18 uses renamed; `IAG/tools/Ads-Watch.ps1:34` reads `bInterupted`: changed in
an IAG repo PR merged with the S1 release), `bPowerParked` -> `bPowerAbortedByPark` (4 uses), `eLastTimeoutCommand` -> `eTimeoutCommand`.

### 3.4 Acceptance stays a hook in 5.4

Moving `_CommandState`/`_AcceptMove`/`_NoteRejected` and the reject log into B needs one enum type for `eLastRejectReason`. B can only
use `BROTLib.E_CommandRejectReason`, which lacks `init_required` (#72), and MT compares against `MONETcommon.E_CommandRejectReason.*`
under `{attribute 'strict'}`: those tests would have to be edited, and `F_CommandAcceptance_Tests` would go with the local function.
So in 5.4 `_AcceptMove` is an abstract hook and the bookkeeping stays where it is. The leftover "delete MONETcommon's copy" (2026-10-21
plan, small leftovers) becomes its own optional pair of PRs after 5.4: BROTLib adds `init_required` to `E_CommandRejectReason`,
`ST_CommandState.bInitRequired`, `F_CommandAcceptance`, `F_CommandRejectText` (additive); MONETcommon switches and changes the test
qualifiers in one commit (an explicit, reviewed test edit). Open question Q2.

### 3.5 Default methods of B, and the command methods

The defaults no longer write the inputs [design]: `Park` becomes the shared implementation (M:2771-2779 and I:2711-2717 are the same
code; M and I delete their overrides; the return value is unused by the comm layer, `FB_Comm_MQTT_Influx.TcPOU:128-162`). `Stop`, `Init`,
`Reset`, `Home`, `Slew`, `Track` differ (focus stop, init refusal texts and `bReleaseHold`, `bResetRequest` vs `bResetActive`,
`bHomeByCommand`, offset clear #177) and stay overridden in M and I. Their B defaults become the minimal latch protocol: `b*Checked :=
TRUE`, then the latch (`Home`/`Slew`/`Track` through `_AcceptMove`, `Init` through `fbStartup.AcceptInit()`). No subclass runs them
today; they make B safe for a future subclass. `_PublishTelemetry` keeps reading `bSlew` in 5.4 (M's workaround M:1667-1680 and the
telemetry suites would change otherwise); switching it to `bSlewActive` is a follow-up.

### 3.6 `FB_PendantControl` and the interfaces

No member P uses (2.1) moves or is renamed, and P writes only inputs, which stay inputs. HalfBROT needs **no source change**; it needs a
re-pin PR as compile proof against the new BROTLib. A release is needed only to keep the pin order rule (BROTLib -> HalfBROT ->
MONETcommon), because the top project's pin decides (2.1); Q4. `I_Telescope`, `I_AltAzTelescope`, `I_RaDecTelescope` are unchanged.

## 4. Divergences between the bodies and their decisions

"Pin" = the test that shows it (existing suites unedited unless *new*). Differences in hooks are kept as they are: 5.4 moves code, it does
not align behaviour, except rows D1, D2, D4.

| # | Difference | Decision [design] | Step | Pin |
|---|---|---|---|---|
| D1 | Move gate placement: I decides edges at the top (I:190-207), before `fbTime()`, `BeginScan` and the error computation, so `bError`, `bClockValid` and `bPowering` of `_CommandState` are the last scan's; M decides after them (M:575-597) | MONET's place (behaviour change: a move edge in the scan of a new error, of a clock loss or of a dropped power-on is rejected with a log instead of accepted and dropped silently) | S1.d | *new* `IagCommandInputs_Tests.Slew_Input_In_The_Scan_Of_A_New_Error_Is_Rejected` |
| D2 | Error park placement: I before targets, guards, supersede (I:292-305); M after supersede, before the arbiter (M:710-722) | MONET's place (`_ParkRequests`). For I neutral by reading: an automatic stop in between queues the park in `bParkAfterStop` in both orders (`_AutoStop` I:1235 vs `Park` I:2713), and with `bError` the supersede is already cleared [unverified] | S1.e | *new* `IagErrorPark_Tests.Error_Park_With_An_Automatic_Stop_In_The_Same_Scan_Runs_After_Settle` (written first, green before and after) |
| D3 | MONET error reaction (ramps, timeout park, focus-error park, roof), cover park, safety park, brake rules (M:451-568, 620-630, 723-771, 907-939) | stays MONET, hooks `_ErrorReaction`, `_ApplyError`, `_ParkRequests`, `_AfterDispatch` | S2 | `MonetSafeState_Tests`, `MonetErrorPark_Tests`, `MonetTimeouts_Tests`, `MonetBrakeRelease_Tests` |
| D4 | `Track()` marks `bTrackChecked` in M (M:2950) but not in I (I:2873): `Track()` plus a `bTrack` edge in one scan is decided twice on I, the second as `replace`, which drops the goto just accepted [by reading] | MONET | S1.f | *new* `IagCommandInputs_Tests.Track_Method_And_Track_Input_In_One_Scan_Count_Once` |
| D5 | `_ReadAxes` before `BeginScan`/clock in I (I:209), after in M (M:390) | template order; neutral (neither reads `aAxis`) | S3 | all IAG suites |
| D6 | IAG-only: cabinet, second axis-reset pass, #100 `bIsPowered`, pole zone, limit home #84, #197 park pending, extra `bStopped` terms #92/#98/#113/#120/#198, in-place park state #187 | stay IAG, in `_ReadInputs`, `_ReadErrors`, `_ErrorReaction`, `_Guards`, `_Timers`, `_UpdateStatus` | S3 | `IagParkInLimit_Tests`, `IagStuckStop_Tests`, `IagParkPowerReset_Tests`, `IagTimeouts_Tests`, `IagErrorPark_Tests` |
| D7 | Error ID and axis reset: first errored axis (M:411-434) vs all plus second pass (I:242-262) | stays per site (`_ReadErrors`); IAG#11 to MONET is a decision-3 item, not here | - | `MonetResetUnderMotion_Tests`, `IagResetUnderMotion_Tests` |
| D8 | Timers from the request (M) vs while dispatched (I, #75), idle park every scan (M) vs once (I, #83) | stay (`_Timers`); decision-3 items | - | `MonetTimeouts_Tests`, `IagTimeouts_Tests` |
| D9 | Arbiter `bEmergencyPark` (`bSafetyPark` vs FALSE), `bStopped` (`bStopped` vs `bSettled`), park pre-step | hooks `_EmergencyPark`, `_AtRest`, `_ParkPreStep` | S2, S3 | `MonetSafeState_Tests`, `IagParkDuringPowerOn_Tests`, `IagStopDuringPark_Tests` |
| D10 | Interrupt extras (sweep stop arm, park/home end texts) and stop-ignored log (I:663-709) | hooks `_Interrupt*`, `_AfterArbiter` | S3 | `IagParkDuringPowerOn_Tests`, `IagStopDuringPark_Tests` |
| D11 | Stop transaction lifecycle: M begins in `_StopTelescope` and cancels when the command is not stop (M:2514-2520, 901-905); I begins on the change to stop and cancels on reset/error/E-stop (I:727-729, 811-814) | stays (hooks); unify later | - | `MonetStopDuringSlew_Tests`, `IagStopDuringSlew_Tests`, `IagStuckStop_Tests` |
| D12 | Stop release park form (inside vs outside the settle IF), settle test (`fbStopTx.bSettled` vs `bSettled`), StopAxis drop (M only) | M's form in B, `_StopSettled`, `_OnAbortStopReleased`; equivalent by reading (3.1 item 16) | S2, S3 | `IagStopDuringPark_Tests`, `MonetStopDuringSlew_Tests` |
| D13 | Per-command timeouts, telemetry cadence, `bSlewing` vs `bSliding`, READY_STATE `Parking` term, idle axis drop, reset release, end-of-scan disable | values and members per site, hooks | S2, S3 | `IagTelemetry_Tests`, `MonetTimeouts_Tests`, `FB_MonetRig_Tests`, `FB_IagRig_Tests` |
| D14 | Gohome edge: M `_AcceptMove` + latch (M:575-579), I `Home()` (I:190-192) | B calls `Home()`; for M the same effect (M:2995-3000) | S2 | `FB_MonetRig_Tests` |
| D15 | `_CommandState`: `bInitRequired` (M:3021, local types) vs `bHomeByCommand` gate (I:1178) | stays in the subclass (`_AcceptMove` hook, 3.4) | - | `IagCommandAcceptance_Tests`, MT acceptance cases |

## 5. Steps and PR sequence

Every step: own git worktree, branch from `develop`, one PR, CI green, merge. Nothing builds or tests locally (no XAE, tctool,
TcXaeShell). A red run is a finding only after the log shows a test failure, not a runner failure; expect 1-3 re-runs per PR. Files are
UTF-8 with BOM, CRLF in the working copy, LF in git; no lone `\r`. A behaviour change is its own commit with its own test.

### S0: checkpoint decision (no code)
Tim decides the staged go (Q1). Precondition for S4 only: go condition 1 met (IAG50cm 0.8.0 on site for a week, MONETcommon #232
released).

### S1: IAG50cm small moves and renames (PR 1, IAG50cm; six commits)
- S1.a rename `bInterupted` -> `bInterrupted` (delete I:72); S1.b `bPowerParked` -> `bPowerAbortedByPark`, `eLastTimeoutCommand` ->
  `eTimeoutCommand`. Neutral; IAG repo PR for `Ads-Watch.ps1`/`Ads-Capture.ps1` merged with the release.
- S1.c add the D2 characterization test first (it must pass on today's code); the D1 and D4 tests go in with their move (S1.d, S1.f).
- S1.d move the move-edge block (I:187-207) after `_HandleReset`/error ID/`bError`/#100, before the error clear (D1). Test flips: none
  existing expected [unverified]; *new* D1 test.
- S1.e move the error-park request (I:292-305) after the supersede block, before the park pre-step (D2). *New* D2 test, green before and
  after.
- S1.f `Track()` sets `bTrackChecked` (D4), *new* test.
- Acceptance: CI green; existing suites unedited; three new tests. Release: IAG50cm minor (0.9.0), short on-site check (section 6).

### S2: MONETcommon local template (PR 2, MONETcommon; neutral)
Reshape M's body into the exact text of 3.1, calling local methods with the hook names and signatures of 3.2 (still in M, `PRIVATE`
where possible): `_ScanBegin`, `_ReadInputs`, `_ReadErrors`, `_ErrorReaction`, `_ApplyError`, `_Guards`, `_Timers`, `_ParkRequests`,
`_Do*`, `_Interrupt*`, `_DropAxisCommands`, `_CommandTimeout`, `_AfterDispatch`, `_UpdateStatus`, `_StopSettled`, `_ReleaseStop`
(replaces `_StopTxRelease`, also in `SuspendAutomatic`), `_ReleaseReset`, `_SafeStateEndOfScan`, `_TelemetryPeriod`, `_AutoStop`.
Code moves verbatim; no line changes meaning. Acceptance: CI green, MT unedited. Release: none on its own (Q5).

### S3: IAG50cm local template (PR 3, IAG50cm; neutral)
The same for I, with the same template text (D5: `_ReadAxes` into `_ReadInputs` after the clock). `_ComputeTargets` extracted from
I:308-410. Acceptance: CI green, IT unedited, and **`diff` of the S2 and S3 bodies shows only comments** (go condition 2, measured).
Release: none on its own.

### S4: BROTLib template body (PR 4, BROTLib; breaking)
B gets the template body (3.1), the members of 3.3, the hooks of 3.2 (ABSTRACT or default; if `PROTECTED ABSTRACT` does not compile,
public `ABSTRACT` as `FB_BaseAxis._StartHoming`), `_ReleaseStop`, and the default methods of 3.5. `FB_AltAzTelescopeControl` and
`FB_RaDecTelescopeControl` unchanged. New `BROTLibTests/.../FB_BaseTelescopeControl_Tests` with a stub `FB_TelescopeStub EXTENDS
FB_AltAzTelescopeControl` (hooks as counters): held input starts once, method + edge in one scan count once, error clears the moves and
the abort stop, supersede keeps the latest, stop release frees a queued park, hook call order (about 10 tests; BROTLibTests is near its
global-data limit, 2026-10-21 plan 5.1: keep the stub small). Release: BROTLib minor 0.20.0 (pre-1.0 minor = breaking). No consumer
moves until it re-pins.

### S5: HalfBROT re-pin (PR 5)
Pin BROTLib 0.20.0, no source change; CI compile is the check. Release HalfBROT patch 0.14.1 if Q4 says so.

### S6: MONETcommon on the base template (PR 6)
In one commit: pin BROTLib 0.20.0 (+ HalfBROT), delete the moved declarations (3.3), the local template body (body becomes `SUPER^();`),
the `Park` override and `_ReleaseStop`; the local hook methods become `PROTECTED` overrides. Acceptance: CI green, **MT unedited**.
Release: MONETcommon minor 0.19.0.

### S7: MONETS and MONETN re-pin (PRs 7a, 7b)
Pin MONETcommon 0.19.0, BROTLib 0.20.0, HalfBROT (0.14.1 or 0.14.0) together. Release MONETS/MONETN patch.

### S8: IAG50cm on the base template (PR 8)
As S6 for I; pin BROTLib 0.20.0. Acceptance: CI green, **IT unedited**. Release: IAG50cm minor 0.10.0.

### Rollback story
- S1-S3 are local; S1 is released and checked alone, S2/S3 are neutral and unreleased until S6/S8, so a rollback of 5.4 on a telescope
  returns to the S1 / MONETcommon 0.18.x build that already runs there.
- On site: re-activate the previous tag (MONETS/MONETN 1.6.x, IAG50cm 0.9.0); those pin BROTLib 0.19.0 and are not touched by 0.20.0.
  Note the installed versions before each activation.
- In git: revert the consumer PR (S6/S8) or the re-pin (S7); BROTLib 0.20.0 then sits unused. MONET and IAG roll back independently.
- A full download (not online change) is expected because the instance layout of the telescope block changes [unverified]; the
  `VAR PERSISTENT` counters stay in M (M:336-339) and are restored by name [unverified].

### Release chain and pin order
BROTLib 0.20.0 (S4) -> HalfBROT re-pin (S5, release per Q4) -> MONETcommon 0.19.0 (S6) -> MONETS and MONETN re-pin (S7) ; IAG50cm
0.10.0 (S8) after S4, independent of S5-S7. Keep 5.4 its own BROTLib release (decision 6 of the 2026-10-21 plan). Checks: MONET/S,
then MONET/N, then IAG50cm (or IAG50cm first if Tim is there first; the chains are independent).

## 6. On-site checks

Record per check: result (pass, fail, deviation), date and time, installed versions, log lines for anything unexpected. If a check
fails, roll back before the next telescope.

**After S1 (IAG50cm 0.9.0, short):**
- [ ] 1. Power-on, slew, `stop=1` during the slew, park; reset after an error (second pass about 2.5 s later)
- [ ] 2. `track` during a goto: abort stop, then the new target; `slew` while parked: rejected with a reason in the log
- [ ] 3. `Ads-Watch.ps1` shows `bInterrupted` (not `bInterupted`) and the latches
- [ ] 4. A night of normal use: no new warning, no unexpected rejection

**After S6/S7 (MONET/S, then MONET/N, full; base: T18 of `IAG/specs/plans/2026-10-12-monet-telescope-test-plan.md`):**
- [ ] 1. Power-on from parked to READY_STATE 1.0; slew; `track`; tracking over 30 min; telemetry every 0.5 s while moving, 1 s idle
- [ ] 2. `stop=1` during a slew: one stop per moving axis; three `stop=1` within a few seconds: no hang, no second `MC_Stop` on a stopping axis
- [ ] 3. `track` over a goto, `slew` over a goto: the latest wins; `home` while tracking
- [ ] 4. Park during power-on (#87); `power=1` during a park: "power-on ignored: park in progress"; park during a stop runs after settle
- [ ] 5. Reset under motion: abort stop, no moving axis reset, no 0x4260
- [ ] 6. Switch to manual under motion and back (#118, `SuspendAutomatic`); a Visu move after the return
- [ ] 7. Horizon guard: a target that runs below the horizon: stop, then home
- [ ] 8. E-stop: covers stop, after release the park in place and the covers close; hydraulics/power-failure ramp only with Tim's agreement, otherwise mock only
- [ ] 9. `nInterruptedAutoClearCount` and `nStopForcedCount` unchanged after the night; no false timeout 16#10/16#30/16#40

**After S8 (IAG50cm 0.10.0, full; base: the 3C list of the IAG plan):**
- [ ] 1. Power-on to READY_STATE 1.0; slew; `track`; tracking over 30 min; telemetry 1 s moving, 5 s idle
- [ ] 2. `track` during a goto; `home` while tracking; `slew` during a goto
- [ ] 3. `park` during a slew, during tracking, during the power-on sweep (IAG#197), with the axes off (in-place park, 0.3 then 0.0)
- [ ] 4. `stop=1` three times during a slew and idle; park queued behind a stop; `stop=1` cancels it
- [ ] 5. Reset without an error during a slew (abort stop, no safety acknowledge); reset after an error (second pass)
- [ ] 6. Pole/horizon limit while tracking: automatic stop, limit home, pending park not lost (IAG#84)
- [ ] 7. Axis error park: only with Tim's agreement, otherwise mock only (`IagErrorPark_Tests`)
- [ ] 8. A night of normal use: no false timeouts 16#10/16#20/16#30/16#40, no unexpected rejections

## 7. Effort (PR-sized, no dates)

| Step | Size | CI runs (incl. re-runs) | Behaviour change | Release |
|---|---|---|---|---|
| S0 decision | S | 0 | - | - |
| S1 IAG moves, renames | M (about 30 edits, 2 block moves, 3 tests) | 2-3 | D1, D4 (D2 neutral) | IAG50cm minor + short visit |
| S2 MONET local template | L (700-line body into about 20 methods, verbatim) | 2-3 | none | none |
| S3 IAG local template | L (820-line body, `_ComputeTargets` extraction) | 2-3 | none | none |
| S4 BROTLib template | L (template about 250 lines, 36 hook methods, about 30 members, stub suite) | 2-4 | none for consumers | BROTLib minor |
| S5 HalfBROT | S | 1-2 | none | patch (Q4) |
| S6 MONETcommon | M (delete about 300 lines and declarations, access edits) | 2-4 | none | MONETcommon minor |
| S7 MONETS, MONETN | S each | 1-2 each | none | patch each |
| S8 IAG50cm | M | 2-4 | none | IAG50cm minor |
| On site | three full checks, one short | - | - | - |

Gain: about 235 skeleton lines per body (edges 12, gate 22, clock 8, error clear 8, supersede 28, arbiter wiring 25, apply 40, idle 6,
timeout 6, dispatch 33, READY_STATE and motion 13, release 12, publish and telemetry 13, snapshot 8) exist once. The leaves stay per site
and the line count overall does not shrink much. The real gain is that a change to the skeleton (a new command, an arbiter input) is
made once and tested once. S2/S3 alone deliver the diff-ability without the release chain.

## 8. Risks and mitigations

- **Compile-level unknowns** (`PROTECTED ABSTRACT`, override access and signature rules, an empty derived body, strict enum mixing,
  duplicate base members): all fail at compile time, not at run time. Mitigation: S2/S3 already use the final names and signatures,
  so S4/S6/S8 change access and delete code only; fallback public `ABSTRACT`.
- **A hook moved to another place in the scan.** S2/S3 change no order except D5 (neutral by reading) and the S1 moves, each with a test;
  "no test edited" is the acceptance of every neutral step.
- **Hook granularity.** 36 methods: a reader follows the scan through B and the subclass. Mitigation: B's body carries the order as
  the one place to read; each hook comment names the M/I lines it came from.
- **Release churn and the single runner.** S4-S8 drag five repos and three visits. Mitigation: neutral steps unreleased until their
  consumer step; batch S7a/S7b; no other BROTLib change in 0.20.0.
- **Mixed pins.** A MONETS PR that pins BROTLib 0.20.0 with MONETcommon 0.18.x fails to compile. Mitigation: S7 pins all three at once.
- **Mock vs reality.** Neutral refactors, but call order inside a scan is what the PLC sees. Mitigation: full on-site checks, MONET/S first.
- **ADS readers and HMI.** Moved members keep their instance path [unverified]; IAG tools change for `bInterrupted` in S1.
- **Download vs online change** on each PLC, persistent counters (5, rollback story).
- **TcUnit limits.** IAG50cmTests 22 suites, MONETcommonTests 35 (limit raised already), BROTLibTests near its data limit (S4 stub).
- **Go condition 1 not met** today; starting S4 early would stack a breaking change on an unchecked 3C.

## 9. Open questions for Tim

1. **Q1 Staged go.** Do S1-S3 now (local, no library change) and decide S4-S8 after the S2/S3 diff is empty and 3C has had its week?
   **Recommendation:** yes. S1-S3 are worth it on their own: two bodies that differ only in hooks are cheap to keep in step even if
   5.4 stops there.
2. **Q2 Acceptance units.** Keep `_AcceptMove`, `_CommandState` and the reject log in the subclasses for 5.4 (3.4), or first move
   MONETcommon to BROTLib's units (BROTLib adds `init_required`; MT changes about 100 qualifiers and drops `F_CommandAcceptance_Tests`)?
   **Recommendation:** keep them in the subclasses for 5.4; do the switch as the small follow-up pair, with the test edit reviewed on its own.
3. **Q3 D2 for IAG.** The error-park move is neutral by reading. Own commit with a characterization test (S1.e), or fold it into S3?
   **Recommendation:** own commit in S1, test first: if the reading is wrong, the test shows it before the release.
4. **Q4 HalfBROT.** Re-pin PR only (compile proof), or also a patch release?
   **Recommendation:** re-pin and patch release; it costs one CI run and keeps the pin order rule simple.
5. **Q5 Releases of S2/S3.** Unreleased until S6/S8 (one MONET and one IAG release for 5.4), or each released with a smoke check?
   **Recommendation:** unreleased; they are neutral and S6/S8 delete them again a few PRs later. Release S1 alone (it changes behaviour).
6. **Q6 `bParkWinsOverPowerOn`.** Both pass TRUE. Keep it as an arbiter input passed TRUE by the base, or drop the input?
   **Recommendation:** keep it in the arbiter (its tests cover FALSE); B passes TRUE; no new base input.
7. **Q7 D4 (`Track()` and `bTrackChecked`).** Fix on IAG as MONET does?
   **Recommendation:** yes, in S1 with its test; it is a one-line difference that the template would otherwise hide in the hook.

## 10. Not verified

- Nothing was compiled or run. Every [design] item (template, hooks, stub suite) is untested.
- TwinCAT rules assumed: duplicate base member is an error; `PROTECTED ABSTRACT` compiles; an override must match access and signature;
  `SUPER^()` reaches B through AltAz/RaDec; strict enums of two libraries do not compare; inherited members keep their ADS path; a full
  download is needed. Each is settled by the first CI run of S4/S6/S8 or on site.
- D1 "no existing test flips", D2 "neutral" and D12 "equivalent" are readings of the code, not runs.
- Whether IAG50cm 0.8.0 is activated on the PLC, and the observing week of go condition 1.
- That the top project's pin decides library resolution (inferred from green CI of MONETS/MONETN with mixed pins).
- Test counts (grep of `TEST('...')` and `MAIN.TcPOU`) are approximate.
