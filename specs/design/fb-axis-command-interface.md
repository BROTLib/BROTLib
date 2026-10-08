# FB_Axis command interface: homing reference and command handshake

Repos: BROTLib (`FB_Axis`, `FB_BaseAxis`), HalfBROT (azimuth, elevation, derotator, focus axes; used by
MONETcommon, MONETS, MONETN), IAG50cm (hour angle, declination, focus axes)

**Status: proposed (2026-10-08).** Nothing implemented. Covers the two `FB_Axis` interface changes left over from
BROTLib#9 that are not bug fixes but interface decisions: (A) a mandatory homing reference position, (B) who owns
the command flags (`MoveAxis`, `HomeAxis`, `StopAxis`, `Jog_Forward`, `Jog_Backwards`). Work order and status:
[2026-10-08-fb-axis-home-position-and-command-handshake.md](../plans/2026-10-08-fb-axis-home-position-and-command-handshake.md).
Background: [2026-09-23-fb-axis-latching-and-self-mutation-fixes.md](../plans/2026-09-23-fb-axis-latching-and-self-mutation-fixes.md)
(findings 3 and 4 there). Issues: BROTLib #62 (A), #63 (B); HalfBROT #46, IAG50cm #21 (migration);
IAG50cm #20 (IAG50cm focus reference).

## Who uses FB_Axis

`FB_Axis` is never instantiated by a telescope directly. `FB_BaseAxis` (BROTLib) holds `fbAxis : FB_Axis`, each
repo's `FB_AxisControl` extends `FB_BaseAxis`, and the concrete axis blocks call `fbAxis(...)` once per cycle with
**all** inputs in the parameter list. Seven call sites, checked on `develop` 2026-10-08:

| Repo | Block | Homes via `FB_Axis`? | `HomingMode` | Position while homing (= reference today) |
|---|---|---|---|---|
| HalfBROT | `FB_AzimuthControl` | yes | default (`MC_DefaultHoming`, cam) | `fCalibPosition` (set every cycle while `bHomeAxis`) |
| HalfBROT | `FB_ElevationControl` | yes | default | `fCalibPosition` |
| HalfBROT | `FB_DerotatorControl` | yes | `MC_ForceCalibration` | `fCalibPosition` |
| HalfBROT | `FB_FocusControl` | yes | `MC_ForceCalibration` if `fLastPposition > 0`, else `MC_DefaultHoming` | `fLastPposition`, else `fHomingPosition` |
| IAG50cm | `FB_HourAngleControl` | no (`HomeAxis := FALSE`; `FB_LatchHome` + `MC_SetPosition`) | `MC_ForceCalibration` | not used |
| IAG50cm | `FB_DeclinationControl` | no (same) | `MC_ForceCalibration` | not used |
| IAG50cm | `FB_FocusControl` | yes | `MC_ForceCalibration` | **whatever `fPosition` holds** (`fPosition := fPosition`) |

MONETcommon, MONETS and MONETN use HalfBROT's axis blocks; they set `fCalibPosition`/`fHomingPosition` and call
`Home()`/`MoveAxis` through `I_Axis`, they do not call `FB_Axis` themselves.

## A. Mandatory homing reference (`HomePosition`)

### Problem

`Axis_Home` passes the `Position` input, the target of a normal move, as the homing reference. With
`MC_ForceCalibration` that value is written as the axis's current position without moving; with cam homing it is the
position assigned at the cam. If a stale move target is in `Position` when homing starts, the axis is calibrated to
it and every later position is off, silently.

Six of the seven callers avoid that by writing their calibration value into `fPosition` while homing. **IAG50cm's
focus does not**: it homes with `MC_ForceCalibration` and `fPosition := fPosition`, so its calibration depends on the
last target. The one place that makes the reference explicit is a comment in `FB_Axis` asking not to change it.

### Design

Add a separate reference input that **every call must assign**:

```st
VAR_IN_OUT CONSTANT
	HomePosition	: LREAL;	// reference position for Axis_Home (MC_ForceCalibration: set as current position;
								// cam homing: position at the cam). Must be assigned in every call.
END_VAR
```

and use it in `Axis_Home` (`Position := HomePosition`). `Position` is then only the move target.

Why `VAR_IN_OUT CONSTANT`: the compiler rejects a call that does not assign it, so "mandatory" is checked at build
time in every consumer, not discovered at run time. It accepts literals and expressions (`HomePosition := 0.0`,
`HomePosition := SEL(...)`). `FB_Axis` already has a `VAR_IN_OUT` (`AxisRef`), so every call already passes its
parameters in the call; nothing changes in the calling style. **To verify in XAE** before relying on it: TwinCAT
version on the engineering PCs supports `VAR_IN_OUT CONSTANT` (3.1.4024 does), and the error message when a call
omits it.

With B2 below (command methods), the same applies to the method: `METHOD Home` declares `fReference` as
`VAR_IN_OUT CONSTANT` too, because ordinary method `VAR_INPUT`s may be omitted in TwinCAT and then silently default
to 0.

Rejected alternatives:
- `VAR_INPUT HomePosition` with a default: not mandatory, a forgotten assignment silently uses the default.
- `VAR_INPUT` with a NaN default and an error at run time when homing with NaN: mandatory only at run time, i.e. on
  the telescope.
- Keeping `Position` as fallback when `HomePosition` is not set: what the issue asked to avoid.

### Migration per caller (behaviour unchanged except IAG50cm focus)

| Block | New argument |
|---|---|
| HalfBROT azimuth, elevation, derotator | `HomePosition := fCalibPosition` |
| HalfBROT focus | `HomePosition := SEL(fLastPposition > 0.0, fHomingPosition, fLastPposition)` (same choice it makes for `fPosition` today) |
| IAG50cm hour angle, declination | `HomePosition := 0.0` with a comment that homing goes through `FB_LatchHome` (they never set `HomeAxis`) |
| IAG50cm focus | **decision needed**, see below |

