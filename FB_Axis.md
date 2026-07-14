# FB_Axis2 (BROTLib) vs FB_Axis3 (IAG50cm) — Comparison & Unification

## Files

| | BROTLib | IAG50cm |
|--|---------|---------|
| **Path** | `BROTLib/BROTLib/BROTLib/POUs/FB_Axis2.TcPOU` | `IAG50cm/IAG50cm/POUs/FB_Axis3.TcPOU` |
| **Lines** | 470 | 502 |
| **Instantiated by** | `FB_BaseAxis` (`fbAxis : FB_Axis2`) | `FB_BaseAxis` (`fbAxis : FB_Axis3`) |

## Additional Inputs (FB_Axis3 only)

| Input | Type | Default | Purpose |
|-------|------|---------|---------|
| `TrackVelocityRef` | LREAL | 0.0 | Expected average tracking velocity |
| `TrackDirectionRef` | INT | 0 | Tracking direction (-1, 0, 1) |
| `TrackEnvelope` | LREAL | 10.0 | `isTracking` tolerance in arcseconds |

## Tracking Logic — The Main Difference

### FB_Axis2 (passive / hold-position)

```st
IF Tracking THEN
    PositionDifference := LIMIT(-0.002, Position - ActualPosition, 0.002);
    TrackPosition := ActualPosition + PositionDifference;
    TrackVelocity := 0.0;
    TrackAcceleration := 0.0;
ELSE
    TrackPosition := ActualPosition;
    TrackVelocity := 0.0;
    TrackAcceleration := 0.0;
END_IF

IF NOT Tracking OR ABS(PositionDifference) < 1E-5 THEN
    Direction := 0;
    TrackVelocity := 0.0;
    TrackAcceleration := 0.0;
ELSIF PositionDifference < 0.0 THEN
    Direction := -1;
ELSE
    Direction := 1;
END_IF

isTracking := Tracking AND ABS(Position - ActualPosition) < 5.0E-3;
```

- PositionDifference clamped to ±0.002
- TrackPosition = clamped ActualPosition offset
- Feed velocity always 0 (passive)
- `isTracking` threshold fixed at 0.005

### FB_Axis3 (active / velocity-aware)

```st
IF Tracking THEN
    PositionDifference := Position - ActualPosition;
    TrackPosition := Position;
    IF ABS(PositionDifference) > 0.01 THEN
        TrackVelocity := 0.05;
        TrackAcceleration := 0.05;
    ELSE
        TrackAcceleration := 0.005;
    END_IF
ELSE
    TrackPosition := ActualPosition;
    TrackVelocity := 0.0;
    TrackAcceleration := 0.0;
END_IF

IF NOT Tracking OR ABS(PositionDifference) < 1E-5 THEN
    Direction := TrackDirectionRef;
    TrackAcceleration := 0.005;
ELSIF PositionDifference < 0.0 THEN
    Direction := -1;
    IF TrackDirectionRef = -1 THEN
        TrackVelocity := ABS(LIMIT(0.0, Velocity, 0.009));
    ELSE
        TrackVelocity := ABS(LIMIT(0.0, Velocity-TrackVelocityRef, 0.009));
    END_IF
ELSE
    Direction := 1;
    IF TrackDirectionRef = 1 THEN
        TrackVelocity := ABS(LIMIT(0.0, Velocity, 0.009));
    ELSE
        TrackVelocity := ABS(LIMIT(0.0, Velocity-TrackVelocityRef, 0.009));
    END_IF
END_IF

isTracking := Tracking AND ABS(Position - ActualPosition) < (TrackEnvelope/3600.0);
```

- PositionDifference unclamped (raw)
- TrackPosition = direct Position target
- Large error (>0.01): velocity 0.05, accel 0.05
- Small error: velocity adjusted by direction match, capped at 0.009
- `isTracking` threshold configurable via `TrackEnvelope` (arcseconds)

### Behavioral Comparison

| Aspect | FB_Axis2 | FB_Axis3 |
|--------|----------|----------|
| PositionDifference | Clamped ±0.002 | Raw (unclamped) |
| TrackPosition | `ActualPosition + clamped_diff` | `Position` (direct) |
| Velocity (large error) | 0.0 (passive) | 0.05 (active) |
| Velocity (small error) | Always 0.0 | `LIMIT(0.0, Velocity, 0.009)` or `LIMIT(0.0, Velocity-TrackVelocityRef, 0.009)` |
| MC_ExtSetPointGenFeed Velocity | `TrackVelocity` (always 0) | `Direction * TrackVelocity` (signed) |
| `isTracking` threshold | Fixed 5.0E-3 | Configurable `TrackEnvelope/3600` |

## Homing / Calibration

### FB_Axis2 (one-shot)
```st
IF HomeDone THEN
    Calibrated := TRUE;
    HomeAxis := FALSE;
END_IF
```
Calibrated set TRUE once, stays TRUE forever.

### FB_Axis3 (continuous)
```st
IF Axis_Status.Status.Homed THEN
    Calibrated := TRUE;
    HomeDone := TRUE;
    HomeAxis := FALSE;
ELSE
    Calibrated := FALSE;
    HomeDone := FALSE;
END_IF
```
Tracks live homed status. Can go FALSE if axis loses home. More robust.

## Error Handling

- **FB_Axis2**: Does NOT check `Axis_Status.Error`
- **FB_Axis3**: Includes `Axis_Status.Error` in both `ErrorID` and `Error` aggregation

## Unused Code

- **FB_Axis3** declares `Axis_HomeLatch: FB_LatchHome` but never uses it.

## FB_BaseAxis Differences

