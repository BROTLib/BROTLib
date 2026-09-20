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

### FB_BaseAxis

Do this **after** the `FB_Axis` merge above, since `fbAxis`'s type depends on it.

**Target shape**: adopt BROTLib's `FB_BaseAxis` as the base (its `ActualPosition`/`isTracking` already work; IAG50cm's are stubbed/missing). Add IAG50cm's three extra members to it:

| Member | Section | Notes |
|--------|---------|-------|
| `bSoEReset` | VAR_INPUT | diagnostic reset |
| `fbSoEReset` | VAR | `FB_SoEReset` |
| `axisRef` | VAR | `AXIS_REF` |

Also change `fbAxis`'s type from `FB_Axis2`/`FB_Axis3` to the unified `FB_Axis`.

**Why this is safe to check first:** all 4 places that `EXTENDS FB_BaseAxis` in the repo already reveal how the current gaps are worked around at the subclass level, which tells us what must be cleaned up to avoid duplicate-identifier errors:

- `IAG50cm/POUs/FB_AxisControl.TcPOU` (parent of `FB_HourAngleControl`, `FB_DeclinationControl`, `FB_FocusControl`) locally re-declares `fActualPosition`, and overrides `ActualPosition` and `isTracking` — working around IAG50cm's `FB_BaseAxis` stub/gap. **Remove these three once the merged base supplies them**, or they'll collide with the new inherited members.
- `HalfBROT/POUs/FB_AxisControl.TcPOU` locally declares `bSoEReset`, `fbSoEReset`, `axisRef` — working around BROTLib's `FB_BaseAxis` missing them. **Remove these three** once the merged base supplies them.
- `MONETN/.../FB_MonetFocusControl.TcPOU` and `HalfBROT/POUs/FB_FocusControl.TcPOU` also extend `FB_BaseAxis` directly but don't use any of the colliding names (`FB_MonetFocusControl` uses a differently-named local `refAxis`) — unaffected, but worth a compile pass after the change since they're the only other direct subclasses in the repo.

**Migration:**
1. Merge `FB_Axis2`/`FB_Axis3` → `FB_Axis` (see above).
2. Add `bSoEReset`/`fbSoEReset`/`axisRef` to BROTLib's `FB_BaseAxis`; retype `fbAxis` to `FB_Axis`.
3. IAG50cm: delete its local `FB_BaseAxis.TcPOU`, reference BROTLib's (same POU Id already, so it's a content swap not a rename). Strip the now-redundant `fActualPosition`/`ActualPosition`/`isTracking` overrides from IAG50cm's `FB_AxisControl`.
4. HalfBROT: strip the now-redundant `bSoEReset`/`fbSoEReset`/`axisRef` declarations from `FB_AxisControl`.
5. Compile all four affected projects (BROTLib, IAG50cm, HalfBROT, MONETN).

## Git Workflow

Four separate repos are touched: **BROTLib**, **IAG50cm**, **HalfBROT**, **MONETN**. Each gets its own branch and its own PR — there's no cross-repo PR mechanism, so the work lands as four independent reviews, ideally merged in the order above (BROTLib first, since IAG50cm/HalfBROT/MONETN all depend on its `FB_Axis`/`FB_BaseAxis`).

Current branch state (checked 2026-07-16):

| Repo | Default branch today | `develop` exists? |
|------|----------------------|--------------------|
| BROTLib | `master` | No |
| IAG50cm | `main` | No |
| HalfBROT | `main` | No |
| MONETN | `master` | No |

Steps, per repo:

1. **Rename `master` → `main`** where still needed (BROTLib, MONETN only — IAG50cm and HalfBROT are already on `main`). Rename locally and on the remote, then update the GitHub default-branch setting so PRs target `main` by default:
   ```
   git branch -m master main
   git push -u origin main
   # then set main as the default branch on GitHub, and delete the old master branch on origin
   ```
2. **Fork `develop` from `main`** in all four repos (none currently have one):
   ```
   git checkout main
   git checkout -b develop
   git push -u origin develop
   ```
3. **Fork a feature branch from `develop`** in each repo for this unification work (e.g. `feature/fb-axis-unification`), and implement that repo's piece there.
4. **Open a PR from the feature branch into `develop`** (not `main`) in each repo.

Repeat step 3–4 independently per repo; step 1–2 is a one-time setup done once per repo before any unification branch is created.
