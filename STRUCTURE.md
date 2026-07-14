# BROTlib - Project Structure

BROTlib (**B**asic **R**obotic **O**bservatory **T**elescope Library) is a modular telescope control system built entirely on **IEC 61131-3 Structured Text** for the **Beckhoff TwinCAT 3** platform. It provides reusable PLC libraries and complete telescope application projects for robotic observatory control.

## Repository Overview

```
brotlib/
├── AstroBROT/       # Astronomical calculations library
├── BROTLib/         # Core telescope control library
├── HalfBROT/        # Halfmann telescope hardware abstraction library
├── IAG50cm/         # IAG 50cm equatorial telescope (Goettingen)
├── MONETcommon/     # Common MONET telescope control library
├── MONETN/          # MONET/N 1.2m telescope (McDonald Observatory, Texas)
├── MONETRoof/       # MONET observatory roof control library
└── MONETS/          # MONET/S 1.2m telescope (Sutherland, South Africa)
```

## Library Projects

### AstroBROT
**Purpose:** Real-time astronomical calculations for PLC hardware.
**Language:** IEC 61131-3 Structured Text (TwinCAT 3)
**Version:** 0.3.0

Provides the mathematical backbone for coordinate transformations and astronomical corrections. Algorithms are ported from IDLAstro (NASA/GSFC), NOVAS F3.1 (USNO), SOFA (IAU), and Meeus "Astronomical Algorithms".

| Function Block | Description |
|---|---|
| `FB_EQ2HOR` | Equatorial (RA/Dec J2000) to Horizontal (Alt/Az) conversion |
| `FB_HOR2EQ` | Horizontal to Equatorial conversion |
| `FB_RADEC2HADEC` | ICRS RA/Dec to apparent Hour Angle/Declination |
| `FB_HADEC2RADEC` | Apparent HA/Dec back to ICRS RA/Dec |
| `FB_PRECESS` | Precession between epochs (Capitaine et al. 2003) |
| `FB_NUTATE` | IAU 1980 nutation theory (63 terms) |
| `FB_IAU2000B` | IAU 2000B nutation model (~1 mas accuracy) |
| `FB_SUNPOS` | Apparent solar position from Julian Date |
| `FB_HADEC2ALTAZ` | HA/Dec to Alt/Az via spherical trigonometry |
| `FB_ALTAZ2HADEC` | Alt/Az to HA/Dec |
| `FB_CO_NUTATE` | RA/Dec correction due to nutation |
| `FB_CO_ABERRATION` | RA/Dec correction due to annual aberration |
| `FB_CO_REFRACT` | Atmospheric refraction correction |

| Function | Description |
|---|---|
| `JD2LST` | Julian Date to Local Sidereal Time |
| `CT2LST` | Civil Time to Local Mean Sidereal Time |
| `DateTime2JD` | TwinCAT TIMESTRUCT to Julian Date |
| `ATAN2` | Four-quadrant arctangent |
| `POLY` | Polynomial evaluation (4 coefficients) |
| `TEN` | DMS to decimal degrees |
| `CO_REFRACT_FORWARD` | Forward atmospheric refraction model |

**Dependencies:** Tc2_Standard, Tc2_Math, Tc2_System, Tc2_Utilities, Tc3_Module, TcUnit (v1.2.0)

---

### BROTLib
**Purpose:** Core reusable library for robotic telescope mount control.
**Language:** IEC 61131-3 Structured Text (TwinCAT 3)
**Version:** 0.3.0

The central library defining telescope control abstractions, interfaces, coordinate types, state machines, pointing models, MQTT communication, and observatory subsystem interfaces. Supports both Alt-Az and RaDec mount types.

**Telescope Control:**
- `FB_BaseTelescopeControl` -- Abstract base for all telescope types (command interface, coordinate calculation, MQTT telemetry)
- `FB_AltAzTelescopeControl` -- Alt-Az specific extension (pointing model, derotator, EOFF/AN/AE/TF error terms)
- `FB_RaDecTelescopeControl` -- Equatorial mount extension

**State Machine (8 states):** Idle, Initializing, Parked, Parking, Slewing, Tracking, Referencing, Error

**Key Interfaces (12):**
`I_Telescope`, `I_AltAzTelescope`, `I_RaDecTelescope`, `I_Axis`, `I_BaseAxis`, `I_Dome`, `I_Roof`, `I_Focus`, `I_Filter`, `I_Brake`, `I_MirrorCovers`, `I_Nasmyth`, `I_Hydraulics`

**Communication:**
- `FB_Comm_MQTT` -- Abstract MQTT client (Tc3_IotCommunicator)
- `FB_Comm_MQTT_Influx` -- Concrete MQTT+InfluxDB telemetry publisher

