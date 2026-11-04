# UI tiers and the HMI gateway (`FB_HmiGateway`, `I_Cabinet`)

Date: 2026-11-04. Status: **proposed**, design only; nothing implemented.

Repos: BROTLib (`I_Cabinet`, `FB_HmiGateway`, `FB_Comm_MQTT_Influx`), MONETcommon, MONETN, MONETS, IAG50cm,
HalfBROT (axis blocks), BROTweb (consumer).

Consumer side (pages, widgets, touch rules, deployment): [BROTweb `docs/design.md`](https://github.com/BROTLib/BROTweb/blob/main/docs/design.md).
Cross-repo work breakdown and the decision record are kept in IAG's private specs (plan `2026-11-04-hmi-middle-tier.md`,
ADR `fleet-0002`); everything needed to implement the PLC side is in this document.

This document is the PLC-side contract of the middle UI tier: which interfaces the HMI uses, who may move the telescope
in which mode, and the adapter block that makes the `I_*` interfaces reachable over ADS.

## 1. Three UI tiers

| Tier | What | Users | Transport | Scope |
|---|---|---|---|---|
| Bottom | TwinCAT VISU screens (`VISUs/*.TcVIS` in MONETS/MONETN) | PLC developers | in the PLC | everything, including internals (NC axis details, flags, test switches). Not gated, not designed for routine use. |
| Middle | BROTweb (TwinCAT HMI) on the touch screen in the cabinet door, also from a laptop | technicians, maintainers | ADS (RPC methods + read of one status struct) | everything needed to **service** the telescope: status, why-not-ready, axes (jog, home), subsystems (covers, hydraulics, focus, derotator, roof/dome, Nasmyth, filter, brake), safety diagnostics read-only, pointing in native coordinates plus one RA/Dec target. |
| Top | pyobs-brot (robotic), BROTgui (Qt desktop) via pybrotlib | observers, robotic scheduler | MQTT verbs (`power`, `park`, `gohome`, `track`, `slew`, `stop`, `reset`, ...) handled by `FB_Comm_MQTT_Influx` | everything needed to **observe**: catalogues, Stellarium, sessions, offsets, tracking, instrument sequences. |

Boundary rules:

- A function belongs to the middle tier when a technician needs it at the telescope with the robotic system switched
  off or the broker down (homing an axis, jogging the focus, running the hydraulics, finding out why the telescope
  is not ready). It belongs to the top tier when it only makes sense for observing (catalogues, pointing offsets,
  tracking a list of targets). The one overlap is a single RA/Dec target on the pointing page (equatorial pointing for
  tests), without catalogues.
- The middle tier is not a port of the VISU: the eleven MONETS VISU screens are not rebuilt one to one. Developer
  details (NC parameters, raw flags, Scope settings) stay in the VISU.
- The middle tier uses only `MAIN.Hmi` (section 5). It never binds to project internals such as
  `MAIN.TelescopeControl.*`.

## 2. Verified state of the code (2026-11-04, `origin/develop` of every repo)

### 2.1 Interfaces (BROTLib `Interfaces/`, `POUs/Comm/I_Comm`)

