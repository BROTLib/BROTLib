# BROTLib / IAG50cm Unification Plan

## Files Comparison

| File | BROTLib | IAG50cm | Status |
|------|---------|---------|--------|
| `ST_TelescopeConfig.TcDUT` | Yes | Yes | **Identical** |
| `NCError_TO_STRING.TcPOU` | Yes | Yes | **Identical** (metadata only) |
| `FB_Axis2.TcPOU` / `FB_Axis3.TcPOU` | FB_Axis2 | FB_Axis3 | **Unify** → `FB_Axis` |
| `FB_BaseAxis.TcPOU` | Uses FB_Axis2 | Uses FB_Axis3 | **Unify** → single `FB_BaseAxis` |
| `FB_PointingModelForward.TcPOU` | Alt/Az | HA/Dec | Different models |
| `FB_PointingModelInversion.TcPOU` | Alt/Az | HA/Dec | Different models |
| `MAIN.TcPOU` | Empty (library) | Full application | Keep separate |
| `FB_LatchHome.TcPOU` | No | Yes (unused ref in FB_Axis3) | Move to BROTLib or remove ref |
| `FB_AxisControl.TcPOU` | No | Yes | Evaluate for BROTLib |

---

## 1. FB_Axis / FB_BaseAxis (planned — see FB_Axis.md)

Detailed comparison and unification plan in [FB_Axis.md](./FB_Axis.md).

Summary:
- Merge `FB_Axis2` + `FB_Axis3` → single `FB_Axis` in BROTLib using FB_Axis3's logic (active tracking, continuous homing, error checks)
- Merge `FB_BaseAxis` — keep BROTLib's `fActualPosition` output and `isTracking` property, add IAG50cm's `bSoEReset`/`FB_SoEReset`/`axisRef`

---

## 2. Pointing Models

### FB_PointingModelForward

| | BROTLib | IAG50cm |
|--|---------|---------|
| **Coordinates** | Azimuth / Elevation | HourAngle / Declination |
| **Parameters** | Tpoint-style: AOFF, BNP, AN_A, AE_A, NPAE, EOFF, AN_E, AE_E, TF | Equatorial: AOFF, BNP, AN_H, AE_H, NPAE, EOFF, AN_D, AE_D |
| **Outputs** | Az_offset, El_offset | HA_correction, Dec_correction, HA_velocity, Dec_velocity |
| **Tracking velocity** | Computed externally in `Tracking/` functions | Built into the model (sidereal `omega`) |
| **FB_Init** | Yes (parameter initialization) | No |

### FB_PointingModelInversion

| | BROTLib | IAG50cm |
|--|---------|---------|
| **Iterations** | Fixed 10 | Up to 20, epsilon convergence (arcsec) |
| **Reference** | `REFERENCE TO FB_PointingModelForward` (via FB_Init) | Local `fbpointing : FB_PointingModelForward` instance |
| **Coordinates** | Az/El | HA/Dec |
| **Wrap-around** | None | Uses `LMOD` |

### Recommendation

These are fundamentally different astronomical coordinate models — **not directly mergeable**. Options:

1. **Keep both as separate POUs** in BROTLib: `FB_PointingModelForward_AltAz` and `FB_PointingModelForward_HADec` (same for Inversion). Clean naming, no ambiguity.
2. **Use a selector FB** that wraps both and picks the right one based on telescope type. Adds complexity for little benefit.
3. **IAG50cm adopts BROTLib's naming** and moves its HA/Dec models into BROTLib alongside the Alt/Az ones.

Option 1 is recommended — simplest, least risk.

---

## 3. MAIN.TcPOU

| | BROTLib | IAG50cm |
|--|---------|---------|
| **Role** | Library placeholder | Full telescope application |
| **Content** | Instantiates `FB_Comm_MQTT_Influx` with empty params | Instantiates CoverControl, DomeControl, PendantControl, TelescopeControl, SafetyHandling, FocusControl, HourAngleControl, DeclinationControl, plus MQTT config |

**Not unifiable.** BROTLib is a reusable library, IAG50cm is a specific installation. Keep separate.

---

## 4. NCError_TO_STRING.TcPOU

