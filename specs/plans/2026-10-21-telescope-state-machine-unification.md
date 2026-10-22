# Telescope state machine: pin it with tests, then unify it in BROTLib (BROTLib#25)

**Status: proposed, 2026-10-21.** Plan only, no PLC code changed. Base commits: BROTLib `c42312e` (`develop`, last
release v0.9.0, #93/#92 merged but not released), MONETcommon `d9d7a6c` (0.9.3), HalfBROT `60453e2` (0.5.7), IAG50cm
`2e09ab4` (0.4.0), MONETS `3f3e40d`, MONETN `da8fea5`. Related: BROTLib#25 (state machine copied), BROTLib#67 (SoE
reset copies), MONETcommon#36 (TcUnit for `FB_MonetTelescopeControl`), MONETcommon#24 (design finding D), the
on-site checks MONETcommon#61-#65, and plan `2026-10-21-focus-retarget-stop-range-122.md` (MONETcommon#122, in work by
another agent: it changes `_StopTelescope` in both telescopes and `I_Focus`; this plan does not touch focus code and
starts its code steps after #122 has merged).

Marking: **[verified]** = read in the code at the commits above on 2026-10-21, with `file:line` (line numbers of the
`.TcPOU` file, XML wrapper included); **[unverified]** = my reading of TwinCAT/CODESYS behaviour or an assumption, to
be confirmed by a spike, CI or on site. Short names: **M** = `MONETcommon/MONETcommon/MONETcommon/FB_MonetTelescopeControl.TcPOU`,
**I** = `IAG50cm/IAG50cm/POUs/FB_TelescopeControl.TcPOU`, **B** = `BROTLib/BROTLib/BROTLib/Telescope/FB_BaseTelescopeControl.TcPOU`.

## Agreed approach (Tim, 2026-10-21)

1. Characterization tests first: a mock rig and scenario suites that pin the *current* behaviour. A test that shows
   a bug is a finding, decided case by case; it does not change code by itself.
2. Then small refactor steps, tests re-run after each. A wanted behaviour change (e.g. IAG gets a MONETcommon fix) is
   its own commit with its own test update, never mixed into a move.
3. Move the already-extracted pure units into BROTLib; IAG50cm adopts them one at a time.
4. Last: the arbitration skeleton in BROTLib's `FB_BaseTelescopeControl` (template method, `EXTENDS`/`ABSTRACT`).
5. IAG50cm needs its own test net. Mocks cannot prove NC/brake/drive behaviour, so every released step still gets an
   on-site check on MONET/S, MONET/N and IAG50cm.

## Where we are

**Two copies, not three [verified].** BROTLib#25 counts a third copy in MONETN. It is gone: MONETN and MONETS both
instantiate `FB_MonetTelescopeControl` (`MONETN/MONETN/MONETNRuntime/POUs/MAIN.TcPOU:28`,
`MONETS/MONETS/MONETSRuntime/POUs/MAIN.TcPOU:28`) and no `.TcPOU` in MONETN/MONETS contains `TCS_command`. The two
copies: M (2525 lines, body M:156-886) and I (2944 lines, body I:182-985).

**Inheritance today [verified].**

- M: `FUNCTION_BLOCK FB_MonetTelescopeControl EXTENDS FB_AltAzTelescopeControl` (M:4); `FB_AltAzTelescopeControl
  EXTENDS FB_BaseTelescopeControl` (`FB_AltAzTelescopeControl.TcPOU:4`); `FB_BaseTelescopeControl` is already
  `ABSTRACT IMPLEMENTS I_Telescope` (B:4). M never calls `SUPER^()` in its body (comment M:160-163) and overrides
  `Init`, `Park`, `Stop`, `Reset`, `Home`, `Slew`, `Track` and the properties (M:1906-2188). B's own content is the TCS
  inputs/outputs, events, timers and `_PublishTelemetry` (B:4-131, 133-215). BROTLib#25 is right that the base holds
  shared variables only.
- I: `FUNCTION_BLOCK FB_TelescopeControl IMPLEMENTS I_RaDecTelescope, I_Telescope` (I:4), **no base class**. It
  redeclares the same inputs/outputs by name (I:10-29, 150-176) and has its own `ST_TelescopeConfig`
  (`IAG50cm/IAG50cm/DUTs/ST_TelescopeConfig.TcDUT`: `houranglePark`, `declinationPark`, `hourangleHome`, ...), a
  different struct with the same name as BROTLib's (`Telescope/ST_TelescopeConfig.TcDUT`: `elevationPark`,
  `azimuthPark`, `derotatorPark`, ...). The design note `design/iag50cm-axis-unification-plan.md` still calls them
  "Identical"; that is out of date.