**Other:** FB_AstroClock (sub-ms time sync), FB_PointingModelForward/Inversion (8-term Tpoint-style model), FB_EventLog, FB_InfluxMessage, tracking velocity functions.

**Dependencies:** AstroBROT, Tc2_MC2, Tc2_NC, Tc3_IotBase, Tc3_IotCommunicator, Tc3_Module

---

### HalfBROT
**Purpose:** Halfmann telescope hardware abstraction layer.
**Language:** IEC 61131-3 Structured Text (TwinCAT 3)

Defines the Halfmann-specific function blocks for axis control, hydraulics, covers, focus, and manual pendant operation. Includes TwinSAFE (FSoE over EtherCAT) safety configuration and HMI visualizations.

| Function Block | Description |
|---|---|
| `FB_AxisControl` | Abstract axis control (extends FB_BaseAxis, implements I_Axis) |
| `FB_AzimuthControl` | Azimuth axis with brake interlock, homing, limit switches, persistent position |
| `FB_ElevationControl` | Elevation axis with mirror cover/brake coordination, altitude warnings |
| `FB_DerotatorControl` | Field de-rotation axis with auto-home |
| `FB_FocusControl` | Focus motor with electromechanical brake, position memory |
| `FB_HydraulicsControl` | Hydraulic pump/brake system, oil monitoring, watchdog timers |
| `FB_CoverControl` | 3-mirror cover sequenced open/close |
| `FB_PendantControl` | BCD-selector manual hand pendant |
| `FB_TelescopeAuxiliary` | Mirror temperature sensors |

**PLC Task:** 10 ms cycle time
**Dependencies:** BROTLib, AstroBROT, Tc2_MC2, Tc2_MC2_Drive, Tc3_Module

---

### MONETcommon
**Purpose:** Common control library for MONET-class telescopes.
**Language:** IEC 61131-3 Structured Text (TwinCAT 3)

Shared function blocks for MONET telescope operations. Extends BROTLib/HalfBROT with MONET-specific control logic.

| Function Block | Description |
|---|---|
| `FB_MonetTelescopeControl` | Full Alt-Az telescope lifecycle (extends FB_AltAzTelescopeControl) |
| `FB_MonetSafetyHandling` | TwinSAFE E-Stop, STO reset for all 3 axes |
| `FB_MonetHydraulicsControl` | Hydraulic pump, brake, oil monitoring |
| `FB_MonetPendantControl` | Manual pendant (BCD selector + buttons) |
| `FB_MonetCabinetControl` | Physical I/O (buttons, switches, lamps, temperature) |
| `FB_MonetFocusControl` | Focus motor (Faulhaber 43:1 gear) |
| `FB_MonetPowerMonitoring` | 3-phase power quality monitoring |

**Dependencies:** BROTLib, AstroBROT, HalfBROT, Tc2_MC2, Tc2_Standard, Tc2_System, Tc2_Utilities

---

### MONETRoof
**Purpose:** Observatory roof (dome enclosure) control.
**Language:** IEC 61131-3 Structured Text (TwinCAT 3)

Controls two independent roof halves, each driven by 2 motors with position tracking via hall-effect sensors.

| Function Block | Description |
|---|---|
| `FB_RoofControl` | Top-level controller (2 roof sections, I_Roof interface, MQTT telemetry) |
| `FB_Roof` | Single roof half (state machine: closed/opened/opening/closing/stopped/error) |
| `FB_RoofMotor` | Single motor drive (position counting, limit switches, speed/direction output) |
| `FB_Ramp` | Linear velocity ramp |

**Safety:** TwinSAFE E-Stop with EL1904/EL2904 terminals
**Dependencies:** BROTLib, Tc2_Standard, Tc2_System, Tc3_Module, VisuSymbols

---

## Application Projects

### IAG50cm
**Purpose:** Full control system for the "Emmy Noether" 50cm equatorial telescope at IAG Goettingen.
**Mount Type:** HA-DEC (equatorial)
**Diameter:** 0.5m

| Location | Value |
|---|---|
| Longitude | 9.9452433 |
| Latitude | 51.5592378 |
| Altitude | 100m |
| City | Goettingen, Germany |

**Key Modules:**
- `FB_TelescopeControl` -- State machine (PowerOn/GoHome/GoTo/Track/Slew/Park/Stop)
- `FB_HourAngleControl` / `FB_DeclinationControl` -- Axis motor control with latch-home calibration
- `FB_FocusControl` -- Focus axis
- `FB_DomeControl` -- Dome rotation/shutter via serial communication
- `FB_CoverControl` -- Mirror cover relay control
- `FB_PendantControl` -- Manual hand controller
- `FB_CabinetControl` -- Hardware cabinet monitoring (24V/48V, fuses, contactors)
- `FB_SafetyHandling` -- TwinSAFE startup (ErrorAck, Restart)
- `FB_PointingModelForward/Inversion` -- 12-term parametric pointing model
- `FB_LatchHome` -- Custom encoder reference marker homing