Functionally identical — same `CASE` statement for NC error codes. Only differences:
- ProductVersion metadata (`3.1.4026.8` vs `3.1.4024.13`)
- LineIds (editor line-number mappings)

**Action:** Pick the newer version (BROTLib's) and sync to IAG50cm. Or better: since BROTLib is the library, IAG50cm should just reference it.

---

## 5. ST_TelescopeConfig.TcDUT

Byte-identical in both projects. No action needed — already shared.

---

## 6. FB_LatchHome

Exists in IAG50cm, referenced (but unused) in `FB_Axis3`'s variable declaration:
```st
Axis_HomeLatch: FB_LatchHome;
```
Never called in the implementation.

**Options:**
1. Remove the dead reference from the unified `FB_Axis` (cleanest).
2. Move `FB_LatchHome` into BROTLib if it has future use.

---

## 7. Interfaces

### BROTLib defines 13 interfaces:

`I_AltAzTelescope`, `I_Axis`, `I_BaseAxis`, `I_Brake`, `I_Dome`, `I_Filter`, `I_Focus`, `I_Hydraulics`, `I_MirrorCovers`, `I_Nasmyth`, `I_RaDecTelescope`, `I_Roof`, `I_Telescope`

### IAG50cm defines 3 inline interfaces:

`I_CoverState`, `I_DomeState`, `I_PendantState`

### Recommendation

IAG50cm's 3 interfaces are specific to its subsystems (covers, dome, pendant). They don't overlap with BROTLib's 13. However:
- BROTLib already has `I_Dome` — IAG50cm's `I_DomeState` could potentially align with it
- Consider whether IAG50cm should adopt BROTLib's `I_BaseAxis` interface for its axis implementations

---

## 8. Tracking Functions (BROTLib only)

BROTLib has `Tracking/` with 4 functions:
- `Azimuthvelocity` — computes Az tracking velocity from coordinates
- `Elevationvelocity` — computes El tracking velocity from coordinates
- `DerotatorPosition2` — computes field derotator angle
- `Derotatorvelocity` — computes derotator angular velocity

IAG50cm computes tracking velocities inside `FB_PointingModelForward` (HA/Dec velocities).

**Recommendation:** These are coordinate-system-specific and map to the respective pointing models. Keep alongside their pointing model counterparts. If IAG50cm's HA/Dec model is moved to BROTLib, its velocity computations should be part of that model (as they already are).

---

## 9. IAG50cm-only Subsystems

These are hardware-specific to the IAG 50cm telescope and have no BROTLib equivalent:

| Subsystem | Files | Purpose |
|-----------|-------|---------|
| `CoverControl/` | 6 | Mirror cover open/close |
| `DomeControl/` | 9 | Dome rotation, shutter |
| `PendantControl/` | 9 | Hand controller |
| `FB_SafetyHandling` | 1 | Safety interlocks |
| `FB_CabinetControl` | 1 | Cabinet I/O |
| `FB_HourAngleControl` | 1 | HA axis control |
| `FB_DeclinationControl` | 1 | Dec axis control |
| `FB_FocusControl` | 1 | Focuser control |
| `FB_TelescopeControl` | 1 | Top-level telescope control |
| `FB_SerialBackground` | 1 | Serial port handling |
| `FB_RefMarkerSearch` | 1 | Reference marker search |

**Not unifiable** — these are installation-specific. They should consume BROTLib's abstractions (`FB_Axis`, `FB_BaseAxis`, interfaces) but remain in IAG50cm.

---

## Priority Summary

| Priority | Item | Effort |
|----------|------|--------|
| **High** | Unify `FB_Axis2` + `FB_Axis3` → `FB_Axis` | Medium |
| **High** | Unify `FB_BaseAxis` | Low (follows from FB_Axis) |
| **Medium** | Sync `NCError_TO_STRING` to newer version | Trivial |
| **Medium** | Evaluate `FB_PointingModelForward` HA/Dec for BROTLib | High (different math) |
| **Low** | Remove dead `Axis_HomeLatch` ref from unified FB_Axis | Trivial |
| **Low** | Align IAG50cm interfaces with BROTLib's `I_BaseAxis` | Low |
| **None** | `MAIN.TcPOU` | Keep separate |
| **None** | IAG50cm hardware subsystems | Keep separate |
