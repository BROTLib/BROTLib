# Telescope Position Tracking

How the telescope follows a celestial target over time.

## Overview

Tracking does not command a fixed velocity. Each PLC cycle (10 ms), the system recalculates the target Alt/Az from fixed RA/Dec + advancing sidereal time, computes the instantaneous velocity needed to follow that moving target, and sends both position and velocity to the NC axis controllers.

## Entry into Tracking

`Track(RA, Dec)` does not start tracking directly — it triggers a **goto** first:

```
Track(RA, Dec)
  → sets bGoto = TRUE
  → _GotoTelescope() moves all axes to computed Alt/Az
  → stage 100: bTrack := bAutoTrack   (automatically enters tracking)
```

Once all axes report `MoveDone` and reach standstill, `_TrackTelescope()` is called every PLC cycle.

## Sidereal Time

The sidereal clock chain:

1. `FB_AstroClock` reads Beckhoff `RTC_EX2` (high-precision real-time clock), syncs with NT time every 5 s
2. `DateTime2JD` converts `TIMESTRUCT` → Julian Date
3. `CT2LST` converts JD → Local Sidereal Time (degrees):

```
T  := (jd - jd2000) / 36525.0
θ  := 280.46061837 + (360.98564736629 × t₀) + T² × (0.000387933 - T / 38710000)
LST := MOD((θ + longitude) / 15.0, 24.0)   [hours]
```

The coefficient `360.98564736629` is degrees per sidereal day. As LST advances, hour angle (`HA = LST - RA`) increases, so the Alt/Az computed for a fixed RA/Dec drifts at exactly the sidereal rate.

The critical connection: tracking relies on `eq2hor` recomputing Alt/Az from the advancing LST. The velocity formulas are derivatives of that coordinate transformation.

## Per-Cycle Tracking Loop

Called every PLC cycle from `_TrackTelescope()` (`MONETcommon/FB_MonetTelescopeControl.TcPOU:1123-1191`):

```
1. fbTime()                          → read clock
2. fJd := DateTime2JD(...)           → Julian Date
3. fLst := CT2LST(longitude, fJd)    → Local Sidereal Time
4. eq2hor(RA, Dec, LST, lat, alt)    → fAzimuthCalc, fElevationCalc
5. fbPointing(az, el)                → pointing offsets
6. apply offsets                      → corrected fAzimuthCalc, fElevationCalc
7. fDerotatorCalc := F_DerotatorPosition2(...) + fDerotatorOffset
8. F_Azimuthvelocity(el, az, lat)    → fAzimuthVelocity
9. F_Elevationvelocity(az, lat)      → fElevationVelocity
10. F_Derotatorvelocity(el, az, lat) → fDerotatorVelocity
11. send (position, velocity) to each axis controller
```

## Tracking Velocity Formulas

Sidereal rate constant:

```
Ω = 360° / 86164.099 s = 4.17807 × 10⁻³ deg/s
```

### Azimuth (`F_Azimuthvelocity`)

```pascal
dAz/dt = Ω × (sin(φ) - cos(φ) × cos(A) × tan(el))
```

where φ = site latitude, A = azimuth, el = elevation. Diverges near zenith (tan(el) → ∞); guarded by `|cos(el)| > 1e-3`.

### Elevation (`F_Elevationvelocity`)

```pascal
dEl/dt = Ω × sin(A) × cos(φ)
```

Zero at azimuth 0°/180° (North/South), maximum at 90°/270° (East/West). Independent of elevation itself.

### Derotator (`F_Derotatorvelocity`)

```pascal
dψ/dt = -Ω × cos(A) × cos(φ) / cos(el) - Ω × cos(φ) × sin(A)
```