| Interface | Commands | State | Gaps for the HMI |
|---|---|---|---|
| `I_Telescope` | `Init`, `Home`, `Park`, `Track(ra, dec)`, `Slew(az, alt)`, `Stop`, `Reset` (each starts its command once; MONETcommon#24 step 5) | `ReadyState`, `Altitude`, `Azimuth`, `RightAscension`, `Declination`, `CoverAutoOpen` (get/set) | no error, busy, parked, E-stop or reject reason. `RightAscension`/`Declination` are not the current position: MONETcommon returns the commanded target (`fRightAscension`), IAG50cm returns nothing (empty getters). `Altitude`/`Azimuth` are the current position without pointing correction in both. |
| `I_AltAzTelescope` | - | offsets (az, alt, derotator), `Dut1`, `Weather` | - |
| `I_RaDecTelescope` | - | `HourAngleOffset`, `DeclinationOffset` | no move in native HA/Dec: `Slew` takes Az/Alt also on IAG50cm. |
| `I_BaseAxis` | `Reset()`; properties written as commands: `HomeAxis` (rising edge starts homing), `MovePos`/`MoveNeg` (jog levels), `Enable`, `Position` (target), `Velocity` | `ActualPosition`, `Busy`, `Calibrated`, `Error`, `ErrorID`, `InPosLimit`, `InNegLimit`, `Ready` | no `Stop()`, no jog speed. |
| `I_Axis` (extends `I_BaseAxis`) | flag properties `MoveAxis`, `StopAxis`, `Tracking` | `isTracking`, `MoveDone`, `SlewTime` | - |
| `I_Focus` (extends `I_BaseAxis`) | `Stop()` | `MinPosition`, `MaxPosition` | no manual home: MONET's focus homes from the VISU through `FB_FocusControl.bManualHome` (HalfBROT#138), not through the interface. |
| `I_MirrorCovers` | `Open`, `Close`, `Reset` | `Opened`, `Closed`, `Error` | no `Stop()` (HalfBROT `FB_CoverControl` has one; MONETcommon keeps a concrete reference for that reason). |
| `I_Hydraulics` | `Reset`; level properties `Enable`, `ManualStartSuction`, `ManualStopPump` | `PumpRunning`, `SuctionRunning`, `OilPressureOK`, `Error` | - |
| `I_Brake` | `OpenBrake`, `CloseBrake` | `BrakeOpen` | - |
| `I_Roof` | `Open`, `Close`, `Stop`, `Reset` | `State : E_RoofState` | no position. |
| `I_Dome` | `Open`, `Close`, `Park`, `Stop`, `Track`, `StopTrack`, `Reset` | `Position`, `RotState`, `ShutterState`, `Parked`, `Tracking`, `Error`, `ErrorID`, `Capabilities` | - |
| `I_Filter`, `I_Nasmyth` | `SetFilter(pos)`, `SetNasmyth(port)` | none | no implementation in any checked repo. |
| E-stop, safety, Local/Remote, pendant | - | - | **in no interface.** `FB_BaseTelescopeControl.bEstopTriggered` is a plain input fed by each `MAIN`. |

The interfaces form an `EXTENDS` hierarchy: `I_AltAzTelescope` and `I_RaDecTelescope` extend `I_Telescope`;
`I_Axis` and `I_Focus` extend `I_BaseAxis`. A reference to a sub-interface converts implicitly to its base, so a
consumer takes the most specific interface it needs and gets the base for free; the same object never has to be
wired twice. The gateway therefore has one input per **distinct subsystem kind** (section 5.2), not one per interface.

`__System.IQueryInterface` (and with it `__QUERYINTERFACE`) is deliberately **not adopted** (decided): it would need a
change to all 13 interfaces in `Interfaces/` and a version bump of BROTLib and every consumer; it moves wiring errors
from compile time (a block that does not implement the input's interface does not compile) to runtime (a query that
returns FALSE); and it is not needed for a fixed vocabulary of subsystem kinds. Revisit only if a generic list of
unknown subsystem kinds is ever wanted.

Related check (2026-11-04, `origin/develop` of all PLC repos): IAG50cm `FB_TelescopeControl` was declared
`IMPLEMENTS I_RaDecTelescope, I_Telescope`, which is redundant because `I_RaDecTelescope` already extends
`I_Telescope`; no other block lists both a sub-interface and its base.

Implementations:

| Interface | MONETS/MONETN (MONETcommon, HalfBROT, MONETRoof) | IAG50cm |
|---|---|---|
| `I_AltAzTelescope` | `FB_MonetTelescopeControl` (extends `FB_AltAzTelescopeControl`) | - |
| `I_RaDecTelescope` (hence `I_Telescope`) | - | `FB_TelescopeControl` (standalone) |
| `I_Axis` | HalfBROT `FB_AzimuthControl`, `FB_ElevationControl`, `FB_DerotatorControl` | `FB_HourAngleControl`, `FB_DeclinationControl` (via `FB_AxisControl`) |
| `I_Focus` | HalfBROT `FB_FocusControl` | `FB_FocusControl` |
| `I_MirrorCovers` | HalfBROT `FB_CoverControl` | `FB_CoverControl` |
| `I_Hydraulics`, `I_Brake` | HalfBROT `FB_HydraulicsControl` | - |
| `I_Roof` | MONETRoof `FB_RoofControl` | - |
| `I_Dome` | - | `FB_DomeControl` |

### 2.2 How jog is modelled today

- `FB_Axis` has two level inputs `Jog_Forward`/`Jog_Backwards` ("while TRUE", read only). They drive one `MC_Jog` with
  `Mode := MC_JOGMODE_STANDARD_FAST`, gated by `Ready`, `Enable_Positive`/`Enable_Negative` (the limit-switch inputs)
  and `NOT ExtActive` (no jog while the tracking setpoint generator is on). The speed is the NC axis parameter for fast
  manual motion of each axis; there is no slow mode, no velocity argument and no timeout.
- `FB_BaseAxis` holds `bMovePos`/`bMoveNeg`, set through `I_BaseAxis.MovePos`/`MoveNeg`; every axis block passes them
  to `Jog_Forward`/`Jog_Backwards` (HalfBROT azimuth, elevation, derotator, focus; IAG50cm hour angle, declination,
  focus). [fb-axis-command-interface.md](fb-axis-command-interface.md) keeps jog as a level on purpose ("a held
  button").
- Writers today: MONETcommon `FB_MonetPendantControl` writes `MovePos`/`MoveNeg` every scan for the function it owns
  and releases them once when it lets go (MONETcommon#3); the MONETS/MONETN axis VISUs write `bMovePos`/`bMoveNeg`
  directly; IAG50cm's own `FB_PendantControl` goes through its state blocks; HalfBROT's `FB_PendantControl` is not
  instantiated by any checked project.
- Consequence: a level that its writer stops refreshing **stays TRUE** and the axis keeps jogging until a limit. The
  axis does not know who wrote the level or when.

**Finding:** the jog itself needs no new interface method: `MovePos`/`MoveNeg` are the right primitive and the
dead-man belongs in the gateway (section 7). Two small extensions are needed for the decided behaviour:

1. A slow jog speed: `FB_Axis` hard-codes `MC_JOGMODE_STANDARD_FAST`. Proposed: an input `Jog_Slow : BOOL := FALSE`
   (`MC_JOGMODE_STANDARD_SLOW` when TRUE), a property `I_BaseAxis.JogSlow : BOOL` (get/set) implemented once in
   `FB_BaseAxis`, and one extra parameter at the seven `fbAxis(...)` call sites. Default FALSE keeps today's behaviour
   for the pendant and the VISU. Adding a property to `I_BaseAxis` breaks every block that implements the interface
   without extending `FB_BaseAxis` (the test mocks, e.g. IAG50cmTests `FB_FocusMock`), so it is a minor-version change
   of BROTLib with a pin bump in every consumer.
2. Nothing else: no `Jog(direction)` method in the interface. A method would not remove the level semantics (MC_Jog
   is level-driven) and would duplicate the property.

The slow and fast manual velocities are NC parameters of each project and are not in the repositories' source in a
form checked here; they must be read from each project's NC configuration before the timings in section 7.4 are
fixed (open question O7).

### 2.3 Where the Local/Remote switch is read today

| Project | Hardware | Code | Effect today |
|---|---|---|---|
| MONETS, MONETN | key switch at the cabinet | MONETcommon `FB_MonetCabinetControl.inKeyLocal` (`AT %I*`), property `KeyLocal` | `MAIN`: `KeyLocal` TRUE gives `eTelescopeMode := manual` (or `off` without hydraulics), FALSE gives `automatic`. In manual/off `MAIN` calls `TelescopeControl.SuspendAutomatic()` instead of the cyclic call: the automatic telescope control does not run, moves are dropped, a new `Init` is required afterwards (MONETcommon#72, #118). Cabinet Start/Stop buttons (hydraulics) and the brake-clear key act only in manual. The roof close on errors acts only in automatic. |
| IAG50cm | switch at the cabinet | `FB_CabinetControl.bIMode` (`AT %I*`), property `LocalMode`; the instance is `fbCabinet` **inside** `FB_TelescopeControl` | only published as `TELESCOPE.STATUS.LOCAL_MODE`. Nothing is gated: MQTT commands are executed in Local. |
| HalfBROT | - | library, no `MAIN`, no cabinet code | - |

The MONET pendant does **not** read the switch: `FB_MonetPendantControl` has an `eTelescopeMode` input with an empty
`IF ... automatic THEN ; END_IF` and neither `MAIN` wires it. The pendant is active whenever its own enable key is on
and the selector is stable. Its plan (MONETcommon `2026-10-30-pendant-release-on-exit-3.md`) proposes mode gating as a
separate issue. So "the pendant already behaves differently in Local and Remote" is not what the code does today; the
decision that the pendant consumes `I_Cabinet.ControlMode` itself (section 4) is new work.

### 2.4 MQTT command handling

`FB_Comm_MQTT` has one input per interface (`Telescope`, `AltAzTelescope`, `RaDecTelescope`, `Focus`, `Filter`,
`Nasmyth`, `Dome`, `Roof`, `MirrorCovers`); IAG50cm's `MAIN` wires `telescopeControl` to both `Telescope` and
`RaDecTelescope`, MONET's wires `TelescopeControl` to `Telescope` and `AltAzTelescope`. The gateway does not copy that
pattern (2.1, 5.2). `FB_Comm_MQTT_Influx._handleMQTTMessage` runs `_DispatchPass` twice (data
fields, then `track`/`slew`), and every field ends in `_ApplyField(parameter, value, sPayloadRcv)`, one `IF/ELSIF` per
verb that calls the interface method. There is no Local/Remote check. In MONET's manual mode the refusal comes from
the telescope (`init_required`, suspended state machine) and from `_FocusAllowed` (READY_STATE must be 1); covers,
roof and dome verbs are executed.

### 2.5 ADS/RPC

No `TcRpcEnable` attribute exists in BROTLib, MONETcommon, MONETN, MONETS, IAG50cm or HalfBROT (`origin/develop`,
grep). The BROTweb proof of concept lists `TcRpcEnable` under `IGNORED_PLC_ATTRIBUTES` in its ADS extension config.
Whether that only affects attribute metadata or also the mapping of RPC methods is not verified (O6).

## 3. `I_Cabinet`

New interface in BROTLib (`Interfaces/I_Cabinet.TcIO`) with a new enum `E_ControlMode`. Read-only properties; the
interface has no setter, so no software can change the mode.

```
{attribute 'qualified_only'} {attribute 'strict'}
TYPE E_ControlMode : (remote := 0, local := 1); END_TYPE

INTERFACE I_Cabinet
PROPERTY ControlMode      : E_ControlMode  // the physical Local/Remote switch (or the fixed project policy)
PROPERTY SwitchPresent    : BOOL           // FALSE: no physical switch, ControlMode is the fixed project policy
PROPERTY EstopActive      : BOOL           // E-stop pressed or not yet released (same signal as bEstopTriggered)
PROPERTY SafetyError      : BOOL           // TwinSAFE group in error (MONET SafetyHandling.error)
PROPERTY SafetyAckPending : BOOL           // E-stop released, safety acknowledge not run yet (drives in STO)
PROPERTY PendantActive    : BOOL           // a pendant currently holds motion authority (section 4.3)
```

Why these members: E-stop, safety state and pendant state are in no existing interface (2.1), and the gateway, the
comm layer and the HMI header all need them from one place. Lamps, horn, temperature and the cabinet buttons are
cabinet internals and stay out (decided).

`E_TelescopeMode` (`off`/`manual`/`automatic`) is not reused: it mixes the switch with the hydraulics state and is
derived in MONET `MAIN` from `KeyLocal`. MONET keeps deriving it; `ControlMode = local` corresponds to its
`manual`/`off`.

| Implementation | Repo | Source of each member |
|---|---|---|
| `FB_MonetCabinetControl IMPLEMENTS I_Cabinet` | MONETcommon | `ControlMode` from `inKeyLocal`; `SwitchPresent` TRUE; `EstopActive`, `SafetyError` new inputs wired in `MAIN` from `SafetyHandling.estop`/`.error`; `SafetyAckPending` new input (MONET's `FB_MonetSafetyHandling` reset sequence state; signal to be identified); `PendantActive` new input from a new output of `FB_MonetPendantControl` (enable key on and a function owned, or a cover hold-to-run active). |
| `FB_CabinetControl IMPLEMENTS I_Cabinet` | IAG50cm | `ControlMode` from `bIMode` (TRUE = Local per its comment; polarity to be checked on site, O16); `EstopActive`, `SafetyAckPending` from its existing inputs `bEstop`, `bSafetyAckPending`; `SafetyError` new input from `FB_SafetyHandling`; `PendantActive` from IAG's `FB_PendantControl` state (not idle), O5. The instance moves from `FB_TelescopeControl` to `MAIN` (passed to the telescope as `I_Cabinet` or `REFERENCE TO`), so the gateway and the comm can reach it. |
| `FB_FixedCabinet IMPLEMENTS I_Cabinet` | BROTLib | for machines without a switch. `ControlMode` from a constant input `eMode` set in the project's `MAIN` declaration (the per-project policy); `SwitchPresent` FALSE; safety members from inputs (default FALSE); `PendantActive` from an input (default FALSE). The policy value is a project constant, never an ADS-writable variable (it must not become a software ownership switch). |

## 4. Command sources and Local/Remote enforcement

Authority is the physical switch, not a software ownership protocol (decided). Enforcement is in the PLC; BROTweb
hiding a button is a convenience, never the protection.

### 4.1 Classes of commands

| Class | Examples | Gated by the switch |
|---|---|---|
| Motion | `Init`, `Park`, `Home`, `Slew`, `Track`, axis jog/home/enable, focus target, covers open/close, hydraulics on, roof/dome open/close/park/track, filter, Nasmyth, derotator and pointing offsets | yes |
| Stop direction | telescope `Stop`, `dome_stop`, roof stop, jog release, focus stop | no (proposed, O4) |
| Reset | `Reset` of telescope/axes/covers/hydraulics/roof/dome | see table |
| Data | coordinate buffers, weather, `dut1` | no |
| Status | telemetry, the gateway status struct | never gated |

### 4.2 Enforcement table

| Source | Remote | Local | Enforced in |
|---|---|---|---|
| MQTT (pybrotlib: pyobs-brot, BROTgui) | as today | motion verbs refused with one WARN log line each (`MQTT <verb> refused: cabinet switch on Local`); stop-direction verbs and data fields pass; `reset` refused (proposed, O4); telemetry and log keep flowing | `FB_Comm_MQTT_Influx._ApplyField` (4.4) |
| HMI (BROTweb, any browser) | read-only for motion: motion RPCs return `rejected_remote`; `Stop` allowed (proposed, O4); `Reset` allowed for the maintainer role (proposed, O4) | motion RPCs allowed, subject to pendant priority (4.3) and to the checks of the implementation behind the interface | `FB_HmiGateway` (section 5); roles in the TcHMI server (section 9) |
| Pendant (MONET `FB_MonetPendantControl`, IAG50cm `FB_PendantControl`) | not active (new: reads `I_Cabinet.ControlMode` itself) | active; priority over the HMI (proposed, O3) | the pendant block itself |
| VISU (developer tier) | unchanged, not gated | unchanged | none: access to the VISU is the developer's |
| Cabinet buttons (Start/Stop/Reset, brake key) | unchanged | unchanged | `MAIN` |
| Internal automatisms (MQTT watchdog, over-temperature park, roof close on error) | unchanged | unchanged | existing code |

Notes:

- The pendant is not routed through the gateway: it is hardware wired to the PLC and already behaves as a separate
  source. It consumes `ControlMode` directly.
- On MONET, Local is today's manual mode, in which the automatic telescope control is suspended. Telescope-level
  commands (`Init`, `Park`, `Home`, `Slew`, `Track`) sent by the HMI in Local are forwarded and then rejected or
  deferred by `FB_MonetTelescopeControl` (`init_required`; stop/park/Init are kept until the return to automatic). With
  HMI motion allowed only in Local, **the pointing page cannot move a MONET telescope** without a change in
  MONETcommon. This is open question O1; axis-level commands (jog, home, enable) work in manual today.
- On IAG50cm the telescope control runs in both modes, so the gateway's telescope commands work in Local. Refusing
  MQTT motion verbs in Local is new behaviour there (the switch was published but not enforced).

### 4.3 Pendant priority (proposed, not confirmed)

In Local both the HMI and the pendant may command. Proposed rule: the pendant wins.

- While `I_Cabinet.PendantActive` is TRUE, the gateway rejects `Jog`, `HomeAxis`, `EnableAxis`, `MoveFocus` and the
  subsystem motion RPCs with `rejected_pendant`, and releases a running HMI jog in the same cycle (section 7).
- Telescope-level RPCs are rejected too (one motion source at a time).
- `Stop` stays allowed.

IAG50cm's pendant is IAG-specific (`FB_PendantControl`, `I_PendantState`) and is not modelled by the HMI beyond the
`PendantActive` bit.

### 4.4 Hook in the comm layer

- `FB_Comm_MQTT` gets one more optional input `Cabinet : I_Cabinet`, wired in every `MAIN` like the other interfaces.
- `_ApplyField` checks once at the top: `IF Cabinet <> 0 AND_THEN Cabinet.ControlMode = E_ControlMode.local AND_THEN
  F_MqttVerbIsMotion(parameter) THEN` log and `RETURN`. `F_MqttVerbIsMotion` is a pure function with the verb list of
  4.1 (`power`, `park`, `gohome`, `track`, `slew`, `focus`, `cover_open`, `cover_close`, `dome_open`, `dome_close`,
  `dome_park`, `dome_track`, `filter`, `nasmyth`, `derotator`, `derotatoroffset`, `elevationoffset`, `azimuthoffset`,
  `declinationoffset`, `hourangleoffset`, `reset`), unit-testable in BROTLibTests.
- A refused `track`/`slew` still consumes the coordinate buffers (as an incomplete one does), so nothing replays
  after the switch goes back to Remote.
- `Cabinet` unassigned keeps today's behaviour (everything accepted), so the change is backward compatible.
- Telemetry: the gateway publishes nothing over MQTT. MQTT clients see the mode through telemetry; IAG50cm already
  publishes `TELESCOPE.STATUS.LOCAL_MODE`, MONET should publish the same key (MONETcommon work item).

## 5. `FB_HmiGateway`

### 5.1 Role and instantiation

One thin adapter in BROTLib. It takes `I_*` references as inputs, exposes a fixed set of RPC methods and publishes one
flat status struct. It holds no telescope logic: every command ends in an interface call, so all checks of the
implementation (MONETcommon `F_CommandAcceptance`, IAG50cm's `bReady` checks, axis limits, `Enable_Positive`/
`Enable_Negative`) apply unchanged. It never writes a project's command inputs or flags.

Each PLC project declares it at the fixed path **`MAIN.Hmi`** and calls it once per cycle, unconditionally, before the
axis blocks (so a jog level written by the gateway is read by the axis in the same cycle):

```
// MONETS / MONETN MAIN (sketch)
Hmi : FB_HmiGateway;
...
Hmi.aipAxes[1] := AzimuthControl;   Hmi.astAxisInfo[1] := stAzimuthInfo;      // descriptors: constants in MAIN
Hmi.aipAxes[2] := ElevationControl; Hmi.astAxisInfo[2] := stElevationInfo;
Hmi.aipAxes[3] := DerotatorControl; Hmi.astAxisInfo[3] := stDerotatorInfo;
Hmi(ipAltAz := TelescopeControl, ipCabinet := CabinetControl, ipFocus := FocusControl, stFocusInfo := stFocusInfo,
    ipCovers := CoverControl, ipHydraulics := HydraulicsControl, ipBrake := HydraulicsControl, ipRoof := RoofControl);

// IAG50cm MAIN (sketch)
Hmi(ipRaDec := telescopeControl, ipCabinet := cabinetControl, ipFocus := focusControl, stFocusInfo := stFocusInfo,
    ipCovers := coverControl, ipDome := domeControl);   // aipAxes[1..2] := haControl, decControl
```

The telescope is wired once, through its most specific interface. HalfBROT's `FB_HydraulicsControl` implements two
unrelated kinds (`I_Hydraulics`, `I_Brake`; neither extends the other), so it goes to both kind inputs; that is two
subsystems of one block, not the same interface wired twice.

In MONETS/MONETN the call goes after `TelescopeControl(...)`/`SuspendAutomatic()` and before `CoverControl()` and the
axis calls; in IAG50cm before `focusControl(...)`. One BROTweb build then serves every telescope.

### 5.2 Declaration

```
FUNCTION_BLOCK FB_HmiGateway
VAR_INPUT
    ipAltAz        : I_AltAzTelescope;   // at most one of ipAltAz/ipRaDec; the assigned one is the gateway's I_Telescope
    ipRaDec        : I_RaDecTelescope;   //   (implicit conversion) and decides the mount type
    ipCabinet      : I_Cabinet;          // unassigned: every motion RPC is rejected (rejected_no_cabinet)
    aipAxes        : ARRAY[1..GVL_Hmi.MAX_AXES] OF I_Axis;        // mount axes, derotator(s)
    astAxisInfo    : ARRAY[1..GVL_Hmi.MAX_AXES] OF ST_HmiAxisInfo;
    ipFocus        : I_Focus;            // appended as the next axis slot, role focus
    stFocusInfo    : ST_HmiAxisInfo;
    ipCovers       : I_MirrorCovers;
    ipHydraulics   : I_Hydraulics;
    ipBrake        : I_Brake;
    ipRoof         : I_Roof;
    ipDome         : I_Dome;
    ipFilter       : I_Filter;
    ipNasmyth      : I_Nasmyth;
    tJogTimeout    : TIME := T#400MS;    // dead-man timeout, section 7
END_VAR
VAR
    ipTelescope    : I_Telescope;        // each cycle: ipAltAz if assigned, else ipRaDec (both convert to I_Telescope)
END_VAR
VAR_OUTPUT
    stStatus       : ST_HmiStatus;       // the only symbol BROTweb reads
END_VAR
```

`GVL_Hmi.MAX_AXES := 6` (MONET uses 4 including focus, IAG50cm 3). Changing it changes the contract (major).

The interface inputs are pointer-sized values without meaning for a client; they should be hidden from the symbol
list (`{attribute 'hide'}` or equivalent, to verify in the O6 spike).

### 5.3 Capabilities: derived, not maintained

- **Presence:** an unassigned reference (`= 0`) means the subsystem is absent. The gateway sets `bPresent` of each
  subsystem every cycle from `<> 0`. No project sets capability flags by hand.
- **Mount type:** derived from which telescope input is wired, never configured: `altaz` if `ipAltAz <> 0`, `radec`
  if `ipRaDec <> 0`, `none` otherwise. There is no mount-type input or flag; `stStatus.eMountType` only reports the
  derived value. Both assigned is a configuration error (`none`, no telescope commands, blocker `config_error`). It
  selects the pointing page. The axis-level part (jog, home) never needs the specific telescope interface.
- **One input per distinct kind:** axes are `I_Axis`, the focus is `I_Focus`; both reach `I_BaseAxis` by implicit
  conversion, so the gateway uses the base members through the same reference (section 2.1).
- **Axes:** `stStatus.nAxisCount` is the number of assigned slots; each slot has a static descriptor
  `ST_HmiAxisInfo`. The descriptor is configuration (names, units, roles), not runtime capability; for the focus,
  `fMin`/`fMax` are taken from `I_Focus.MinPosition`/`MaxPosition` every cycle instead of the descriptor.
- **Subsystem kinds** are a fixed vocabulary: telescope, axis (incl. focus), covers, hydraulics, brake, roof, dome,
  filter, Nasmyth, cabinet/safety. A new kind is one new interface input, one status sub-struct, one RPC group and one
  BROTweb widget, written once. Pages are not generated from descriptions.

```
TYPE E_HmiAxisRole : (other := 0, azimuth, altitude, derotator, hour_angle, declination, focus); END_TYPE

TYPE ST_HmiAxisInfo : STRUCT
    sName     : STRING(31);      // localization key for the HMI, e.g. 'axis.azimuth'
    eRole     : E_HmiAxisRole;   // native-coordinate role; the pointing page reads the axes by role
    sUnit     : STRING(7);       // 'deg', 'mm', ...
    fMin      : LREAL;           // display/entry range (soft limits of the project), not a safety limit
    fMax      : LREAL;
    bCanJog   : BOOL;
    bCanHome  : BOOL;
    bCanEnable: BOOL;            // the HMI may switch the axis enable (MONET manual mode; see O10)
END_STRUCT END_TYPE
```

### 5.4 RPC methods

Every method carries `{attribute 'TcRpcEnable'}`, takes only elementary values (no interfaces, references or
pointers) and returns `E_HmiResult` immediately. The result reports the **gateway's own gates** (mode, presence,
pendant, argument range, busy). The command is then executed in the gateway's cyclic body (5.5); its outcome
(accepted by the implementation or not) appears in `stStatus.stLastCommand` within one cycle.

```
TYPE E_HmiResult : (
    queued := 0,           // passed the gateway gates, runs in the next cycle; outcome in stLastCommand
    rejected_remote,       // switch on Remote: no HMI motion
    rejected_pendant,      // pendant active (4.3)
    rejected_no_cabinet,   // ipCabinet not assigned
    rejected_absent,       // subsystem/axis slot not present
    rejected_argument,     // NaN, out of range, unknown index or direction
    rejected_busy,         // previous command of this group not yet executed
    rejected_not_allowed,  // capability not offered (descriptor bCanJog/bCanHome/bCanEnable FALSE)
    rejected_jog_owner,    // another client holds the jog (7.2)
    rejected_axis_busy     // axis moved by another source (homing, telescope move)
); END_TYPE
```

| Group | Method | Calls | Mode | Notes |
|---|---|---|---|---|
| Telescope | `Init(bOpenCovers : BOOL)` | `CoverAutoOpen := bOpenCovers; Init()` (as MQTT `power=1/2`) | Local | |
| | `Park()`, `Home()` | `Park()`, `Home()` | Local | |
| | `Slew(fAzimuth, fAltitude : LREAL)` | `Slew(az, alt)` | Local | degrees; alt-az native pointing. Range check as MQTT (`-360..360`, `-90..90`). |
| | `Track(fRightAscension, fDeclination : LREAL)` | `Track(ra, dec)` | Local | degrees, ICRS (as `FB_BaseTelescopeControl`); HMI converts from h:m:s. |
| | `Stop()` | `Stop()`, focus `Stop()`, releases any HMI jog | always (proposed) | |
| | `Reset()` | `Reset()` | always (proposed), role maintainer | IAG50cm: also the safety acknowledge path. |
| Axes | `Jog(nAxis : USINT; nDirection : SINT; bSlow : BOOL; nToken : UDINT)` | `MovePos`/`MoveNeg` (+ `JogSlow`) | Local | section 7; `nDirection` -1/0/+1, 0 = release. |
| | `HomeAxis(nAxis : USINT)` | `HomeAxis := TRUE` (rising edge) | Local | focus on MONET: O10. |
| | `EnableAxis(nAxis : USINT; bEnable : BOOL)` | `Enable := bEnable` | Local (`bEnable` FALSE always) | only if `bCanEnable`. |
| | `ResetAxis(nAxis : USINT)` | `Reset()` | always, role maintainer | |
| | `MoveFocus(fPosition : LREAL)` | `ipFocus.Position := f` after the `MinPosition..MaxPosition` check (as MQTT `focus`) | Local | MONET focus in manual mode: O10. |
| Covers | `CoversOpen()`, `CoversClose()`, `CoversReset()` | `Open()`, `Close()`, `Reset()` | Local (reset: always) | no stop: O9. |
| Hydraulics | `HydraulicsEnable(bEnable : BOOL)`, `HydraulicsReset()` | `Enable := b`, `Reset()` | Local (`bEnable` FALSE always) | `ManualStartSuction`/`ManualStopPump` not exposed (O13). |
| Brake | - | - | - | status only (O12). |
| Roof | `RoofOpen()`, `RoofClose()`, `RoofStop()`, `RoofReset()` | `I_Roof` | open/close Local; stop always | |
| Dome | `DomeOpen()`, `DomeClose()`, `DomePark()`, `DomeStop()`, `DomeReset()` | `I_Dome` | stop always, rest Local | dome tracking stays in the top tier. |
| Filter, Nasmyth | `SetFilter(nPos : USINT)`, `SetNasmyth(nPort : INT)` | `I_Filter`, `I_Nasmyth` | Local | no implementation exists yet. |

Not exposed (top tier): pointing offsets, derotator offset, `Dut1`, weather, dome tracking, `Goto` without tracking.
A native HA/Dec move for equatorial mounts has no interface method (O2).

### 5.5 Execution model (mailbox)

Each RPC writes its request into a one-slot mailbox of its group (telescope, per axis, covers, hydraulics, roof,
dome, filter/Nasmyth) and returns. The cyclic body takes each filled slot once, calls the interface, writes
`stLastCommand` and frees the slot. Reasons:

- It does not depend on the thread in which TwinCAT executes an RPC call (O6): interface methods, `FB_EventLog` and
  the comm's log queue (`I_Comm.PublishLog`, documented as not task-safe) are only touched from the PLC task.
- One command per group per cycle, in a defined order: stop first, then reset, then motion.
- `Stop()` does not wait in a mailbox behind a motion command: it has its own slot and is executed first.

`stLastCommand : ST_HmiCommandRecord` = `nId` (UDINT, incremented per accepted RPC), `eCommand` (E_HmiCommand),
`bAccepted` (the interface method returned TRUE), `eTelescopeReason` (`E_CommandRejectReason` when the implementation
provides one, else `none`), `nCycle` (heartbeat value at execution). BROTweb matches `nId` to show the outcome next
to the button.

The `BOOL` return value of the `I_*` methods is not uniform today: MONETcommon's `Slew`/`Track`/`Home` return FALSE on
rejection, `Stop` and IAG50cm's `Park`/`Home` return nothing meaningful. `bAccepted` is therefore informational; the
status fields (`fReadyState`, axis states) are what the HMI shows as the result (O11).

### 5.6 Status struct

Written once per cycle at the end of the gateway body; all values from the same cycle. BROTweb reads it as one
symbol (one ADS read per subscription tick, so it is consistent).

```
TYPE ST_HmiStatus : STRUCT
    // contract
    nContractMajor   : UINT;          // GVL_Hmi.CONTRACT_MAJOR
    nContractMinor   : UINT;          // GVL_Hmi.CONTRACT_MINOR
    sLibVersion      : STRING(23);    // from Global_Version.stLibVersion_BROTLib
    nHeartbeat       : UDINT;         // +1 per gateway cycle; frozen = PLC/gateway not running
    // cabinet and safety (I_Cabinet)
    eControlMode     : E_ControlMode;
    bSwitchPresent   : BOOL;
    bEstop           : BOOL;
    bSafetyError     : BOOL;
    bSafetyAckPending: BOOL;
    bPendantActive   : BOOL;
    bHmiMotionAllowed: BOOL;          // Local AND NOT pendant AND ipCabinet assigned: enables the motion widgets
    nBlockers        : DWORD;         // bit set of E_HmiBlocker (5.8)
    // telescope
    eMountType       : E_HmiMountType; // none, altaz, radec
    bTelescope       : BOOL;          // presence
    fReadyState      : LREAL;         // I_Telescope.ReadyState (telescope-ready-state.md)
    fAzimuth         : LREAL;         // deg, current, without pointing correction (I_Telescope.Azimuth)
    fAltitude        : LREAL;         // deg, current, same
    fTargetRA        : LREAL;         // deg, commanded target where the implementation provides it (2.1)
    fTargetDec       : LREAL;         // deg
    stLastCommand    : ST_HmiCommandRecord;
    // axes (slots 1..nAxisCount; focus is one of them, role focus)
    nAxisCount       : USINT;
    aAxis            : ARRAY[1..GVL_Hmi.MAX_AXES] OF ST_HmiAxisStatus;
    // subsystems
    stCovers         : ST_HmiCoversStatus;      // bPresent, bOpened, bClosed, bError
    stHydraulics     : ST_HmiHydraulicsStatus;  // bPresent, bEnabled, bPumpRunning, bSuctionRunning, bOilPressureOK, bError
    stBrake          : ST_HmiBrakeStatus;       // bPresent, bOpen
    stRoof           : ST_HmiRoofStatus;        // bPresent, eState : E_RoofState
    stDome           : ST_HmiDomeStatus;        // bPresent, fPosition, eRotState, eShutterState, bParked, bTracking, bError, nErrorID, nCapabilities
    bFilter          : BOOL;
    bNasmyth         : BOOL;
END_STRUCT END_TYPE

TYPE ST_HmiAxisStatus : STRUCT
    bPresent      : BOOL;
    stInfo        : ST_HmiAxisInfo;   // copy of the descriptor (focus: limits from I_Focus)
    fPosition     : LREAL;            // ActualPosition, unit sUnit
    fTarget       : LREAL;            // Position (target) as read through the interface
    bEnabled, bReady, bBusy, bCalibrated, bError : BOOL;
    nErrorID      : UDINT;
    bInPosLimit, bInNegLimit : BOOL;
    bTracking     : BOOL;             // I_Axis.isTracking (FALSE for the focus)
    nJogDirection : SINT;             // the HMI jog the gateway currently drives: -1/0/+1
END_STRUCT END_TYPE
```

Units: angles in degrees everywhere (RA too; BROTweb displays hours), focus and other linear axes in the unit of the
descriptor. Times are not published except as the heartbeat. LST is not available through any interface; the HMI
does not need it because RA/Dec targets are converted in the PLC.

Writes to `stStatus` over ADS are overwritten in the next cycle; BROTweb maps it read-only (section 9).

### 5.7 Contract version

`GVL_Hmi.CONTRACT_MAJOR`/`CONTRACT_MINOR` are constants of the library, published in every status.

| Change | Version |
|---|---|
| new field appended to a struct, new RPC method, new enum value at the end, new blocker bit | minor +1 |
| field removed/renamed/retyped, RPC signature or return semantics changed, `MAX_AXES` changed, `MAIN.Hmi` path changed | major +1 |

TcHMI binds fields by name, so appending is safe. BROTweb declares the major it was built for and the minimum minor it
needs; on a different major or a lower minor it shows a blocking banner and disables every command (BROTweb design).
The library version itself follows [custom-library-versioning.md](custom-library-versioning.md); the contract version
changes only when the HMI-visible surface changes.

### 5.8 Errors and "why not ready"

`nBlockers` is a bit set of `E_HmiBlocker`, recomputed every cycle from the inputs; BROTweb translates every bit with
its own de/en texts and lists the active ones in the header and on the errors page.

| Bit | Name | Source |
|---|---|---|
| 0 | `estop` | `I_Cabinet.EstopActive` |
| 1 | `safety_error` | `I_Cabinet.SafetyError` |
| 2 | `safety_ack_pending` | `I_Cabinet.SafetyAckPending` |
| 3 | `telescope_error` | `ReadyState = -1` |
| 4 | `not_online` | `ReadyState <> 1` (with the READY_STATE value shown) |
| 5 | `axis_error` | any `aAxis[i].bError` |
| 6 | `axis_not_calibrated` | any present axis with `bCanHome` and NOT `Calibrated` |
| 7 | `axis_in_limit` | any `InPosLimit`/`InNegLimit` |
| 8 | `covers_error` | `I_MirrorCovers.Error` |
| 9 | `hydraulics_error` | `I_Hydraulics.Error` or NOT `OilPressureOK` while enabled |
| 10 | `roof_error` | `I_Roof.State = error` |
| 11 | `dome_error` | `I_Dome.Error` |
| 12 | `mode_remote` | `ControlMode = remote` (HMI motion disabled; information, not an error) |
| 13 | `pendant_active` | `I_Cabinet.PendantActive` |
| 14 | `no_cabinet` | `ipCabinet = 0` |
| 15 | `config_error` | both `ipAltAz` and `ipRaDec` assigned, duplicate axis roles, or `nAxisCount` > `MAX_AXES` |

Per-axis `nErrorID` is shown with its number; BROTweb may translate NC error numbers the way BROTLib's
`NCError_TO_STRING` does. The implementation's own reject reason (MONETcommon `eLastRejectReason`) and refusal texts
(MONETcommon `sInitRefusedReason`, IAG50cm `TCScommandRefusedEvent`) are not reachable through `I_Telescope` (O11).

## 6. Relation to existing safety

- The gateway only calls `I_*` methods and properties. It cannot do anything an MQTT client or the pendant cannot do
  through the same interface, and every implementation check applies.
- Axis-level commands (jog, home, enable) bypass the telescope state machine by nature, exactly as the pendant and the
  VISU do today. That is why they are Local only, slow, dead-man protected and subject to pendant priority.
  Horizon/elevation windows of the telescope state machine do not apply to jog (as for the pendant); NC soft limits,
  limit switches and the `Enable_Positive`/`Enable_Negative` gating in `FB_Axis` do.
- E-stop and TwinSAFE are not touched: the safety circuit cuts the drives (STO) regardless of any PLC software. The
  gateway reads the safety state; it has no acknowledge RPC of its own (IAG50cm acknowledges through `Reset()`).
- MONETcommon's automatisms (watchdog park, over-temperature park, roof close on error) are unchanged.

## 7. Jog dead-man

### 7.1 Behaviour

Jog is "move while pressed". The HMI calls `Jog(nAxis, nDirection, bSlow, nToken)` every **150 ms** while the button
is held and once with `nDirection := 0` on release. The gateway writes `MovePos`/`MoveNeg` of that axis every cycle
while the jog is valid and releases them when any of the following holds:

| Release condition | Detected by |
|---|---|
| no `Jog` call for `tJogTimeout` (400 ms) | watchdog `TON` restarted by every call |
| `Jog` with `nDirection = 0` | the call |
| `ControlMode` becomes `remote` | each cycle |
| `PendantActive` becomes TRUE | each cycle |
| `EstopActive` or `SafetyError` | each cycle |
| axis `Error`, or the axis reports the limit in the jog direction | each cycle |
| `Stop()` RPC | the call |
| another axis or direction requested | the call (the old one is released first; a direction reversal needs a release) |

Release writes `MovePos := FALSE; MoveNeg := FALSE` (and `JogSlow := FALSE`) **once** on the owned axis and drops the
ownership, the same pattern as the pendant's release (MONETcommon#3), so a jog the pendant or the VISU starts later is
not overwritten. A timeout release writes one `FB_EventLog` WARN (`HMI jog <axis> released: no keep-alive`).

### 7.2 Ownership

The TcHMI server makes all ADS calls with one AMS address, so the PLC cannot tell clients apart. Each browser session
generates a random `nToken`; the gateway holds one jog at a time and rejects calls with a different token
(`rejected_jog_owner`) until the jog is released. This prevents a second open page (laptop) from keeping or reversing
a jog the panel started.

### 7.3 Timing

- Call period 150 ms: fast enough that a lost call is noticed well within a fraction of a second, slow enough for a
  door-panel browser and the TcHMI server (about 7 RPCs per second for one held button).
- Timeout 400 ms: more than two call periods (300 ms), so one lost or late call does not stop the axis; the 100 ms
  margin covers the browser-server-ADS latency. Rule: `tJogTimeout >= 2 x period + worst observed round trip`; tune
  only after measuring the round trip on the door panel (verification step in the plan).
- Measured in the PLC with a `TON` on task time, never with client time stamps.
- Hidden browser tabs throttle timers to about one call per second or less, so a jog started in a tab that goes to the
  background stops within 400 ms. This is intended.

### 7.4 Overrun

Travel after the last valid call, worst case (release lost): `s = v_jog x (tJogTimeout + t_cycle) + v_jog^2 / (2 a)`,
with `v_jog` and `a` the NC manual parameters of the axis (slow mode by default). Example only, not a project value:
at 0.5 deg/s the timeout part is 0.2 deg. The real `v_jog` per axis is O7; the release by `nDirection := 0` on
pointer-up normally stops after one round trip.

### 7.5 Failure analysis

| Failure | Effect on the PLC | Stops within |
|---|---|---|
| finger lifted | `Jog(..., 0)` | one round trip |
| touch cancelled (gesture, finger slides off, `pointercancel`/`lostpointercapture`) | BROTweb treats it as release; if the release is lost, no more calls | round trip, else 400 ms |
| tab hidden, browser hangs or crashes, kiosk restarts | calls stop | 400 ms |
| network between panel and server, TcHMI server crash/restart, ADS route lost | calls stop | 400 ms |
| two clients | second token rejected | - |
| switch to Remote, pendant takes over, E-stop | release in the gateway cycle (E-stop: STO anyway) | one cycle |
| axis at a limit switch | `FB_Axis` gates the direction | NC |
| gateway body no longer called (MAIN edit, exception) | **the last level stays TRUE** | not covered by the gateway |
| PLC stopped | NC stops the axes | NC |

The last-but-one row is the residual risk of a dead-man that lives outside the axis. Mitigation in this design: the
gateway call in `MAIN` is unconditional and reviewed like the axis calls. A stronger option is a level watchdog in
`FB_BaseAxis` (the level must be rewritten every cycle); the pendant does that, but the MONET VISU writes the level
once per press, so it would break VISU jog. O8.

## 8. ADS and TcRpcEnable constraints

- ADS cannot call methods through an interface reference and cannot browse interface-typed members (they are
  pointers). RPC requires `{attribute 'TcRpcEnable'}` on a method of a concrete FB instance with a fixed symbol path.
  Hence one concrete adapter at `MAIN.Hmi` instead of exposing the `I_*` references.
- RPC parameters and return values: elementary types, enums, `STRING`, structs; no `REFERENCE`, `POINTER` or
  interface. All gateway methods follow that.
- Properties are not ADS-readable without `{attribute 'monitoring' := 'call'}`; the gateway therefore publishes a
  plain output struct instead of properties.
- To verify in a spike before implementation (O6): RPC methods of an FB that lives in a **library** are callable;
  TcHMI (the PoC uses 1.12) maps them as server symbols and passes typed arguments; the thread context of the call
  (the mailbox makes the design independent of it); effect of `TcRpcEnable` in the ADS extension's
  `IGNORED_PLC_ATTRIBUTES`.
- BROTweb writes no PLC variable. Every state change goes through an RPC.

## 9. Roles and access (PLC view)

The PLC cannot see the HMI user. Motion is not role-gated: the Local/Remote gate in the gateway applies to every user
and every client (decided). Roles decide only non-motion rights, checked in the TcHMI server: each RPC symbol is
mapped with the access rights of the user groups, so a crafted request cannot bypass them. Proposed mapping: every
authenticated user may call `Stop` and the motion RPCs (which the PLC then gates); only the maintainer group may call
the `Reset*` RPCs and change HMI configuration. Consequence: in Local, any logged-in user on a laptop has the same
motion rights as the door panel (O15).

## 10. Migration of the BROTweb proof of concept

The PoC maps 26 symbols under `MAIN.TelescopeControl.*` (MONET naming), among them direct writes of `bInit`, `bPark`,
`bSlew`, `bTrack`. Since MONETcommon#24 step 5 these inputs are edge-triggered and never cleared by the telescope
(see MONETcommon `specs/plans/2026-11-02-step-4c-client-check.md`): the first write starts the command, every later
write of TRUE does nothing. IAG50cm names its instance `telescopeControl` and the paths do not exist there at all.

| PoC symbol(s) | Replacement |
|---|---|
| `bInit` | `Init(bOpenCovers)` |
| `bPark` | `Park()` |
| `bSlew` + `fAzimuth`/`fElevation` writes | `Slew(fAzimuth, fAltitude)` |
| `bTrack` + `fRightAscension`/`fDeclination` writes | `Track(fRightAscension, fDeclination)` |
| `fAzimuthCurrent`, `fElevationCurrent` | `stStatus.fAzimuth`, `stStatus.fAltitude` |
| `fRightAscension`, `fDeclination` (read) | `stStatus.fTargetRA`, `stStatus.fTargetDec` |
| `fAzimuthOffset`, `fElevationOffset` | dropped (top tier) |
| `*Calc`, `*Pointing`, `fHourAngleCalc` | dropped; native coordinates from `aAxis[]` by role |
| `fJD`, `fLST`, `sDateTime`, `fbTime.sDateTime` | dropped; a clock field can be appended later (minor change) if a page needs it |
| `sState` | `fReadyState`, `nBlockers` |

All 26 mappings are removed from the TcHMI server configuration in the rewrite; BROTweb then maps only
`MAIN.Hmi.stStatus` and the `MAIN.Hmi` RPC methods.

## 11. Decided

1. The middle tier commands over ADS (RPC methods + one status symbol), not MQTT: maintenance must work with the broker
   down; arguments and return values are typed; clients never set request flags.
2. The BROTLib `I_*` interfaces are the semantic contract. A thin adapter `FB_HmiGateway` makes them reachable over ADS;
   no new parallel contract.
3. The gateway lives at the fixed path `MAIN.Hmi` in every project; BROTweb binds only to it.
4. Capabilities are derived: unassigned reference = absent; fixed vocabulary of subsystem kinds, one widget each; axes
   and focus as slots with descriptors; mount type selects the pointing page. No page generation.
5. New interface `I_Cabinet` with `ControlMode` from the physical switch; implemented by MONETcommon
   `FB_MonetCabinetControl`, IAG50cm `FB_CabinetControl` and a fixed BROTLib implementation whose policy is a project
   constant.
6. Authority is the physical switch. Remote: MQTT may move, HMI is read-only for motion. Local: HMI and pendant may
   move, MQTT motion verbs are refused, status keeps flowing. Enforced in the PLC (gateway + comm), never only in the
   HMI. Login roles decide only non-motion rights.
7. The pendant reads `I_Cabinet.ControlMode` itself and is not routed through the gateway.
8. Jog is a PLC-enforced dead-man: keep-alive calls about every 150 ms, PLC timeout about 400 ms, slow fixed speed (two
   selectable at most), Local only.
9. The gateway has one input per distinct subsystem kind; the telescope is wired once through `ipAltAz` or `ipRaDec`
   (implicit conversion to `I_Telescope`, mount type derived from which is wired). `__System.IQueryInterface` is not
   adopted (2.1).
10. BROTLib and BROTweb are public: no hostnames, AMS NetIDs, IP addresses, credentials, licence or deployment details
   in their docs or default configs.

## 12. Open questions

| # | Question | Notes |
|---|---|---|
| O1 | How does the pointing page move a **MONET** telescope? Local suspends the automatic control (no Slew/Track/Park), Remote makes the HMI read-only. | Options: (a) a MONETcommon "local automatic" mode in which the telescope control runs while the key is on Local and only HMI commands are accepted; (b) pointing page usable only where the implementation runs in Local (IAG50cm); (c) allow HMI telescope commands in Remote when the MQTT source is idle (contradicts the decided authority model). Needs Tim. |
| O2 | Native HA/Dec move for equatorial mounts | `I_RaDecTelescope` has none; `Slew` takes Az/Alt on IAG50cm too. Options: add `SlewHaDec(ha, dec)` to `I_RaDecTelescope` (IAG50cm implements it with `FB_RaDecCoordinates`); or the pointing page offers RA/Dec only. |
| O3 | Pendant priority over the HMI in Local | proposed in 4.3, not confirmed by Tim. |
| O4 | Stop and reset across modes | proposed: HMI `Stop` always; HMI `Reset` always (maintainer); MQTT `stop` passes in Local, MQTT `reset` refused in Local. MONET defers a telescope `Stop()` in manual by design (#118), so an HMI stop in Local acts through the jog release and the focus stop only. |
| O5 | Source of `PendantActive` | MONET: new output of `FB_MonetPendantControl`; IAG50cm: state of `FB_PendantControl` (`I_PendantState`) not idle; or a separate interface instead of an `I_Cabinet` member. |
| O6 | ADS/TcHMI spike | RPC in a library FB, TcHMI 1.12 mapping of RPC methods, call thread, `IGNORED_PLC_ATTRIBUTES`, hiding interface inputs. |
| O7 | Jog speeds | NC slow/fast manual velocities per axis (MONETS, MONETN, IAG50cm); is the slow mode slow enough for a touch screen; `Jog_Slow` extension of `FB_Axis` (2.2). |
| O8 | Gateway not called leaves the jog level TRUE | accept with review, or add a level watchdog in `FB_BaseAxis` and change the MONET VISU jog to refresh the level. |
| O9 | Covers stop | `I_MirrorCovers` has no `Stop()`; adding it touches HalfBROT and IAG50cm `FB_CoverControl` and the mocks. |
| O10 | Focus and axis enable in MONET manual mode | MONET focus homing is `bManualHome` (not in `I_Focus`); behaviour of `Focus.Position` writes in manual; whether the HMI may switch axis enables (MONET elevation depends on the brake key). |
| O11 | Telescope status beyond `ReadyState` | no error/busy/parked/reject reason/current RA-Dec in `I_Telescope`; proposal: an optional `I_TelescopeStatus` (separate input, implemented incrementally) with `Error`, `ErrorID`, `Busy`, `IsParked`, `LastRejectReason`, current RA/Dec. BROTLib's `E_CommandRejectReason` lacks MONETcommon's `init_required`. Uniform method return values. |
| O12 | Brake from the HMI | MONET `MAIN` overwrites `bOpenBrake` every scan from the cabinet brake key in manual; proposed: status only. |
| O13 | Hydraulics manual suction/pump | level properties with unclear ownership; not exposed in the first version. |
| O14 | Safety diagnostics | EL1904/EL2904 connection states exist only inside `FB_MonetSafetyHandling`/`FB_SafetyHandling`; an optional `I_SafetyDiagnostics` would be needed for the read-only safety page. |
| O15 | Client restriction | the PLC cannot tell the door panel from a laptop; accept (decided authority model) or restrict motion RPCs to the panel's TcHMI user group. |
| O16 | IAG50cm switch polarity | `bIMode` TRUE = Local per the comment; check on site. |