**Pointing Model:** 12-term model calibrated from 136 points (2026-01-21), RMS ~17.7"/13.5"
**Sidereal Rate:** 360/86164.099 deg/s (~15.041 arcsec/s)
**Communication:** MQTT (topics `50cm/Telescope/SET`, `50cm/Telemetry`, `50cm/Log`)
**Auto-park:** 12-hour timeout

**Hardware:**
- TwinSAFE: EL1918 (safe input), ELM7212/ELM7221 (analog I/O with SAFEMOTION FSoE)
- Serial: RS-232/485 for dome communication
- EtherCAT bus

**Dependencies:** BROTLib, AstroBROT, Tc2_MC2, Tc2_MC2_Drive, Tc2_SerialCom, Tc3_IotCommunicator

---

### MONETN
**Purpose:** Control system for MONET/N (Monitor of Network of Telescope North), 1.2m Alt-Az telescope.
**Mount Type:** ALT-AZ with field derotator
**Diameter:** 1.2m
**Location:** McDonald Observatory, Texas (lon -104.0217, lat 30.6714, alt 2000m)

**Key Subsystems:**
- Telescope mount (Az/El/Derotator) via AX5125/AX5206 servo drives
- Mirror covers (3 covers, sequenced)
- Focus (Faulhaber 3557K024CR + 43:1 gear)
- Hydraulics (oil pump, suction pump, brake)
- Power monitoring (3-phase)
- Safety (TwinSAFE: EL1904/EL2904/AX5805)
- Cabinet control (buttons, switches, lamps, temperature)
- Pendant (BCD selector manual control)
- 11 HMI visualization screens

**MQTT:** Broker at 169.254.146.10:1883 (topics `MONETN/Telescope/SET`, `MONETN/Telemetry`, `MONETN/Log`)
**Auto-park:** 12-hour timeout

**Hardware:**
- PLC: Beckhoff CX-7A03E9 (ARM)
- Drives: AX5125 (Az/El), AX5206 (Derotator)
- Motors: TMA 0530 (Az), TMA 0360 (El)
- Safety: AX5805 (STO), EL1904/EL2904 (FSoE)

**Dependencies:** BROTLib, AstroBROT, HalfBROT, MONETcommon, MONET_Roof, Tc2_MC2, Tc2_MC2_Drive, Tc3_IotCommunicator

---

### MONETS
**Purpose:** Control system for MONET/S (Monitor of Network of Telescope South), 1.2m Alt-Az telescope.
**Mount Type:** ALT-AZ with field derotator
**Diameter:** 1.2m
**Location:** SAAO Sutherland, South Africa (lon 20.810808, lat -32.375823, alt 1798m)

Nearly identical to MONETN but configured for the Southern Hemisphere site.

**Key Subsystems:**
- Same as MONETN (Az/El/Derotator axes, covers, focus, hydraulics, safety, pendant)
- Weather station HTTP polling (currently disabled)
- Mirror/cell/flange temperature sensors

**MQTT:** Broker at 192.168.127.10:1883 (topics `MONETS/Telescope/SET`, `MONETS/Telemetry`, `MONETS/Log`)
**MQTT Watchdog:** 30s timeout triggers auto-park + roof close

**Hardware:** Same as MONETN (CX-7A03E9, AX5125/AX5206 drives, TMA motors, EL1904/EL2904 safety)

**Dependencies:** BROTLib, AstroBROT, HalfBROT, MONETcommon, MONET_Roof, Tc2_MC2, Tc2_MC2_Drive, Tc3_IotCommunicator

---

## Dependency Graph

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

## Common Patterns

- **All projects** target Beckhoff TwinCAT 3 (IEC 61131-3 Structured Text)
- **Build targets** include TwinCAT RT (x86/x64), TwinCAT CE7 (ARMv7), and TwinCAT OS (ARM/x64)
- **MQTT telemetry** is published via `FB_Comm_MQTT_Influx` following an InfluxDB-friendly topic schema
- **Pointing models** use Tpoint-style parametric coefficients (8-12 terms)
- **Safety** is handled via TwinSAFE (FSoE over EtherCAT) with EL1904/EL2904 terminals
- **Event logging** uses `FB_EventLog` blocks publishing structured messages via ADS logging
- **Manual control** is provided via BCD-selector hand pendants
- **Auto-park** timeout (12 hours) protects against abandoned sessions
