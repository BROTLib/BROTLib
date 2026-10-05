# FB_Axis latching and self-mutation fixes (BROTLib#9)

**Status: proposed.** Nothing implemented. Covers #9's six findings, re-verified against the
merged `FB_Axis` (post `FB_Axis2`+`FB_Axis3` unification, `349617e`) rather than the now-deleted
`FB_Axis2` the issue was originally filed against — only one of the six turned out to be fixed by
that merge as a side effect. See also `specs/plans/2026-09-23-multi-field-influx-message-parsing.md`
and the axis-unification plans for the surrounding context; this plan is scoped to `FB_Axis` only.

## Findings, re-verified against the current `FB_Axis.TcPOU`

| # | Finding | Status post-merge |
|---|---|---|
| 1 | `Axis_SetpointEnable.Execute` latches TRUE after an error; `Axis_Reset` doesn't touch it | **still live** |
| 2 | `Calibrated` never cleared, doesn't read the NC's own homed flag | **fixed** (merge adopted `FB_Axis3`'s continuous-homing check) |
| 3 | `Axis_Home` uses the move target (`Position`) as the homing reference position | **still live** |
| 4 | Self-mutating `VAR_INPUT`s (`MoveAxis`/`HomeAxis`/`StopAxis`/`Jog_Forward`/`Jog_Backwards`) | **still live**, design question not a mechanical bug |
| 5 | `Enable_Positive`/`Enable_Negative` default `TRUE`; `MC_Power`'s own default is unclear | **still live**, unverified against Beckhoff's actual default |
| 6 | `IF MoveDone AND (NOT Axis_Modulo.Busy OR NOT Axis_Move.Busy)` — `OR` only "works" because one side is always inactive | **still live** |

Finding 2 needed no further action. The rest are addressed below.

## 1. `Axis_SetpointEnable.Execute` latch

Current:

```st
IF Tracking AND Ready AND Calibrated AND NOT StopAxis THEN
	Axis_SetpointEnable.Execute := TRUE;
ELSIF NOT Axis_SetpointEnable.Busy AND Axis_SetpointEnable.Done THEN
	Axis_SetpointEnable.Execute := FALSE;
END_IF
```

After an error, `Busy` and `Done` both go FALSE (per the MC block's own error contract), so neither
branch fires and `Execute` holds whatever it was — permanently TRUE if it was TRUE when the error
hit, mid-track. `Axis_Reset` (`MC_Reset`, a separate FB instance entirely) never references
`Axis_SetpointEnable` at all.

**Fix**: also clear `Execute` on error, and let a reset re-arm it:

```st
IF Tracking AND Ready AND Calibrated AND NOT StopAxis AND NOT Error THEN
	Axis_SetpointEnable.Execute := TRUE;
ELSIF (NOT Axis_SetpointEnable.Busy AND Axis_SetpointEnable.Done) OR Axis_SetpointEnable.Error THEN
	Axis_SetpointEnable.Execute := FALSE;
END_IF
```

`Error` here is the FB's own aggregate output (computed later in the same cycle from all the
`Axis_*.Error` sub-outputs, `Axis_SetpointEnable.Error` included) — using it directly instead of
the aggregate avoids a one-cycle lag if the aggregate hasn't been recomputed yet this scan; check
execution order in the body before deciding which to reference. Needs a TcUnit test that drives an
error mid-track and confirms `Execute` drops and can re-latch after `Reset`.

## 2. `Axis_Home` reference position

Current: `Axis_Home(..., Position := position, ...)` — `position` is case-insensitively the same
variable as the `Position` VAR_INPUT (the move target), with a dead `//DEFAULT_HOME_POSITION`
comment next to it suggesting a constant used to be there.

**Fix options**, needs a decision (not purely mechanical — depends on what callers actually expect):
- Add a dedicated `HomePosition : LREAL` input, defaulting to `0.0`, and use that instead of
  `Position`. Every current caller would need to either accept the new default or start passing an
  explicit home position — check call sites in HalfBROT/IAG50cm/MONETcommon/MONETN before deciding
  the default is safe.
- Or: confirm whether `Position := position` was ever intentional (e.g. "home to wherever the last
  commanded move target was") — seems unlikely given the dead `DEFAULT_HOME_POSITION` comment, but
  worth ruling out before assuming it's purely a leftover bug.

## 3. Self-mutating `VAR_INPUT`s

`MoveAxis`/`HomeAxis`/`StopAxis`/`Jog_Forward`/`Jog_Backwards` are declared `VAR_INPUT` but the
block clears them itself once the corresponding `*Done` fires (`MoveAxis := FALSE;` etc.). A caller
that assigns these via the instance's call parameter list every cycle (`fbAxis(MoveAxis := bMove,
...)`) fights the block: the caller's own value from this scan overwrites whatever the block just
cleared, on the same scan, before the next cycle. A caller that instead sets the field directly
once (`fbAxis.MoveAxis := TRUE;` outside the call) and lets the block clear it does not have this
problem — check which pattern current consumers actually use before assuming this is live.

**Not a mechanical fix.** A real fix is an API change: split each into a rising-edge `Execute`
input plus a `Done` output, matching how the underlying `MC_*` blocks themselves already work, so
"is this still commanded" and "did it finish" aren't conflated in one bidirectionally-written
variable. That's a breaking signature change across every consumer of `FB_Axis` — same class of
change as the `FB_Axis2`/`FB_Axis3` merge itself, so it should go through the same kind of
survey-then-migrate process (see `specs/design/iag50cm-fb-axis-comparison.md` for the precedent),
not get bundled into this plan's mechanical fixes.

**Recommendation for this plan**: document the gotcha (a comment on each affected input, and a note
in `specs/design/`) rather than attempt the API redesign here.

## 4. `Enable_Positive`/`Enable_Negative` default

Declared `BOOL := TRUE` (meaning: no limit-switch-driven restriction by default). The issue's
"`MC_Power` itself defaults them to FALSE, as far as I remember" claim could not be confirmed —
checked Beckhoff's own `MC_Power` reference page and it doesn't state a default for either
parameter, and a general web search didn't turn up a definitive answer either. **Open question,
not resolved by this plan.**

If `MC_Power`'s own default really is FALSE (meaning: unless something wires it, motion is
disabled in both directions), then `FB_Axis`'s override to TRUE is a deliberate, documented choice
("unwired limit switch means no limit") that should probably get an explicit comment explaining why
that's the intended safe default here, rather than silently overriding whatever `MC_Power` would
otherwise do. If `MC_Power` also defaults TRUE, there's nothing to fix, just confirm and drop this
finding.

**Next step**: check `MC_Power`'s actual declaration (TwinCAT XAE intellisense/object browser, or a
support request) rather than continue guessing from search results.

## 5. `MoveDone AND (NOT Axis_Modulo.Busy OR NOT Axis_Move.Busy)`

Confirmed: `isModuloAxis` gates which of `Axis_Modulo`/`Axis_Move` ever executes (only one
`Execute` condition is ever true), so the other's `.Busy` is permanently FALSE — satisfying the
`OR` unconditionally regardless of whether the *active* one is still busy. Verified this doesn't
currently cause visible harm because `MoveDone` and the active block's `Busy` normally fall
together per the `MC_MoveAbsolute`/`MC_MoveModulo` done/busy contract, but relying on that timing
coincidence via a semantically-wrong `OR` is fragile — a version bump or edge case in the MC block
implementation could desync them.

**Fix**: change to the semantically-correct check, gated on which block is actually active instead
of using the "OR of two conditions where one is a decoy":

```st
IF MoveDone AND ((isModuloAxis AND NOT Axis_Modulo.Busy) OR (NOT isModuloAxis AND NOT Axis_Move.Busy)) THEN
	MoveAxis := FALSE;
END_IF
```

Equivalent to the issue's suggested plain `AND` (`NOT Axis_Modulo.Busy AND NOT Axis_Move.Busy`)
given the permanently-FALSE-when-inactive property already established, but reads more honestly
about *why* it's correct instead of relying on that property implicitly. Needs a TcUnit case
confirming behavior is unchanged for both `isModuloAxis := TRUE` and `FALSE` axes.

## Sequencing

1. **Safe, mechanical**: #5 (the `OR`/`AND` fix) — pure logic correction, no interface/behavior
   change once verified. Lowest risk, do first.
2. **Needs Beckhoff confirmation first**: #4 (`Enable_Positive`/`Enable_Negative` default) — either
   confirm harmless and close, or add the explanatory comment once `MC_Power`'s real default is
   known.
3. **Needs care, real behavior change**: #1 (`Axis_SetpointEnable.Execute` latch) and #2 (`Axis_Home`
   reference position) — both are genuine bug fixes changing what the axis actually does in an
   error/homing scenario respectively. Write TcUnit coverage for each before merging; #2 also needs
   the call-site survey before picking a default.
4. **Separate, bigger effort, not in this plan**: #3 (self-mutating inputs) — an API redesign
   requiring the same survey-then-migrate process as the `FB_Axis2`/`FB_Axis3` merge itself.

## Tests

- TcUnit (BROTLibTests): extend `FB_Axis`'s test coverage (check what exists today, if anything)
  with: an error injected mid-track confirming `Axis_SetpointEnable.Execute` drops and can
  re-latch after `Reset` (#1); the `MoveDone`/busy-check fix behavior for both modulo and
  non-modulo axes (#5).
- #2 and #4 aren't independently testable in TcUnit without simulating real NC axis behavior —
  note as "not testable here" per the existing convention in other BROTLib test suites, verify on
  hardware/simulation instead.

## Not in this plan

- The self-mutating `VAR_INPUT` API redesign (#3) — flagged for its own future plan once someone
  wants to take it on, given the cross-repo migration cost.
- Anything about `FB_BaseAxis`'s own known gaps (`InNegLimit`/`InPosLimit`, already handled in #20).
