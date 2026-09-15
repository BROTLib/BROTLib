# BROTLib

BROTLib (**B**asic **R**obotic **O**bservatory **T**elescope Library, also known
as the "Beckhoff RObotic Telescope Library") is the core, reusable TwinCAT 3
library for the robotic observatory telescopes developed at the
Institut für Astrophysik Göttingen (Georg-August-Universität Göttingen).

It is written entirely in IEC 61131-3 Structured Text for the **Beckhoff
TwinCAT 3** platform and defines the shared abstractions — telescope control
state machines, axis and observatory-subsystem interfaces, coordinate types,
pointing models, MQTT/InfluxDB communication and event logging — on top of
which all other BROT projects are built:

```
                    ┌──────────┐
                    │ AstroBROT│  (astronomical calculations)
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ BROTLib  │  (core telescope control library)
                    └────┬─────┘
                         │
         ┌───────────────┼────────────────────────┐
         │               │                        │
    ┌────▼───┐    ┌──────▼──────┐          ┌─────▼────┐
    │HalfBROT│    │  MONETRoof  │          │ IAG50cm  │
    └────┬───┘    └──────┬──────┘          └──────────┘
         │               │
         │        ┌──────▼──────┐
         │        │ MONETcommon │
         │        └──────┬──────┘
         │               │
         └───────┬───────┘
                 │
        ┌────────┴────────┐
        │                 │
   ┌────▼──┐        ┌────▼──┐
   │MONETN │        │MONETS │
   └───────┘        └───────┘
```

---

## Repository layout

```
BROTLib/
├── BROTLib.sln                  # TwinCAT solution
├── BROTLib/
│   ├── BROTLib.tsproj           # TwinCAT system project
│   ├── BROTLib/
│   │   ├── BROTLib.plcproj      # PLC library project
│   │   ├── PlcTask.TcTTO        # PLC task
│   │   ├── DUTs/                # Enumerations and structures
│   │   │   ├── E_TCSCommand.TcDUT
│   │   │   ├── E_TCSErrors.TcDUT
│   │   │   ├── E_TelescopeMode.TcDUT
│   │   │   ├── E_RoofState.TcDUT
│   │   │   ├── E_DomeRotationState.TcDUT
│   │   │   ├── E_Horn.TcDUT, E_Blink.TcDUT
│   │   │   ├── ST_AltAzCoordinate.TcDUT, ST_RaDecCoordinate.TcDUT
│   │   │   ├── ST_TelescopeConfig.TcDUT
│   │   │   └── ST_InfoData*.TcDUT
│   │   ├── GVLs/GVL_Math.TcGVL  # Mathematical constants
│   │   ├── Interfaces/          # I_Telescope, I_Axis, I_BaseAxis, I_Dome,
│   │   │                        # I_Roof, I_Focus, I_Filter, I_Brake,
│   │   │                        # I_MirrorCovers, I_Nasmyth, I_Hydraulics,
│   │   │                        # I_AltAzTelescope, I_RaDecTelescope
│   │   └── POUs/                # Function blocks and functions
│   │       ├── MAIN.TcPOU       # Library placeholder
│   │       ├── Comm/            # FB_Comm_MQTT, FB_Comm_MQTT_Influx, I_Comm
│   │       ├── Debug/           # FB_InfoConnection, FB_InfoEStop, FB_InfoGroup
│   │       ├── Pointing/        # FB_PointingModelForward, FB_PointingModelInversion
│   │       ├── Tracking/        # F_Azimuthvelocity, F_Elevationvelocity,
│   │       │                    # F_DerotatorPosition2, F_Derotatorvelocity
│   │       ├── Telescope/       # FB_BaseTelescopeControl,
│   │       │                    # FB_AltAzTelescopeControl,
│   │       │                    # FB_RaDecTelescopeControl
│   │       └── ...              # FB_AstroClock, FB_Axis2, FB_BaseAxis,
│   │                            # FB_EventLog, FB_InfluxMessage, FB_Horn,
│   │                            # FB_BLINK, FB_ButtonEnable, FB_LightTimer,
│   │                            # FB_TONTP, F_YREAL, NCError_TO_STRING
│   └── _Libraries/              # Resolved library references
├── specs/                       # Specification documents (ADR / design / plans)
│   ├── adrs/index.md            # Architecture decision records
│   ├── design/index.md          # Design docs (e.g. TwinCAT ScopeView .svdx format)
│   ├── plans/index.md           # Implementation plans
│   └── steering/index.md        # Contributor guidance
├── STRUCTURE.md                 # Overview of the whole BROT repository ecosystem
├── UNIFICATION.md               # BROTLib / IAG50cm unification plan
├── MONET_Unification.md         # MONETcommon / MONETN / MONETS unification plan
├── FB_Axis.md                   # FB_Axis / FB_BaseAxis unification design
├── TRACKING.md                  # Tracking/pointing notes
└── README.md
```

---

## Library architecture

BROTLib provides the reusable core for both **Alt-Az** and **equatorial
(HA/Dec)** mount types. The library is organised into four layers:

1. **Interfaces** — abstract contracts for every observatory subsystem, so the
   application code (and HMI) depends on interfaces, not on concrete
   implementations:

   | Interface | Subsystem |
   |---|---|
   | `I_Telescope` | Generic telescope (command interface, coordinate handling, telemetry) |
   | `I_AltAzTelescope` / `I_RaDecTelescope` | Mount-type-specific extensions |
   | `I_Axis` / `I_BaseAxis` | Motion axes (position, velocity, tracking, homing) |
   | `I_Dome` | Dome rotation and shutter |
   | `I_Roof` | Roof (dome enclosure) open/close control |
   | `I_Focus`, `I_Filter`, `I_Brake` | Instrument subsystems |
   | `I_MirrorCovers`, `I_Nasmyth`, `I_Hydraulics` | Telescope infrastructure |
   | `I_Comm` | Telemetry/log publishing (`Publish`, `PublishLog`) |

2. **Telescope control** — the command/state layer:

   - `FB_BaseTelescopeControl` — abstract base for all telescope types: TCS
     command inputs, coordinate handling, MQTT telemetry, auto-park and
     command timers, the sidereal-rate constant.
   - `FB_AltAzTelescopeControl` — Alt-Az extension: pointing model, derotator,
     EOFF/AN/AE/TF error terms, `FB_EQ2HOR`/`FB_HOR2EQ` transforms.
   - `FB_RaDecTelescopeControl` — equatorial (HA/Dec) mount extension.

   **Command model** — telescope behaviour is expressed through the command
   enumeration `E_TCSCommand` (`no_command`, `gohome`, `park`, `track`, `goto`,
   `stop`, `slew`, `poweron`) and a **command-priority dispatcher** shared by
   all BROT applications: `power > stop > park > gohome > goto > slew > track >
   no_command`. Commands are executed as stage-based sub-state machines
   (`CASE nStage` in the concrete implementations, e.g. MONETcommon's
   `FB_MonetTelescopeControl`), with `fReadyState` (0 shutdown … 1 ready, −1
   error), `nMotionState` (0 stopped / 1 moving / 8 tracking) and per-command
   timeouts reported as telemetry. (An earlier 8-state machine described in
   `STRUCTURE.md` was removed in 2026; no `E_TelescopeState` enum exists in the
   current code.)

3. **Axes** — `FB_Axis2` / `FB_BaseAxis` implement the axis abstraction
   (position/velocity control, homing, limits, error checks) on top of the
   TwinCAT NC axes. An axis-unification effort (`FB_Axis`, see
   [FB_Axis.md](./FB_Axis.md) and [UNIFICATION.md](./UNIFICATION.md)) merges
   `FB_Axis2` with the IAG50cm `FB_Axis3` into a single block.

4. **Infrastructure** — communication, logging, math and utilities.

---

## Key components

### Telescope control

- **`FB_BaseTelescopeControl`** — abstract base class for all telescope types.
  Provides the command interface (`E_TCSCommand`: e.g. `GoHome`, `GoTo`,
  `Track`, `Slew`, `Park`, `Stop`, `PowerOn`), the state machine, coordinate
  handling and MQTT telemetry publishing.
- **`FB_AltAzTelescopeControl`** — Alt-Az implementation with
  `FB_PointingModelForward`/`FB_PointingModelInversion` (Tpoint-style,
  8-term), derotator position/velocity calculation and the EOFF/AN/AE/TF
  pointing-error terms.
- **`FB_RaDecTelescopeControl`** — equatorial implementation for HA/Dec mounts
  (used by IAG50cm).

### Axes and pointing

- **`FB_BaseAxis` / `FB_Axis2`** — axis abstraction over a TwinCAT NC axis:
  position and velocity control, `isTracking` handling, homing/referencing,
  limit handling and error checking. `FB_AxisControl`-style blocks in the
  hardware libraries (`HalfBROT`, `MONETcommon`) extend these.
- **`FB_PointingModelForward`** — Tpoint-style parametric pointing model
  (8 terms: AOFF, BNP, AN_A, AE_A, NPAE, EOFF, AN_E, AE_E, TF), producing
  Az/El offsets and tracking velocities.
- **`FB_PointingModelInversion`** — inverts the pointing model (11 fixed
  iterations) to compute corrected target coordinates.
- **Tracking functions** — `F_Azimuthvelocity`, `F_Elevationvelocity`,
  `F_DerotatorPosition2`, `F_Derotatorvelocity` compute the velocity setpoints
  for sidereal tracking on an Alt-Az mount and the field derotator position.

### Communication and telemetry

- **`I_Comm` / `FB_Comm_MQTT`** — abstract MQTT client built on
  `Tc3_IotCommunicator`.
- **`FB_Comm_MQTT_Influx`** — concrete MQTT + InfluxDB telemetry publisher.
  Publishes measurements in Influx line protocol; used by every BROT
  application (topics such as `MONETN/Telemetry`, `50cm/Telemetry`, ...).
- **`FB_InfluxMessage`** — parses single Influx line-protocol messages
  (`measurement,tags parameter=value`) received on the command topic.