Field rotation rate for an alt-az mount. Source: [field_derotator_formula.pdf](https://github.com/cytan299/field_derotator/blob/master/field_derotator_formula/field_derotator_formula.pdf). Guarded against `|cos(el)| > 1e-3`.

### Derotator Position (`F_DerotatorPosition2`)

```pascal
q = -arctan( sin(A) / (tan(φ)×cos(el) - sin(el)×cos(A)) )   [parallactic angle]
derotator = MOD(q - sign × el + offset, 360°)
```

`sign` (`fDerotatorSign`) accounts for different derotator mounting orientations.

## Pointing Model During Tracking

Applied before velocity calculation in the main body (`FB_MonetTelescopeControl:120-128`):

```pascal
fbPointing(fAzimuth := fAzimuthCalc, fElevation := fElevationCalc, ...)

fElevationCalc := fElevationCalc + fElevationPointingOffset + fElevationOffset
fAzimuthCalc   := fAzimuthCalc + fAzimuthPointingOffset
                  + fAzimuthOffset / COS(fElevationCalc * d2r)
```

Velocities are then calculated on the **corrected** coordinates:

```pascal
fDerotatorVelocity := F_Derotatorvelocity(fElevationCalc, fAzimuthCalc, ...)
fElevationVelocity := F_Elevationvelocity(fAzimuthCalc, ...)
fAzimuthVelocity   := F_Azimuthvelocity(fElevationCalc, fAzimuthCalc, ...)
```

### Forward Model (`FB_PointingModelForward`)

8-parameter Tpoint-style model:

```
Az offset  = AOFF - BNP/cos(el)
             + AN_A×sin(az)×tan(el) - AE_A×cos(az)×tan(el) + NPAE×tan(el)
El offset  = EOFF + AN_E×cos(az) + AE_E×sin(az) + TF×cos(el)
```

| Parameter | Meaning |
|-----------|---------|
| AOFF | Azimuth encoder zero error |
| EOFF | Elevation encoder zero error |
| BNP | Collimation (beam non-perpendicularity) |
| AN_A, AE_A | Azimuth axis misalignment (N-S / E-W) |
| AN_E, AE_E | Elevation axis misalignment (N-S / E-W) |
| NPAE | Non-perpendicularity of az and el axes |
| TF | Gravitational tube flexure |

### Inverse Model (`FB_PointingModelInversion`)

Solves for sky coordinates from encoder positions by iterating the forward model 11 times:

```pascal
FOR i := 0 TO 10 DO
    fbPointing(fAzimuth := az - d_az, fElevation := el - d_el, ...)
END_FOR
```

### MONETN Calibrated Values

```
BNP   = 0.417996     AN_A  = -0.000540
AE_A  =  0.001094    NPAE  =  0.354092
AN_E  = -0.001539    AE_E  =  0.002838
TF    =  0.075394
```

During tracking, pointing offsets change every cycle as Alt/Az change, so mount misalignments, flexure, and collimation errors are continuously compensated.

## Safety Limits

Tracking auto-stops if:

| Condition | Threshold | File |
|-----------|-----------|------|
| Elevation too low | < 5.0° | `FB_MonetTelescopeControl:1148` |
| Elevation too high | > 89.5° | `FB_MonetTelescopeControl:1148` |
| Azimuth wrap | > 440.0° | `FB_MonetTelescopeControl:1151` |
| Derotator limit (low) | < -69.0° and moving negative | `FB_MonetTelescopeControl:1155` |
| Derotator limit (high) | > 379.0° and moving positive | `FB_MonetTelescopeControl:1155` |

## Velocity Function Usage Across Projects

The velocity functions are called in two contexts: the **main body** (runs every cycle regardless of state) and **`_TrackTelescope()`** (runs only when tracking is active). The main-body computation is redundant in some projects.

### MONETN (independent `FB_MonetTelescopeControl` copy)

Velocities computed **3 times per cycle**:

| Location | Lines | Used for |
|----------|-------|----------|
| Main body, first call | 140-142 | Axis wrapping decisions (149-159) |
| Main body, second call | 145-147 | Redundant — same wrapping logic |
| `_TrackTelescope()` | 1088-1090 | Applied to axis velocity outputs |

The wrapping code at lines 149-159 is **active** and uses velocity direction:

```pascal
IF (fAzimuthCalc > 310.0 AND fAzimuthVelocity > 0.0) OR (fAzimuthCalc > 440.0) THEN
    fAzimuthCalc := fAzimuthCalc - 360.0;
ELSIF (fAzimuthCalc < 80.0 AND fAzimuthVelocity < 0.0) OR (fAzimuthCalc < -50.0) THEN
    fAzimuthCalc := fAzimuthCalc + 360.0;
END_IF
```

This avoids the axes spinning the long way around when crossing the 0°/360° boundary.

### MONETcommon (shared library, used by MONETS)

Velocities computed **2 times per cycle**:

| Location | Lines | Used for |
|----------|-------|----------|
| Main body | 134-136 | Dead code — wrapping at 149-159 is commented out |
| `_TrackTelescope()` | 1124-1126 | Applied to axis velocity outputs |

The main-body computation is unused. `_TrackTelescope()` recomputes from the same inputs.

### IAG50cm

Does **not** use `F_Azimuthvelocity`, `F_Elevationvelocity`, `F_Derotatorvelocity`, or `F_DerotatorPosition2`. Has its own telescope control implementation.

### Dead Code Note

In MONETN's `_TrackTelescope()`, the velocity assignment has unreachable branches:

```pascal
IF NOT fbElevation.Tracking THEN
    ...
    IF fbElevation.isTracking THEN
        fbElevation.Velocity := fElevationVelocity;      -- line 1108
    ELSE
        fbElevation.Velocity := 3.0*fElevationVelocity;  -- line 1110
    END_IF
    fbElevation.Velocity := fElevationVelocity;           -- line 1112 (overwrites both)
```

Line 1112 unconditionally overwrites both branches, making the `3.0*fElevationVelocity` path unreachable. Same pattern for azimuth and derotator.

## bTracking Status

The telescope-level `bTracking` output requires all three axes to be in stable velocity tracking for a sustained period:

```pascal
tonTrackingDelay(
    in := fbElevation.fbAxis.isTracking
       AND fbAzimuth.fbAxis.isTracking
       AND fbDerotator.fbAxis.isTracking,
    PT := T#5500MS,
    Q  => bTracking
);
```

5.5 s debounce prevents false status during transitions.

## Non-Sidereal Tracking: Interface Design

Reference: [pyobs tracking-mode-design.md](/home/husser/code/pyobs/pyobs-core/tracking-mode-design.md)

### Problem

BROT's current tracking is strictly sidereal — `Track(RA, Dec)` stores fixed coordinates and the pipeline recomputes Alt/Az (or HA/Dec) from those plus advancing LST. There is no mechanism for tracking the Moon, planets, asteroids, or other non-sidereal bodies at runtime.

### Architectural Difference from pyobs

**pyobs** separates pointing from tracking — `ITrackingMode` (discrete: sidereal/solar/lunar/off) and `ITrackingRate` (continuous RA/Dec rate offset) are independent of where the telescope points. The tracking rate is a firmware-level property.

**BROT** computes everything from RA/Dec + LST each cycle. There is no separate "tracking rate" register — the velocity functions derive instantaneous rates from the current position of a fixed RA/Dec target. The RA/Dec is set once and stays fixed.

### Two Architectures in BROT

The two telescope types handle tracking velocities differently:

**MONET (Alt-Az mount):** Velocities are computed from Alt/Az position using `F_Azimuthvelocity`, `F_Elevationvelocity`, `F_Derotatorvelocity` — derivatives of the coordinate transformation equations. These are sent as velocity commands to the NC axes.

**IAG50cm (equatorial HA-DEC mount):** Velocities are computed by `FB_PointingModelForward`, which applies sidereal rate (`omega = 360°/86164.099s`) plus pointing model corrections. The HA axis receives `TrackVelocityRef := omega` (sidereal reference), and `FB_Axis3` computes the correction as `Velocity - TrackVelocityRef`. The Dec axis has `TrackVelocityRef := 0.0` (no sidereal component).

### Two Implementation Approaches

#### Approach A: Update RA/Dec from ephemeris each cycle

Works for **MONET only**. Instead of modifying velocity formulas, update the stored RA/Dec before each cycle's coordinate conversion:

```pascal
// Non-sidereal tracking: update target before coordinate conversion
IF bUpdateTarget THEN
    fRightAscension := fRightAscension + fRaRate * fDt;
    fDeclination    := fDeclination + fDecRate * fDt;
END_IF
```

For MONET, the existing pipeline does the rest — `eq2hor` computes the correct Alt/Az, velocity functions compute the correct rates. No changes to velocity functions needed.

**Does not work for IAG50cm** — see "Approach A Does Not Work for IAG50cm" below.

| pyobs Interface | MONET Implementation |
|---|---|
| `TrackingMode.SIDEREAL` | Current behavior — fixed RA/Dec, LST advances |
| `TrackingMode.OFF` | Stop tracking (`bTrack := FALSE`) |
| `TrackingMode.SOLAR` | Update RA/Dec from solar ephemeris each cycle |
| `TrackingMode.LUNAR` | Update RA/Dec from lunar ephemeris each cycle |
| `ITrackingRate(ra_rate, dec_rate)` | Update RA/Dec each cycle: `RA += ra_rate × dt`, `Dec += dec_rate × dt` |

#### Approach B: Modify velocity functions with rate offset

Required for **IAG50cm**. Add the non-sidereal rate to the velocity computation:

```
HA_velocity = (omega + non_sidereal_rate + pointing_corrections) / d2r
Dec_velocity = (pointing_corrections + non_sidereal_rate) / d2r
```

This modifies `FB_PointingModelForward` to include the non-sidereal rate in `omega` and the Dec output. The pointing model corrections then automatically scale with the actual rate.

### Approach A Does Not Work for IAG50cm

Approach A (update RA/Dec, let existing pipeline handle it) works for MONET but **fails for IAG50cm** due to how `FB_Axis3` handles tracking.

**Why it works for MONET:** The velocity functions (`F_Azimuthvelocity` etc.) are derivatives of the coordinate transformation. They take current Alt/Az as input and output the instantaneous rate needed to follow that position. When RA/Dec changes (non-sidereal target), the Alt/Az changes, and the velocity functions automatically compute the correct rate. No velocity function changes needed.

**Why it fails for IAG50cm:** The velocity path is hardcoded to sidereal rate:

1. `FB_PointingModelForward` computes `Velocity = (omega + track_tau_esti)/d2r` where `omega` is the sidereal rate (line 42, 99). It doesn't know about non-sidereal motion.

2. `FB_Axis3` receives this velocity and computes a correction: `TrackVelocity = Velocity - TrackVelocityRef` (line 155). For HA, `TrackVelocityRef = omega`, so the correction is just the pointing model terms. The non-sidereal rate is missing.

3. When RA/Dec updates and the HA position changes, `FB_Axis3` tries to catch up via position-following. But the catch-up velocity is clamped to **0.05 deg/s** (line 134). The Moon moves at ~0.5 deg/s — 10x faster. The axis falls behind and never catches up.

```
Moon tracking scenario:
  dRA/dt ≈ 0.5 deg/s (Moon's apparent motion)
  Each 10ms cycle: target moves 0.005 arcsec
  After 1s: PositionDifference = 0.5 deg (>> 0.01 threshold)
  TrackVelocity = 0.05 deg/s (clamped)
  Axis falls behind at 0.45 deg/s → never converges
```

### Approach B Required for IAG50cm

IAG50cm needs velocity path modifications — updating RA/Dec alone is insufficient:

**1. Modify `FB_PointingModelForward` — add non-sidereal rate to `omega`:**

```pascal
// Current (line 42):
omega : LREAL := 360.0 / 86164.099 * (PI/180.0);

// Modified:
omega := 360.0 / 86164.099 * (PI/180.0) + fNonSiderealHaRate * d2r;
```

This makes the pointing model corrections (`track_tau_esti`, `track_dec_esti`) scale correctly with the actual HA rate, and the output velocity includes the non-sidereal component.

**2. Modify Dec velocity output — add non-sidereal Dec rate:**

```pascal
// Current (line 100):
Declination_velocity := track_dec_esti / d2r;

// Modified:
Declination_velocity := (track_dec_esti + fNonSiderealDecRate * d2r) / d2r;
```

The Dec axis has `TrackVelocityRef = 0.0`, so the full velocity is used directly.

**3. Optionally increase catch-up limit in `FB_Axis3`:**

```pascal
// Current (line 134):
TrackVelocity := 0.05;

// Modified:
TrackVelocity := 0.05 + ABS(fNonSiderealHaRate);
```

This ensures the axis can catch up when the position target jumps from an ephemeris update.

### Summary: Approach by Telescope Type

| | MONET (Alt-Az) | IAG50cm (HA-DEC) |
|---|---|---|
| Approach A (update RA/Dec only) | ✓ Works | ✗ Fails — velocity path hardcoded to sidereal |
| Required changes | Just update RA/Dec before `eq2hor` | Update RA/Dec + modify `FB_PointingModelForward` + increase `FB_Axis3` catch-up limit |
| Velocity functions | `F_Azimuthvelocity` etc. (auto-account for changing target) | `FB_PointingModelForward` (must be modified to include non-sidereal rate) |
| Why different | Velocities are coordinate derivatives — they naturally follow a moving target | Velocity is sidereal rate + corrections — doesn't know about non-sidereal motion |

### What Each Architecture Needs

**MONET (Alt-Az):**
- Just update RA/Dec before `eq2hor` — no velocity function changes
- Derotator stays correct automatically — it derives from Alt/Az
- Pointing model stays correct — applied to updated coordinates

**IAG50cm (HA-DEC):**
- Update RA/Dec before HA/Dec conversion
- Modify `FB_PointingModelForward` — add non-sidereal rate to `omega` (line 42) and Dec output (line 100)
- Increase `FB_Axis3` catch-up velocity limit (line 134) for fast-moving bodies
- Pointing model corrections automatically scale correctly once `omega` includes the non-sidereal rate

### Ephemeris Sources

For Approach A, RA/Dec updates need an ephemeris source:

- **Solar/Lunar**: precomputed Chebyshev polynomials or simple analytical models (sunpos is already in AstroBROT)
- **Planets**: JPL Horizons queries or Keplerian elements propagated locally
- **Asteroids/comets**: orbital elements with local two-body propagation (no network dependency)

The ephemeris computation runs on the PLC's task cycle (10 ms), so it must be lightweight — analytical models or small lookup tables, not network queries. For complex targets (asteroids with fresh elements), an external Python service could publish RA/Dec rates over MQTT, which the PLC consumes.

## Key Files

| File | Purpose |
|------|---------|
| `BROTLib/POUs/Tracking/F_Azimuthvelocity.TcPOU` | Azimuth tracking rate formula |
| `BROTLib/POUs/Tracking/F_Elevationvelocity.TcPOU` | Elevation tracking rate formula |
| `BROTLib/POUs/Tracking/F_Derotatorvelocity.TcPOU` | Field rotation rate formula |
| `BROTLib/POUs/Tracking/F_DerotatorPosition2.TcPOU` | Derotator target position |
| `BROTLib/POUs/FB_BaseTelescopeControl.TcPOU` | LST/JD calculation, coordinate updates |
| `BROTLib/POUs/Pointing/FB_PointingModelForward.TcPOU` | Forward pointing model |
| `BROTLib/POUs/Pointing/FB_PointingModelInversion.TcPOU` | Inverse pointing model |
| `BROTLib/POUs/FB_AstroClock.TcPOU` | Real-time clock synchronization |
| `AstroBROT/FB_EQ2HOR.TcPOU` | Equatorial → horizontal conversion |
| `AstroBROT/FB_HOR2EQ.TcPOU` | Horizontal → equatorial conversion |
| `AstroBROT/CT2LST.TcPOU` | Julian Date → Local Sidereal Time |
| `AstroBROT/DateTime2JD.TcPOU` | TwinCAT TIMESTRUCT → Julian Date |
| `AstroBROT/FB_PRECESS.TcPOU` | Precession between epochs |
| `AstroBROT/FB_NUTATE.TcPOU` | Nutation corrections |
| `AstroBROT/FB_CO_REFRACT.TcPOU` | Atmospheric refraction |
| `MONETcommon/FB_MonetTelescopeControl.TcPOU` | `_TrackTelescope()` loop |