| | BROTLib | IAG50cm |
|--|---------|---------|
| **Path** | `BROTLib/BROTLib/BROTLib/POUs/FB_BaseAxis.TcPOU` | `IAG50cm/IAG50cm/POUs/FB_BaseAxis.TcPOU` |
| **POU Id** | `{bae85b54-65c9-4d1f-98f7-530b10d558b7}` | `{bae85b54-65c9-4d1f-98f7-530b10d558b7}` (same) |
| **Lines** | 348 | 338 |

### VAR_INPUT

| Input | BROTLib | IAG50cm |
|-------|---------|---------|
| `bEnable` | Yes | Yes |
| `bReset` | Yes | Yes |
| `bSoEReset` | **No** | Yes |
| `bHomeAxis` | Yes | Yes |
| `fPosition` | Yes | Yes |
| `fVelocity` | Yes | Yes |
| `bMoveNeg` | Yes | Yes |
| `bMovePos` | Yes | Yes |

### VAR

| Variable | BROTLib | IAG50cm |
|----------|---------|---------|
| `fbComm : I_Comm` | Yes | Yes |
| `fbAxis` type | `FB_Axis2` | `FB_Axis3` |
| `fbSoEReset : FB_SoEReset` | **No** | Yes |
| `axisRef : AXIS_REF` | **No** | Yes |

### VAR_OUTPUT

| Output | BROTLib | IAG50cm |
|--------|---------|---------|
| `fActualPosition` | Yes | **No** |
| `bCalibrated` | Yes | Yes |
| `bError` | Yes | Yes |
| `nErrorID` | Yes | Yes |
| `bReady` | Yes | Yes |

### Properties

| Property | BROTLib | IAG50cm |
|----------|---------|---------|
| `ActualPosition` | **Implemented** (returns `fActualPosition`) | **Stubbed out** (empty getter/setter, has `{warning 'add property implementation'}`) |
| `Busy` | Implemented (`fbAxis.Busy`) | Implemented (`fbAxis.Busy`) |
| `Calibrated` | Implemented (`bCalibrated`) | Implemented (`bCalibrated`) |
| `Enable` | Implemented (get/set `bEnable`) | Implemented (get/set `bEnable`) |
| `Error` | Implemented (`bError`) | Implemented (`bError`) |
| `ErrorID` | Implemented (`nErrorID`) | Implemented (`nErrorID`) |
| `HomeAxis` | Implemented (get/set `bHomeAxis`) | Implemented (get/set `bHomeAxis`) |
| `InNegLimit` | **Empty getter** | **Empty getter** |
| `InPosLimit` | **Empty getter** | **Empty getter** |
| `isTracking` | **Implemented** (`fbAxis.isTracking`) | **Missing entirely** |
| `MoveNeg` | Implemented (get/set `bMoveNeg`) | Implemented (get/set `bMoveNeg`) |
| `MovePos` | Implemented (get/set `bMovePos`) | Implemented (get/set `bMovePos`) |
| `Position` | Implemented (get/set `fPosition`) | Implemented (get/set `fPosition`) |
| `Ready` | Implemented (`bReady`) | Implemented (`bReady`) |
| `Velocity` | Implemented (get/set `fVelocity`) | Implemented (get/set `fVelocity`) |

### Methods

| Method | BROTLib | IAG50cm |
|--------|---------|---------|
| `FB_Init` | Sets `fbComm` | Sets `fbComm` |
| `Reset` | Sets `bReset := TRUE` | Sets `bReset := TRUE` |

### Summary of Issues in IAG50cm FB_BaseAxis

1. **`ActualPosition` property stubbed out** — getter/setter are empty. The `fActualPosition` VAR_OUTPUT is declared but never written to. This means `ActualPosition` is always 0.
2. **`isTracking` property missing** — no way to read tracking state from outside.
3. **`axisRef` declared in VAR but never passed to `fbAxis`** — `fbAxis` is never called in the body (the implementation is empty `<![CDATA[]]>`). This is the same in BROTLib — both `FB_BaseAxis` bodies are empty. The actual wiring presumably happens in concrete subclasses.
4. **`fbSoEReset` declared but never used** — same issue as `axisRef`, likely wired in subclasses.

## Unification Plan

### FB_Axis

**Create a single `FB_Axis` in BROTLib** as the superset:

1. **Use FB_Axis3's tracking logic** — strictly better (active correction, configurable envelope). FB_Axis2's passive tracking was an early simplified version.

2. **Use FB_Axis3's continuous homing check** — more robust, doesn't lose calibration state.

3. **Include `Axis_Status.Error`** — catches errors FB_Axis2 silently ignores.

4. **Remove `Axis_HomeLatch`** — unused dead code.

5. **Default the 3 new inputs** so existing BROTLib callers work unchanged:

| Input | Default | Effect |
|-------|---------|--------|
| `TrackVelocityRef` | 0.0 | Small-error velocity becomes `LIMIT(0.0, Velocity, 0.009)` — gentle active correction |
| `TrackDirectionRef` | 0 | Direction derived from position difference (same as FB_Axis2) |
| `TrackEnvelope` | 5.0 | 5 arcsec ≈ 0.0014°, close to FB_Axis2's old 0.005 threshold |

### Behavioral Impact on BROTLib

The only change: tracking becomes **active** instead of passive. With defaults, when there's a position error during tracking, the axis receives a small feed velocity (~0.009) instead of 0. This is more responsive and correct for telescope tracking.

### Migration

- **BROTLib**: Replace `FB_Axis2` → `FB_Axis`. No interface changes needed for `FB_BaseAxis` or its callers (new inputs have defaults).
- **IAG50cm**: Replace `FB_Axis3` → `FB_Axis`. Same interface, just a rename.