- **`F_EscapeInfluxString`** / **`F_IsNumericValue`** — Influx string escaping
  and strict numeric validation (incl. scientific notation).
- **`FB_EventLog`** — structured event/error logging with severity and message
  text, published to the log topic.

The incoming command layer parses `command` measurements and dispatches the
telescope/auxiliary commands (`power`, `park`, `gohome`, `track`, `slew`,
`stop`, `reset`, `nasmyth`, `focus`, `cover_open`/`cover_close`,
`dome_open`/`dome_close`/`dome_stop`/`dome_park`/`dome_track`/`dome_reset`,
`filter`, `derotator`, the coordinate buffers `rightascension`/`declination`/
`elevation`/`azimuth`, and the offset commands `elevationoffset`,
`azimuthoffset`, `derotatoroffset`, `declinationoffset`, `hourangleoffset`) to
the interface references (`Telescope`, `AltAzTelescope`, `RaDecTelescope`,
`Focus`, `Filter`, `Nasmyth`, `Dome`, `Roof`, `MirrorCovers`). Telemetry is
published at 1 s while slewing/tracking and 5 s when idle.

### Utilities and timing

- **`FB_AstroClock`** — sub-millisecond time synchronisation for the PLC
  (astronomical timing accuracy).
- **`FB_BLINK` / `E_Blink`** — lamp/blink pattern generation for HMI lamps.
- **`FB_ButtonEnable`** — button debounce/enable logic for panels.
- **`FB_Horn` / `E_Horn`** — warning-horn control.
- **`FB_LightTimer`**, **`FB_TONTP`** — timer blocks.
- **`F_YREAL`** — REAL formatting helper; **`NCError_TO_STRING`** — maps TwinCAT
  NC error codes to readable text; **`GVL_Math`** — mathematical constants.

---

## Coordinate and DUT types

- `ST_RaDecCoordinate` — right ascension / declination (ICRS) coordinate pair.
- `ST_AltAzCoordinate` — altitude / azimuth coordinate pair.
- `ST_TelescopeConfig` — telescope configuration structure shared with IAG50cm
  (identical copy in both projects, see [UNIFICATION.md](./UNIFICATION.md)).
- `ST_InfoDataConnection` / `ST_InfoDataFB` / `ST_InfoDataGroup` — debug info
  data structures used by the `FB_Info*` debug blocks.
- `E_TCSCommand`, `E_TCSErrors`, `E_TelescopeMode` — command, error and mode
  enumerations of the telescope control layer.
- `E_RoofState` — roof states (`closed`, `opened`, `opening`, `closing`,
  `stopped`, `error`, `unknown`) used by `I_Roof` implementations such as
  MONETRoof.
- `E_DomeRotationState` — dome rotation states for `I_Dome`.

---

## Versioning and development process

- Versioned with git tags (`v0.2.0` … `v0.4.1`); the library version is bumped
  per release (e.g. *0.4.1* adds scientific-notation support in
  `F_IsNumericValue`).
- `specs/` holds lightweight specification documents: ADRs (decision records),
  design docs (e.g. the reverse-engineered TwinCAT ScopeView `.svdx` format
  used by the roof analysis scripts), plans, and steering guidance.
- `UNIFICATION.md` / `FB_Axis.md` document the ongoing unification of
  duplicated code between BROTLib and IAG50cm; `MONET_Unification.md`
  documents the (related, separate) unification of MONETcommon / MONETN /
  MONETS code. Both unification plans are documented but not yet implemented.
- A CI build pipeline for TwinCAT (`build.ps1` / `build.yml`, branch
  `feature/ci-twincat-build`) validates the library compiles on a clean TwinCAT
  installation (the untracked `test_errors.TcPOU` is a deliberately broken POU
  used to exercise that build).

---

## Dependencies

- **AstroBROT** — astronomical calculations library (coordinate
  transformations, sidereal time, precession, nutation, refraction);
  referenced as `AstroBROT, * (BROT)`.
- Beckhoff system libraries: `Tc2_Standard`, `Tc2_System`, `Tc2_Utilities`,
  `Tc2_Math`, `Tc2_MC2` + `Tc2_NC` (motion control / NC axes),
  `Tc3_IotBase`, `Tc3_IotCommunicator` (MQTT, TF6701), `Tc3_Module`.

The library is published under the company `BROT` and referenced by consumers
with the namespace `BROTLib` (resolution `BROTLib, * (BROT)`). BROTLib is
consumed by **HalfBROT**, **MONETRoof**, **MONETcommon**, **IAG50cm**,
**MONETN** and **MONETS**.

---

## Building and deployment

The library is built with TwinCAT 3.1 in TwinCAT XAE (PLC task 10 ms,
priority 20; the system project is 3.1.4024.66, the PLC project is authored
with 3.1.4026.x — the project was created on Build 4024 and is edited on
4026). It is distributed as a compiled TwinCAT library (library version 0.4.1)
and referenced from the application projects' `_Libraries/` folders.
Application projects targeting TwinCAT RT (x86/x64), TwinCAT CE7 (ARMv7) and
TwinCAT OS (ARM/x64) all build on this library.