- `FB_RaDecTelescopeControl` (BROTLib) is used by nobody (search over all repos finds only BROTLib's own files). Its
  body is mostly commented out.
- HalfBROT `FB_PendantControl` holds `fbTelescope : REFERENCE TO FB_AltAzTelescopeControl`
  (`HalfBROT/HalfBROT/HalfBROT/POUs/FB_PendantControl.TcPOU:13`), so any change to that class ripples into HalfBROT.

**Already shared [verified].** `BROTLib.FB_StartupControl` / `FB_StartupReadiness` (READY_STATE) are used the same
way by both: `BeginScan` (M:158, I:184), `Update` (M:724-729, I:838-843), `PublishDue` (M:754, I:870), `AcceptInit`
(M:1983, I:2148). This is the model for the extraction: a pure-logic block in BROTLib, tested in BROTLibTests,
called from both controllers.

**Tests today [verified].**

- MONETcommonTests: 19 suites (`MONETcommonTests/.../POUs/MAIN.TcPOU`), all on pure functions, `FB_MonetStopTransaction`
  and a stop simulation (`FB_MockStopAxis`, `FB_StopRig`, `StopLoop_Sim_Tests`). `FB_MonetTelescopeControl` is never
  instantiated; plan `MONETcommon/specs/plans/2026-09-22-add-tcunit-tests.md` left that open ("not yet attempted").
  TcUnit limits 32 suites, 32 tests per suite, 256 asserts per suite (`MONETcommonTests.plcproj:154-163`).
- IAG50cmTests: 5 suites on copied POUs (`IAG50cmTests/tools/Sync-Sources.ps1` copies `FB_StopTransaction`,
  `FB_HomeDropReason`, `FB_HomeHold`, `FB_SweepStop`, `FB_PointingModelForward`). **No BROTLib reference** in
  `IAG50cmTests.plcproj` (only Beckhoff libraries and TcUnit). `FB_TelescopeControl` is never instantiated; its
  README says so ("they need the whole `FB_TelescopeControl` or an NC axis").
- BROTLibTests: `FB_Axis_Tests` runs the real `FB_Axis` on a plain `AXIS_REF`; NC outputs are written through a
  pointer because "`NcToPlc` is not writable from outside" (`FB_Axis_Tests.TcPOU:29-30`, `SetActPos`). That trick is
  what the mocks below rely on.

## Comparison: identical, diverged, inherently site-specific

"Identical" = same logic and names apart from the axis list. "Diverged" = same job, different logic; the column
"newer fix" says which side carries a later fix. "Site" = differs because of the hardware and stays a hook.

### Body

| Block | M | I | Class | Note |
|---|---|---|---|---|
| Startup scan begin | 158 | 184 | identical | `fbStartup.BeginScan` |
| Clock, JD, LST, stop without valid clock | 170-180 | 185-195 | identical | |
| Reset trigger | 183 (`rtrigReset(CLK := bReset)`) | 205 (key or `Reset()`, only with `bError OR bSafetyAckPending`) | diverged | IAG: a reset without an error does nothing (#36, #59). Policy, not a bug |
| Stuck-stop recovery by reset | 191-205 | none | diverged, newer fix M (#96 D3, #56) | |
| Reset clears flags | 207-236 (all moves, `F_ResetMoveAbort`, stages) | 208-242 (goto/slew/track, coordinates to park, dome reset, stages) | diverged | M drops `bGoHome` (#85); I keeps it (cancelled by `tonHomePending`, I:481-490) |
| Axis reset after an error | 248-270 (only the first errored axis in an IF/ELSIF chain) | 262-275, 1407-1423 (all errored axes, second pass after the safety acknowledge) | diverged, newer fix I (#11, #55, #103) | the second pass is IAG safety (STO), the "all axes" part is generic |
| Error ID priority | 248-270 | 245-253 | identical pattern | axis list per site |
| `bError` composition | 275-279 | 281 (+ cabinet, `bTestError`) | site | |
| Error reaction | 304-323 (clear moves, disable axes, brake on elevation error) | 283-294 (clear moves, disable axes, cabinet LED) | identical core + site | brake (M) and cabinet (I) are hooks |
| Target coordinates, pointing, inverse | 325-418 (alt-az, derotator, `F_AxisTurn`) | 297-399 (HA/Dec, forward/inverse model, ICRS) | site | target conversion hook |
| Horizon guard | 421-427 (`fHorizon+0.2`, `bStopped`) | 403-417 (`MAX(fHorizon+0.2, fPointingSafeAltitude)`, `bSettled`, home only when `bReady AND NOT bError`) + pole zone | diverged, newer fix I (#82) | pole zone is site |
| Goto/slew target check | 352 (warning only, #94); stage check in `_GotoTelescope` 923-932 (error 16#15/16#16) | 421-461 (target to park position, `bStop`) | diverged | policy |
| Idle power timeout (12 h park) | 431, 439-441 (sets `bPark` every scan while Q) | 466, 491-496 (fires once, #83) | diverged, newer fix I | |
| Stage-machine timeouts | 436-438 (from the request) | 474-481 (only while dispatched and no error, #75; also park timeout and pending-home drop) | diverged, newer fix I | M's `tonGotoTimeout` counts while a goto waits behind a stop |
| `bInterrupted` auto-clear | 447-459 | none | M only | safety net, counter should stay 0 (MONETcommon#63) |
| Latest move wins (supersede) | 463-491 | `bRestartGoto`/`bRestartSlew` 696-722 (#41) | diverged | M decides at arrival (`F_CommandAcceptance`), I only restarts the same command |
| Emergency park on a new axis error | 495-504 (`F_ErrorParkRequest`, `F_WakeShakeErrorExempt`) | none | M only (#86, #113) | IAG: the error disables the axes, a park during an error is handled in the arbitration (I:555-630) |
| Arbitration order | stop > park-aborts-power > power > abort stop > park > gohome > goto > slew > track > idle (508-639) | user stop > power > stopping > park > gohome > goto > slew > track > idle (501-733) | diverged | see below |
| Per-command timeout | 643-646 (`eTimeoutCommand`, #56) | 740-748 (`eLastTimeoutCommand`, #40, stop transaction `Begin`) | identical | stop timeout 15 s (M:655) vs 30 s (I:756) |
| Dispatch | 648-680 | 750-782 | identical | |
| Stop transaction | `FB_MonetStopTransaction`, 3 axes, arrays (681-685, 1674-1745) | `FB_StopTransaction`, 2 axes (798-808, 1921-1956) | diverged | M is a port of I (`FB_MonetStopTransaction.TcPOU:11`); M adds `Restart`, latched-level handling, `bForced`/`bStuck`; I adds the motion lock (StateDWord bit 29) and the homing abort (`FB_StopTransaction.TcPOU:70-103`) |
| Brake close while elevation disabled | 690-692 | none | site (#121) | |
| `bSlewing`/`bSliding`, tracking delay | 694-701 (5.5 s) | 785-790 (1 s) | identical pattern | delay is a parameter |
| `bStopped` | 1709-1711 | 792-793 | identical | over the axis list |
| `bHomed`, `bReady`, `bBusy` | 705-720 | 825-834 | identical pattern | members are site (covers/brake vs `bIsPowered`/focus enable) |
| READY_STATE update | 724-729 | 838-843 | identical | |
| Motion state | 731-737 | 845-851 | identical | |
| Stop release | 740, 1730-1743 (only when the transaction has settled, #96; park deferred by the stop runs then) | 855-857 (`IF bStopped THEN bStop := FALSE`) | diverged, newer fix M | |
| `bReset` release, E-stop disables axes | 742-750 | 860-867 | identical | |
| READY_STATE publish, telemetry cadence | 754-766 (0.5 s / 1 s) | 870-884 (1 s / 5 s) | identical / parameter | telemetry content is site |
| Event blocks | 770-879 | 889-985 | mostly identical | I has dynamic end texts (#57, #75), M the rejection log (#83) |

### Arbitration differences that matter [verified]

- **Stop clears what.** M clears every move flag and resets every stage machine (M:519-529, #84). I clears only the
  first flag of an IF/ELSIF chain (I:507-526), the pattern M fixed in #84.
- **Who aborts a power-on.** M: any stop (M:508-518), and a park aborts a power-on (M:533-545, #87). I: only a user
  stop (`bUserStop`, I:501, #27); a power-on *cancels* a pending park (I:533-541). The two telescopes have the
  opposite precedence between park and power-on.
- **Park during a stop.** M keeps it (`bParkAfterStop`, M:2050-2054, released at M:1738-1742). I: the stop branch
  clears `bPark` (I:512-515) when no power-on runs, so the park is lost.
- **Preemption stop.** M sets `bMoveAbortPending` on every preemption (M:573, 594, 612). I sets `bStopping` only when
  the preempted command is the one that moves (I:644-646, 667-669, 693-695), and stops tracking before a home (#72,
  I:671-675).
- **Park in an error.** M: `_ParkTelescope` stage 0 runs an emergency park (brake, axes off, covers, M:1079-1110). I:
  the arbitration closes covers, parks the dome, disables the focus, does not move the mount and does not set
  `bIsParked` (I:555-630); `_ParkTelescope` returns on `bError` (I:1269-1272).
- **Command acceptance.** M decides every move at arrival (`F_CommandAcceptance` through `_AcceptMove`, M:2215-2240;
  direct flag writes on their edge, M:283-302). I refuses `Slew`/`Track` only when not ready (I:2270, 2299); `Home`,
  `Park`, `Init` are unconditional (I:2120, 2159, 2148).
- **Switch to manual.** M has `SuspendAutomatic` (M:1324-1430, #118), called by MONETS/MONETN MAIN when not in
  automatic. IAG has no such mode: `bLocalMode` is only read from the cabinet and published (I:199, 1614).

### Methods

| Method | M | I | Class |
|---|---|---|---|
| Stage-machine prologue (reset/error/stop/interrupt guard, timeout) | 902-916, 1014-1026, 1074-1086, 1586-1600 | 1002-1013, 1133-1148, 1260-1275, 1799-1810 | identical idea, order differs (I checks the timeout first), park guard differs (M keeps running on `bError`) |
| `_GotoTelescope` | 889-1005 (3 axes in parallel) | 990-1120 (HA then Dec or Dec then HA, so the tube stays above the horizon) | skeleton identical (ready, untrack, targets, move, wait, auto-track), move plan site |
| `_SlewTelescope` | 1572-1673 | 1787-1920 | same as goto |
| `_HomeTelescope` | 1006-1057 (no stages) | 1121-1246 (stages; stage 110 ends the power-on, `MarkCompleted` I:1237) | diverged: who completes the startup |
| `_ParkTelescope` | 1058-1185 (3 axes, brake, hydraulics, covers) | 1247-1406 (sequential axes, dome, focus wait #56, covers) | site; stage 100 completion identical |
| `_PowerOn` | 1186-1323 (covers, homing, focus after elevation, move home, `MarkCompleted`) | 1467-1575 (safety acknowledge wait, optional covers, enable, focus, then `bGoHome`) | site; abort prologue identical in purpose |
| `_StopTelescope` | 1784-1828 (one scan: untrack, cancel moves, one stop per axis) | 1921-1958 (three scans: untrack, then cancel, then stop) | diverged |
| `_TrackTelescope` | 1829-1905 | 1959-2008 | site (velocities), skeleton identical |
| `Init` | 1966-2007 (refused during stop/park, logged #80/#87) | 2143-2154 | diverged |
| `Park`, `Stop`, `Reset` | 2044-2064, 2126-2136 | 2155-2162, 2176-2182, 2281-2288 | diverged (#83 defer, #96 restart vs `bUserStop`, `bResetRequest`) |
| `Slew`, `Track`, `Home` | 2107-2188 (`_AcceptMove`) | 2116-2122, 2259-2309 | diverged |
| Telemetry | `_SendTelemetry` 1432-1571 | `_SendTelemetryEquitorial` 1576-1786 | site |

### Extracted units and where they belong [verified, files in `MONETcommon/MONETcommon/MONETcommon/`]

Generic (move to BROTLib): `F_CommandAcceptance` + `E_CommandDecision`, `E_CommandRejectReason`, `ST_CommandState`,
`F_CommandRejectText`, `F_TCSCommandText`; `F_ErrorParkRequest`; `F_ResetMoveAbort` and `F_SuspendStop` (both take
three per-axis BOOLs, generalise to "any enabled axis moving"); `F_GotoTargetCheck`; `F_TargetBelowHorizonWarning`;
`F_HomeBelowHorizon`; `FB_MonetStopTransaction` merged with IAG's `FB_StopTransaction` into one N-axis block.

MONET-specific (stay): `F_AxisTurn` (wrap of azimuth/derotator; generic in principle, only MONET uses it),
`F_AzimuthOffsetOnAxis`, `F_BrakeMustClose`, `F_ParkAxesCanMove` (three axes and a brake), `F_WakeShakeErrorExempt`.
IAG-specific (stay): `FB_SweepStop`, `FB_HomeHold`, `FB_HomeDropReason` (calibration sweep and home texts of the
latch-home axes), `F_HourAngleOffsetOnAxis`.

## Design

### D1. The mock rig: subclass the real axis blocks, override the body

`FB_ElevationMock EXTENDS HalfBROT.FB_ElevationControl` (likewise azimuth, derotator; on IAG
`FB_HourAngleMock EXTENDS FB_HourAngleControl`, `FB_DeclinationMock EXTENDS FB_DeclinationControl`). The body is
overridden and does **not** call `SUPER^()`, so no `MC_*` block and no `AXIS_REF` access runs. The real property
setters stay (`MoveAxis` calls `fbAxis.MoveTo()`, `StopAxis` calls `fbAxis.Stop()`,
`HalfBROT/.../FB_AxisControl.TcPOU` setters at 195-220 and 243-265 [verified]), so the telescope sees the real
command interface. The mock body is a small motion model driven by the levels the telescope writes (`bEnable`,
`bHomeAxis`, `bMoveAxis`, `bTracking`, `bStopAxis`, `fPosition`): enable -> `bReady` after n scans, homing ->
calibrated after n scans, move -> `InMotion` n scans then `MoveDone` and `fActualPosition := fPosition`, stop ->
`Stopping`, `StopDone` after n scans (the `FB_MockStopAxis` model, which already uses the real `FB_AxisCommand`),
`InjectError(nId)`, `Reset()` clears it. It writes what the telescope reads directly: `fbAxis.InMotion`, `InRamp`,
`StandStill`, `Stopping`, `StopDone`, `Homing`, `Busy`, `isTracking`, `MoveDone` (M:694-719, 1684-1698), and on IAG
`axisRef.NcToPlc.StateDWord` bit 29 and `fbLatchHome.Busy` (I:805-807).

Why a subclass and not an interface: M takes `REFERENCE TO FB_ElevationControl` etc. (M:10-12) and I
`REFERENCE TO FB_HourAngleControl` (I:48-49), concrete types, and both read the nested `fbAxis` instance, not a
property. A subclass is assignable to that reference without touching production code.

**[unverified, spike S0]:** (a) that writing `fbAxis.<output>` from the derived block compiles (if not, the
`POINTER TO` route of `FB_Axis_Tests.SetActPos` works for plain outputs); (b) that a body override without
`SUPER^()` compiles for `FB_ElevationControl` (not declared `FINAL`, so expected yes); (c) that the `AT%I*` variables
of `FB_AxisControl` (`HalfBROT/.../FB_AxisControl.TcPOU:21-24`) do not prevent instantiation on the test target (the
cover spike showed unlinked `AT%I*` works, `MONETcommon/specs/plans/2026-09-22-add-tcunit-tests.md`).

Small interface mocks: `FB_CoversMock` (`I_MirrorCovers`: Open, Close, Opened, Closed, Error, Reset),
`FB_BrakeHydraulicsMock` (`I_Brake` + `I_Hydraulics`; MONETS MAIN passes `HydraulicsControl` for both,
`MONETS/.../MAIN.TcPOU` telescope call), `FB_FocusMock` (`I_Focus`; after #122 also `Stop`, `MinPosition`,
`MaxPosition`), on IAG `FB_DomeMock` (`I_Dome`, 15 members). Pointing: the real `FB_PointingModelForward`/
`FB_PointingModelInversion` with zero coefficients. Comm: the existing `FB_NullComm`.

A rig block per telescope (`FB_MonetRig`, `FB_IagRig`) owns the telescope and the mocks and has `Scan()` in the
MONETS/IAG MAIN order (telescope first, then covers, hydraulics, axes, focus; `MONETS/.../MAIN.TcPOU` and
`IAG50cm/IAG50cm/POUs/MAIN.TcPOU:30-58` [verified]) plus helpers `PowerOnToReady(nMaxScans)`, `ScanUntil(...)`.

**Time.** Scenario steps that only need scans run many `Scan()` calls in one PLC cycle. Timers (`TON`) do not
advance inside one cycle **[unverified, standard TwinCAT behaviour]**, so steps that wait on a timer (tracking
delay 5.5 s M:699-701, mock `bReady` if it uses the real `tonReadyDelay`, 15 s stop timeout) span cycles in a
multi-cycle TcUnit test. The 600 s / 2 min / 12 h timeouts are out of reach without a time seam (open question 4).

### D2. Characterization, not specification

Each test asserts what the code does today, with the line it pins in a comment. Where the current behaviour looks
wrong, the test still pins it, its name ends in `_Current`, and an entry goes into "Findings" at the end of this file
for Tim to decide. A decided change is a separate commit that flips the assertion.

### D3. Target shape (step 5)

A template-method base in BROTLib (D-open 1 for where), split in two so the hard part stays testable without axes:

- **`FB_CommandArbiter`** (pure logic, like `FB_StartupControl`): inputs the command flags, a per-axis status array
  and the telescope state; outputs `TCS_command`, which flags to clear, which stage machines to reset
  (interrupt), abort-stop request, the per-command timeout. Holds the generic N-axis stop transaction. Tested in
  BROTLibTests with no axis at all.
- **`FB_BaseTelescopeControl`** body (the skeleton): `BeginScan`, clock, `_ReadAxes()` (hook, fills
  `ST_AxisStatus` array: enabled, standStill, moving, stopping, stopDone, stopAxisLevel, tracking, busy, calibrated,
  error, errorID), error reaction, `_ComputeTargets()` (hook), guards (hook `_HorizonGuard`), arbiter, dispatch to
  the `ABSTRACT` hooks `_PowerOn`, `_Park`, `_Goto`, `_Slew`, `_Home`, `_Track`, `_SetStopAxis(i, b)`,
  `_CancelMoves()`, `_Untrack()`; then status, `fbStartup.Update`, release, events, telemetry (`_SendTelemetry` hook).
- `nAxes` and a fixed `ARRAY[1..4]` (TwinCAT has no open arrays outside `VAR_IN_OUT`). MONET 3, IAG 2.
- `FB_AltAzTelescopeControl` / `FB_RaDecTelescopeControl` keep only the coordinate parts; the axis blocks stay
  concrete (`REFERENCE TO`) in the MONETcommon / IAG50cm subclasses, because BROTLib cannot reference HalfBROT.
- Site policy where the two differ (park vs power-on, automatic stop vs power-on, reset without error) are inputs or
  overridable methods of the base (`_PowerOnAbortedByPark : BOOL`, ...), decided per site in step 4.

`ABSTRACT` is supported by the XAE build in use (B:4 and HalfBROT `FB_AxisControl.TcPOU:4` compile) [verified
indirectly]; `ABSTRACT` methods on a function block and `PROTECTED` access are standard in 4024 **[unverified on
this build]**.

## Steps

Every step: branch from `develop`, PR, CI green (`tcbuild.yml`), merge. "Release" says what the step means for the
versions; numbers are provisional because #93/#92 (BROTLib 0.9.1) and #122 (BROTLib 0.10.0, HalfBROT 0.6.0,
MONETcommon 0.9.4 or 0.10.0) come first.

### Step 0: spikes and prerequisites

**0.1 Wait for #122.** It adds `fbFocus.Stop()` to `_StopTelescope`/`Stop` in M and I and three members to
`I_Focus`. Characterization against pre-#122 code would be thrown away, and `FB_FocusMock` must implement the new
`I_Focus`. Start step 1 on the MONETcommon `develop` that pins the #122 BROTLib/HalfBROT.

**0.2 Mock spike (MONETcommonTests).** Files: `MONETcommonTests/.../POUs/FB_ElevationMock.TcPOU`, `MAIN.TcPOU`, one
suite `FB_MonetRig_Spike_Tests` with `Rig_Instantiates_Telescope_With_Mock_Axes` (assign references, 10 scans, no
exception, `bError` FALSE) and `Mock_Axis_Move_Reports_MoveDone`. Acceptance: green on the runner; answers D1 (a)-(c).
If (a) fails both ways, fallback: NC simulation axes in the test target **[unverified: the user-mode runtime runs NC
simulation axes]**, decided with Tim before step 1. Release: none.

**0.3 IAG50cmTests reach.** Two obstacles [verified]: the test project has no BROTLib/AstroBROT reference, and
`FB_TelescopeControl` instantiates `fbCabinet : FB_CabinetControl` (I:56), whose unlinked `AT %I*` contacts read
FALSE, so `bCabinetError := NOT(... AND ...)` is TRUE (`IAG50cm/IAG50cm/POUs/FB_CabinetControl.TcPOU`, first body
line) and `bError` (I:281) is TRUE in every test. Spike: add `BROTLib, <pin> (BROT)` to `IAG50cmTests.plcproj`,
extend `Sync-Sources.ps1` with the dependency closure of `FB_TelescopeControl` (axis controls, `FB_AxisControl`,
`FB_LatchHome`, `FB_CabinetControl`, pointing blocks, `F_HourAngleOffsetOnAxis`, `ST_TelescopeConfig`,
`FB_StopTransaction`, `FB_SweepStop`, `FB_HomeDropReason`, GVLs), and set the five contacts TRUE through pointers
each scan (no production change). Acceptance: `Rig_Instantiates_Iag_Telescope` green with `bError` FALSE.
Fallback: a behaviour-neutral IAG commit that makes the cabinet an input (`I_Cabinet` or a reference), with on-site
check. Release: none.

### Step 1: MONETcommon characterization suites (MONETcommon#36)

Files (all new, `MONETcommon/MONETcommonTests/MONETcommonTests/MONETcommonTests/POUs/`): `FB_AxisMockCore`,
`FB_ElevationMock`, `FB_AzimuthMock`, `FB_DerotatorMock`, `FB_CoversMock`, `FB_BrakeHydraulicsMock`,
`FB_FocusMock`, `FB_MonetRig`, five suites below; `MAIN.TcPOU` declarations; `MONETcommonTests/README.md` table.
Test names follow the house style (`TEST('Name')`).

- `MonetStopDuringSlew_Tests`: `Stop_During_Slew_One_Stop_Edge_Per_Moving_Axis` (`nStopCalls` 1 for each moving
  axis, 0 for the axis at rest), `Stop_During_Slew_Clears_All_Move_Flags` (M:519-529),
  `Stop_Released_Only_After_Settled` (`bStop` TRUE until StopDone of every stopped axis and 3 scans at rest,
  M:1730-1731), `Repeated_Stop_Restarts_Only_Moving_Axes` (M:2131-2133), `Goto_During_Slew_Supersedes_With_Abort_Stop`
  (M:463-491), `Park_During_Stop_Runs_After_Settle` (M:2050-2054, 1738-1742).
- `MonetParkDuringPowerOn_Tests`: `Park_At_Cover_Stage_Aborts_PowerOn` (M:533-545, `fbStartup.Initializing` FALSE,
  `TCS_command` stop then park), `Park_During_Homing_Stops_Moving_Axes_First`, `Park_After_Cover_Command_Closes_Covers`
  (#113, M:1241), `Init_During_Park_Refused` (M:1972-1981), `Stop_During_PowerOn_Aborts_Startup` (M:508-518).
- `MonetResetUnderMotion_Tests`: `Reset_While_Slewing_Keeps_Abort_Stop` (`bMoveAbortPending` TRUE, no `Reset()` on a
  moving axis, M:221-226), `Reset_At_Rest_Clears_Pending_Moves`, `Reset_During_Park_Keeps_Park` (M:215-223),
  `Reset_Recovers_Stuck_Stopping_Axis` (M:191-205), `Reset_During_PowerOn_Stage10_Current` (the power-on is aborted,
  open point of #56).
- `MonetErrorPark_Tests`: `Elevation_Error_Starts_Emergency_Park` (M:495-504, brake closed, axes disabled, covers
  closed, `bIsParked` at the end), `Focus_Error_Starts_Emergency_Park`, `Error_On_Parked_Telescope_No_Park`,
  `Error_During_Estop_No_Park`, `First_PowerOn_AzEl_Error_Exempt` (#113, M:497-500), `Persisting_Error_No_Second_Park`.
- `MonetSuspendUnderMotion_Tests`: `Suspend_While_Slewing_Stops_Each_Moving_Axis_Once` (M:1354-1366),
  `Suspend_At_Rest_No_Stop`, `Suspend_Drops_Queued_Moves_Keeps_Park` (M:1343-1353), `Suspend_Blocks_Jog_Until_Settled`
  (M:1385-1390), `Suspend_Stuck_Stop_Hands_Over_And_Keeps_Abort` (M:1400-1409), `Back_To_Automatic_Error_No_Park`
  (M:1334).

Acceptance: all green against unchanged MONETcommon; every red test is either a rig bug (fix the rig) or a finding
recorded below with the line it pins. Suite count 19 + 6 = 25 of 32. Release: none (test project only; it references
`MONETcommon, *`, which CI installs from the branch).

### Step 2: IAG50cm characterization suites

Files: `IAG50cm/IAG50cmTests/IAG50cmTests/IAG50cmTests/POUs/` `FB_HourAngleMock`, `FB_DeclinationMock`,
`FB_FocusMock`, `FB_DomeMock`, `FB_CoversMock`, `FB_IagRig`, suites below; `tools/Sync-Sources.ps1`;
`IAG50cmTests.plcproj` (BROTLib pin, new POUs); `README.md`.

- `IagStopDuringSlew_Tests`: `Stop_During_Slew_One_Stop_Per_Moving_Axis`, `Stop_Sequence_Takes_Three_Scans`
  (I:1927-1953), `Stop_Clears_Only_First_Flag_Current` (I:507-526), `Stop_Released_On_Bare_Standstill_Current`
  (I:855-857), `Home_Waits_For_Settled` (I:678).
- `IagParkDuringPowerOn_Tests`: `Park_During_PowerOn_Waits_Current` (power branch first, I:529), `PowerOn_Cancels_Pending_Park`
  (I:533-541), `Automatic_Stop_Does_Not_Abort_PowerOn` (I:501), `User_Stop_Aborts_PowerOn`.
- `IagResetUnderMotion_Tests`: `Reset_Without_Error_Ignored` (I:205), `Reset_With_Error_Resets_All_Errored_Axes`
  (I:266-270, 1415-1423), `Second_Pass_After_Ack_Delay` (I:271-275, multi-cycle 2.5 s).
- `IagErrorPark_Tests`: `Axis_Error_Disables_Axes_No_Automatic_Park_Current`, `Park_During_Error_Closes_Covers_Parks_Dome`
  (I:555-630, `bIsParked` stays FALSE), `Park_With_Axes_Off_Does_Not_Move_Mount` (#54).
- No suspend suite: IAG has no manual-mode suspension (above). Recorded as N/A, not as a gap.

Acceptance: as step 1. Release: none.

### Step 3: behaviour-neutral refactors, one per PR, tests after each

Order chosen so later extraction is a move of finished pieces.

| # | Repo | Change | Files | Acceptance |
|---|---|---|---|---|
| 3.1 | MONETcommon | `_ReadAxes()` fills an `ST_AxisStatus` array once per scan; `_StopTxInputs`, `bStopped`, `bBusy`, `bSlewing` read it instead of `fbX.fbAxis.*` | M | all step-1 suites green, no test edited |
| 3.2 | IAG50cm | the same (`ST_AxisStatus` local until step 4) | I | all step-2 suites green |
| 3.3 | MONETcommon | the event block (M:769-879) into `_LogEvents()`; the reset block (M:182-236) into `_HandleReset()` | M | green |
| 3.4 | IAG50cm | the same for I:888-985, I:201-275 | I | green |
| 3.5 | both | stage-machine prologue into one private `_StageGuard(...) : BOOL` per FB, keeping each FB's order | M, I | green |

Release: MONETcommon patch (0.9.x+1) with 3.1/3.3/3.5, MONETS/MONETN re-pin; IAG50cm patch with 3.2/3.4/3.5.
Neutral by intent, but they touch the scan order of every axis read, so each release gets the short on-site smoke
test (power-on, slew, stop, park; MONETcommon#63/#64 checklists) on MONET/S first, then MONET/N, IAG50cm.

### Step 4: pure units into BROTLib, IAG adopts one at a time

**4.1 BROTLib (one PR):** new folder `BROTLib/BROTLib/BROTLib/Telescope/Command/`: `E_CommandDecision`,
`E_CommandRejectReason`, `ST_CommandState`, `F_CommandAcceptance`, `F_CommandRejectText`, `F_TCSCommandText`,
`F_ErrorParkRequest`, `F_ResetMoveAbort`, `F_SuspendStop` (signature: `bAnyAxisMoving` instead of Az/El/Dr),
`F_GotoTargetCheck`, `F_TargetBelowHorizonWarning`, `F_HomeBelowHorizon`. Tests move from MONETcommonTests to
BROTLibTests unchanged in content (`F_CommandAcceptance_Tests`, `F_ErrorParkRequest_Tests`, `F_ResetMoveAbort_Tests`,
`F_SuspendStop_Tests`, `F_GotoTargetCheck_Tests`, `F_TargetBelowHorizonWarning_Tests`, `F_HomeBelowHorizon_Tests`).
Acceptance: BROTLibTests green with the moved suites; README telescope section. Release: BROTLib minor (additive,
after 0.10.0; consumers stay on their pin until they bump).

**4.2 BROTLib generic stop transaction:** `FB_StopTransaction` for up to 4 axes, union of both: per-axis issue/done,
latched-level write-low (M), `Restart` (M), `bForced`/`bStuck` (M), motion-lock input and homing abort (I), settle
after 3 scans. Test suite `FB_StopTransaction_Tests` = both existing suites (`FB_MonetStopTransaction_Tests`, IAG's
`FB_StopTransaction_Tests`) re-expressed against the new block, plus `StopLoop_Sim_Tests`. Same BROTLib release as
4.1 or the next.

**4.3 MONETcommon adopts:** pin the new BROTLib (`MONETcommon.plcproj:125`, tests `:110`) and HalfBROT if the chain
needs it (below), delete the moved POUs and `FB_MonetStopTransaction`, remove the moved suites from MONETcommonTests.
Same PR, because a POU in MONETcommon and one in BROTLib with the same name may be ambiguous in MONETS/MONETN
**[unverified]**. Acceptance: step-1 suites green unchanged. Release: MONETcommon minor, MONETS/MONETN re-pin, on-site
smoke test.

**4.4 IAG50cm adopts, one unit per PR.** Pin bump first (`IAG50cm.plcproj:224`), then:
(a) `FB_StopTransaction` from BROTLib replacing the local one (neutral if the new inputs are wired like today);
(b) `F_ResetMoveAbort`-style abort on reset, (c) `F_CommandAcceptance`, (d) `F_ErrorParkRequest` are **behaviour
changes** for IAG: each only after Tim's decision on the matching finding, each its own commit that updates the
step-2 assertions it flips. Release: IAG50cm minor per batch, on-site check on IAG50cm (stop, park, reset, power-on).

**Chain order and pins.** Today: HalfBROT pins `BROTLib, 0.9.0` (`HalfBROT.plcproj:102`); MONETcommon pins AstroBROT
0.4.5, BROTLib 0.9.0, HalfBROT 0.5.7 (`MONETcommon.plcproj:121/125/129`); MONETS (`MONETSRuntime.plcproj:102/106/110/118`)
and MONETN (`MONETNRuntime.plcproj:96/100/104/112`) pin all four; IAG50cm pins BROTLib 0.9.0 only. CI reinstalls the
pinned releases before each build (`tools/Install-PinnedLibraries.ps1`, every repo). Releases: `release.yml` bumps
`ProjectVersion` on `develop` and opens the PR to `main`; `tag-release.yml` tags on the merge and dispatches
`release-library.yml`, which attaches the `.library` (IAG50cm has no library workflow, tag only). Whether MONETS can
pin a newer BROTLib than the one HalfBROT was built against without re-releasing HalfBROT depends on placeholder
resolution **[unverified]**; until checked, keep the order BROTLib -> HalfBROT (re-pin, patch) -> MONETcommon ->
MONETS/MONETN, as the #122 plan does. One CI check would settle it.

### Step 5: the arbitration skeleton in BROTLib

**5.1 `FB_CommandArbiter` (BROTLib, pure logic)** per D3, built from the MONET arbitration (M:461-646) with the site
policies as inputs. `FB_CommandArbiter_Tests` in BROTLibTests: the arbitration rows of both telescopes as tables
(stop beats all; park vs power-on per policy input; abort stop before the next command; latest move wins; idle clears
axis commands; per-command timeout restart). Release: BROTLib minor, additive.

**5.2 MONETcommon on the arbiter.** M's arbitration block replaced by the arbiter call; stage machines unchanged.
Acceptance: every step-1 suite green without edits. Release: MONETcommon minor, on-site full check (MONETcommon#63/#64
lists) on MONET/S, then MONET/N.

**5.3 IAG50cm on `FB_BaseTelescopeControl`.** First a neutral PR: `FB_TelescopeControl EXTENDS
FB_RaDecTelescopeControl` (cleaned of its dead body) and the duplicate declarations deleted. Blocker: the base's
`telescopeConfig : ST_TelescopeConfig` (B:39) clashes with IAG's own struct of the same name. Options: the base drops
`telescopeConfig` and asks for site/location through properties, or BROTLib's struct gains HA/Dec park/home fields
(MONETS/MONETN constant initialisers unaffected). Then the arbiter as in 5.2. Acceptance: step-2 suites green.
Release: IAG50cm minor, on-site full check.

**5.4 Template body in `FB_BaseTelescopeControl`.** Move the skeleton (D3) into B with `ABSTRACT` hooks; M and I
implement the hooks and stop calling the arbiter themselves. Breaking for anything that extends B or
`FB_AltAzTelescopeControl`: MONETcommon and HalfBROT `FB_PendantControl` (REFERENCE, so only member names matter).
Release: BROTLib minor (pre-1.0 minor = breaking), HalfBROT re-pin + release, MONETcommon minor, MONETS/MONETN,
IAG50cm. On-site full check on all three telescopes. Closes BROTLib#25 (also update its text: two copies, not three)
and MONETcommon#24 item 2.

### Step 6: on site, per released step

Mocks cannot show NC timing, brake/hydraulics, STO and drive behaviour. Minimum per release: MONET/S (power-on,
slew, stop during slew, park during power-on, reset under motion, switch to manual under motion, emergency park by an
injected axis error only if Tim agrees to provoke one), then MONET/N the same, IAG50cm (power-on, slew, stop, park,
reset after an error). Cross-reference the existing lists MONETcommon#61-#65; record results in this file.

#### Checklist for the first visit (2026-10-22): MONETcommon 0.9.6, BROTLib 0.10.3, IAG50cm 0.4.3

Covers the time seam and the timer swap (0.9.5), the refactors 3.1 to 3.4 (0.9.6) and the open MONETcommon#122 retest. Intended
behaviour change of the refactors: none. Note the installed versions first (rollback target). If a check fails, stop and roll back
before the next telescope. Results go into this section and as a comment on the issues.

Before the visit: cut and merge a MONETS and a MONETN release (pins BROTLib 0.10.3, HalfBROT 0.6.0, MONETcommon 0.9.6); IAG50cm 0.4.3 is tagged.

**A. MONET/S, then MONET/N**

- [ ] 1. Power-on from parked: READY_STATE 1.0 (note the time, new warnings or rejections in the log)
- [ ] 2. Slew to a safe position: axes move and arrive, `bSlewing` TRUE then FALSE
- [ ] 3. Stop during the slew (`stop=1`): each axis stopped once, `bStopped` TRUE, no error
- [ ] 4. Park during power-on: the park wins (MONETcommon#87), covers close, telescope parks
- [ ] 5. Reset under motion: abort stop, no moving axis is reset, no NC error 0x4260
- [ ] 6. Switch to manual under motion: axes stop once, then the pendant gets them; back to automatic is clean
- [ ] 7. Goto and track over a night: no false timeout errors 16#10/16#30/16#40, no unexpected rejections
- [ ] 8. Emergency park by an axis error: only if provoked with Tim's agreement, otherwise "mock only"

**B. MONETcommon#122 retest (MONET/S, focus online and idle)**

- [ ] 1. `focus=30` moves from 36.0 and reaches about 30
- [ ] 2. `focus=500` is rejected or clamped with a log message, the focus does not run past the limit
- [ ] 3. `focus=36` redirects the focus to 36
- [ ] 4. `stop=1` stops the focus axis

**C. IAG50cm**

- [ ] 1. Power-on  - [ ] 2. Slew  - [ ] 3. Stop during the slew  - [ ] 4. Park
- [ ] 5. Reset after an error: errored axes reset, second pass about 2.5 s later
- [ ] 6. Normal use over a night

Record per check: result (pass, fail, deviation), date and time, installed versions, log lines for anything unexpected, and the
actual focus positions for B.

**Results:** (not run yet)

## Risks

- **The mock lies.** Scenario tests pass on a motion model; real `MC_Stop`/`MC_MoveAbsolute` timing differs (e.g. the
  one-scan false standstill IAG50cm#98, `StopDone` skew #96). Mitigation: reuse the measured models
  (`FB_MockStopAxis`), keep on-site checks per release, say "pinned by mock" in each test comment.
- **Spike S0 fails** (outputs not writable, body override not allowed): fall back to NC simulation axes or a seam
  in HalfBROT (properties instead of `fbAxis.*` reads), which is a HalfBROT change and a release.
- **#122 overlap.** Both `_StopTelescope`s and `I_Focus` change; starting early means rework or merge conflicts with
  the other agent's work.
- **Time-bound behaviour untested** (600 s, 2 min, 12 h timeouts). Findings there stay on-site only unless a time
  seam is added (open question 4).
- **Release churn.** Every BROTLib step can drag HalfBROT, MONETcommon, MONETS, MONETN and IAG50cm along, each with an
  on-site check; the single CI runner serialises everything. Batch neutral steps into one release per repo.
- **Name collisions** between moved POUs and leftovers in MONETcommon/IAG50cm during the transition (4.3).
- **TcUnit limits**: 32 suites per project; MONETcommonTests reaches 25 in step 1 (raise `MAXNUMBEROFTESTSUITES` in
  the `.plcproj` if needed).
- **IAG test project copies sources**; a bigger closure in `Sync-Sources.ps1` means more files to keep in step.

## Open decisions (for Tim)

Each decision carries a **Recommendation** (Claude, 2026-10-21; not yet confirmed by Tim). Decide 3 and 4 before step 1,
because they shape the tests; the rest can wait until the characterization suites are green.

1. **Base class home:** BROTLib (`FB_BaseTelescopeControl` already lives there, BROTLib#25 asks for it, one less repo)
   or a new shared library between BROTLib and MONETcommon/IAG50cm (smaller BROTLib releases, HalfBROT not dragged
   along by telescope changes, but one more repo, CI job, pin and release in every chain).
   **Recommendation: BROTLib (not yet confirmed).** Tim said on 2026-10-21 that IAG50cm is meant to use BROTLib's
   `FB_RaDecTelescopeControl` eventually (README says the same), which points to BROTLib, so the target chain is `FB_BaseTelescopeControl` with two subclasses, `FB_AltAzTelescopeControl` (MONET)
   and `FB_RaDecTelescopeControl` (IAG50cm). Finishing the RaDec class (BROTLib code review M8: `fJD` never set,
   reads `fRightAscensionCurrent`/`fDeclinationCurrent`, own `VAR PERSISTENT` pointing terms, dead body) and the
   `ST_TelescopeConfig` clash (5.3) are part of step 5.3, not a side task.
2. **Inheritance only, or arbiter + template:** the pure `FB_CommandArbiter` (step 5.1, testable like
   `FB_StartupControl`) with a thin template body (5.4). Stopping after 5.3 (composition, no template body) is a
   valid end state and avoids the breaking change to `FB_AltAzTelescopeControl`.
   **Recommendation:** go to 5.4 (IAG50cm moving onto the RaDec class makes inheritance the target), but treat 5.3 as a
   checkpoint: stop there if 5.4 turns out to cost more than it saves.
3. **Policy per divergence** (each becomes a finding and, if wanted, a separate commit): park vs power-on precedence;
   automatic stop aborts power-on; stop clears all flags (I); park kept during a stop (I); stop released only when
   settled (I); reset without an error (I); emergency park on a new error (I); command acceptance at arrival (I);
   timeouts counted only while dispatched, idle park fires once, all errored axes reset (M gets IAG's fixes); horizon
   guard gated on ready (M).
   **Recommendation:** the side with the newer fix wins, each as its own commit with its own test, never inside a
   move. MONET's fixes go to IAG: stop clears every flag (#84), park survives a stop, stop released only when settled
   (#96), command acceptance (#83), emergency park on a new error (#86). IAG's fixes go to MONET: timeouts count only
   while the command runs (#75), the 12 h idle park fires once, all errored axes are reset (#11), horizon guard only
   when ready (#82). **Park vs power-on is the exception:** the precedence differs today and is a safety behaviour.
   Default to MONET's rule (park wins over power-on, MONETcommon#87) but make it a policy input of the arbiter and
   have Tim, or whoever runs IAG50cm, decide it for IAG explicitly.
   **Decided (Tim, 2026-10-22): agreed.** Pinned by the characterization suites: axis error (MONET emergency park goes to
   IAG), reset without an error (IAG ignores it, goes to MONET), park during power-on (park wins, as an arbiter input
   `bParkWinsOverPowerOn`; the IAG50cm owner still has to confirm it for IAG before IAG changes). Order: IAG safety
   changes first, MONET behaviour changes last, each as its own commit and release.
4. **Time seam** for the long timeouts (600 s, 2 min, 12 h): none (on site only), or an injectable time source in
   the timeout blocks.
   **Recommendation:** add the seam, small and test-only. The timeouts are where the state machine hides bugs and a
   12 h timer cannot be checked on site. The default is the real clock, so production behaviour does not change. If it
   turns out to be invasive, fall back to testing the timeouts through pure functions only.
   **Decided (Tim, 2026-10-22): agreed.** Do it before the steps that move the timeout logic (3 to 5).
5. **IAG cabinet in tests:** pointer writes from the test (no production change) or make the cabinet an input.
   **Recommendation:** pointer writes (step 0.3). Making the cabinet an input is the cleaner design, but it changes
   IAG's interface during the refactor. Revisit it as its own small change once IAG sits on the shared base.
6. **Version numbers:** BROTLib minor per step 4/5 stage, or hold step 4 and 5 for one larger BROTLib release.
   **Recommendation:** release the small neutral moves of step 4 on their own; batch step 5.1 to 5.3 into one BROTLib
   release if the tests are green. Keep the breaking template body (5.4) separate. Every BROTLib release means a pin
   bump in MONETcommon, HalfBROT, MONETS, MONETN and IAG50cm, and the `FB_AltAzTelescopeControl` change forces a
   HalfBROT release, so schedule that one on purpose.

## Findings

(Filled while steps 1 and 2 run: test name, pinned line, current behaviour, proposed decision.)

### Step 3 (2026-10-22)

- Done and merged on develop, unreleased: 3.1/3.2 `_ReadAxes` + `ST_AxisStatus` (MONETcommon#138, IAG50cm#149), 3.3/3.4 `_LogEvents` +
  `_HandleReset` (MONETcommon#140, IAG50cm#150), all characterization suites green and unedited. In IAG50cm the axis reset of #11 stays in
  the body: it runs after the error ID, and an axis `Reset()` can change the state the ID is derived from.
- **3.5 `_StageGuard` not done, proposed to drop from step 3.** The prologues of the stage machines are not the same thing:
  IAG50cm uses `bReset OR bError OR bStop OR bInterupted` in goto/home/park/slew (the power-on has its own, with `NOT bPower`);
  MONETcommon uses four variants: goto/slew `bReset OR bError OR bInterrupted OR NOT <flag>`, home `bReset OR bError OR bInterrupted` (no stage
  reset), park `bReset OR bStop OR bInterrupted` (no `bError`, the emergency park needs it), power-on `bReset OR bStop OR bInterrupted`.
  One guard per FB would only cover goto/slew on MONET and would bake the differences in. They are the decision-3 divergences (does a stop
  abort a power-on, does an error abort a park), so the guard belongs to the arbiter/template of step 5, as a policy.
- Time seam (decision 4) done: `FB_TimeoutTimer` with a per-instance `nDivisor` (BROTLib 0.10.3), `nTimeDivisor` on both telescope FBs,
  timeout suites `MonetTimeouts_Tests` (3) and `IagTimeouts_Tests` (2). A global divisor does not work: TcUnit runs all suites in the same
  PLC cycles.

## Not in this plan

- Focus behaviour (MONETcommon#122, other agent).
- SoE reset unification (BROTLib#67): same pattern (one sequence in `FB_BaseAxis`), separate plan; IAG's
  `FB_DeclinationControl`/`FB_FocusControl` still use the old `IF NOT fbSoEReset.Busy` pattern (lines 134-141, 86-93).
- MONETcommon#24 items 3-6 (mutable inputs, site constants, coupling): partly helped by step 5, not targeted.
- Telemetry unification (`_SendTelemetry` vs `_SendTelemetryEquitorial`): site-specific, stays.