The `fPosition := fCalibPosition` / `fPosition := fHomingPosition` lines in the HalfBROT blocks stay for now: they
also make the move right after homing go to the calibration position (`homeDelay`). Removing them is a separate
clean-up once the move is made explicit.

**Open decision, IAG50cm focus:** it has no reference switch (`MC_ForceCalibration`), so "homing" means "declare the
current position to be X". What should X be?
1. `telescopeConfig.focusHome` (16.3): only correct if the focus was parked there before the power cut.
2. A persistent last known position (like HalfBROT's `fLastPposition`): correct as long as nothing moved the focus
   while unpowered.
3. Fit a reference switch and use real homing.

Until decided, the migration passes `fPosition` explicitly (`HomePosition := fPosition`, today's behaviour) with a
`TODO` pointing at the IAG50cm issue, so the interface change does not silently change this axis.

### Compatibility

Breaking change of `FB_Axis` (new mandatory parameter), accepted: all repos are updated together (decision
2026-10-08). BROTLib minor version (0.7.0). Constraint for the order of merges: HalfBROT, MONETcommon, MONETS and
MONETN resolve `BROTLib, *`, and the CI runner's test job installs BROTLib `develop` into the library repository,
so HalfBROT stops building as soon as the change is on BROTLib `develop`. The BROTLib and HalfBROT changes are
therefore merged back to back (see the plan). IAG50cm pins `BROTLib, 0.5.5`; it moves to 0.7.0 in the same round.

## B. Command flags: one owner

### Problem

`MoveAxis`, `HomeAxis`, `StopAxis`, `Jog_Forward` and `Jog_Backwards` are `VAR_INPUT`s that `FB_Axis` also writes:
it clears `MoveAxis` on `MoveDone`, `HomeAxis` once homed, `StopAxis` on `StopDone`, both jog flags on `JogDone`.

All seven callers pass these inputs in the call list every cycle (`MoveAxis := bMoveAxis`) and clear their own flag
on the matching done output (`IF fbAxis.MoveDone THEN bMoveAxis := FALSE`). So the handshake runs twice: `FB_Axis`'s
own clear is overwritten by the caller's value at the next call and has no effect; what actually ends a command is
the caller's clear. The telescope blocks above them set `MoveAxis`/`HomeAxis` through `I_Axis` properties and rely
on the axis block's clear. It works today because every caller follows the same pattern, but:

- A caller that sets a flag once and relies on `FB_Axis` to clear it (the pattern the self-clear suggests) works
  only if it sets the field directly instead of passing it in the call: two valid-looking usages, different
  behaviour.
- Reading `FB_Axis` alone does not tell you when a command ends; the truth is in seven callers.
- `Jog_*` come from pendant buttons (levels); `FB_Axis` clearing them on `JogDone` is meaningless for a level.

### Options

**B1. Callers own the flags.** `FB_Axis` stops writing its inputs: remove the five self-clears and keep the done
outputs (`MoveDone`, `HomeDone`/`Calibrated`, `StopDone`, `JogDone`) as the only signal. Document the contract in
the declaration: "level input, the caller sets it and clears it on the done output". This matches what all seven
callers already do, so the expected behaviour change is none. Small diff, no change to the axis blocks or `I_Axis`.
Leaves the double handshake in the callers (each axis block still clears its flag on the done output).

**B2. Command methods.** `FB_Axis` gets methods `Move(fPosition, fVelocity)`, `Home(fReference)`, `Stop()`, which
latch a request that `FB_Axis` turns into a rising `Execute` and clears itself on done/error; outputs per command
(`MoveDone`, `HomeDone`, `StopDone`, `Busy`, `Error`). No command inputs, so nothing to fight over, and
`Home(fReference)` makes A's reference part of the call. The axis blocks drop their `bMoveAxis`/`bHomeAxis`/
`bStopAxis` bookkeeping and call the methods from their `I_Axis` property setters (`MoveAxis := TRUE` ->
`fbAxis.Move(...)`), so the telescope state machines (MONETcommon, IAG50cm) do not change. Jog stays a level input
(`Jog_Forward`/`Jog_Backwards`, read-only), since it is a held button.

**Recommendation:** with breaking changes accepted (2026-10-08), **B2**, done in the same round as A (A becomes the
`fReference` argument of `Home`). B1 is the fallback if B2 turns out bigger than expected at implementation time; it
can be done in an afternoon. The `I_Axis` property setters keep the telescope-facing interface stable either way.

### What must be checked before B1

- That no caller sets a command field directly (`fbAxis.MoveAxis := TRUE` outside the call) and relies on the
  self-clear. The 2026-10-08 grep found none in HalfBROT, IAG50cm or MONETcommon; re-check at implementation time.
- `HomeAxis`: `FB_Axis` keeps a re-home request alive while `Axis_Home.Busy` (re-home fix `6dabd5a`); callers clear
  `bHomeAxis` on `HomeDone`, which is a level while homed. Confirm the re-home case on the IAG50cm focus (the
  2026-10-06 re-home check) still works without the self-clear.
- Jog: confirm with the pendant on one telescope that releasing the button stops the axis (it must already, since
  the button level is passed every cycle).

## Not covered here

- `Enable_Positive`/`Enable_Negative` default (`TRUE` in `FB_Axis`, no default i.e. `FALSE` in `Tc2_MC2.MC_Power`):
  every current caller assigns both, so the default affects no caller today; see BROTLib#9.
- The setpoint-enable error latch (BROTLib#61) and the `OR`/`AND` busy check (#55), already done.
