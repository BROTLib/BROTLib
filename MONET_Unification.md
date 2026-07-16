# MONETcommon / MONETN / MONETS Unification Plan

## Directive

MONETcommon and MONETS represent the current/target code. MONETN was forked from an
earlier snapshot of the same code and has drifted out of sync — where MONETN
diverges from MONETcommon, MONETcommon's version wins by default. A few specific
exceptions are called out below where MONETN's code is actually the more correct
or more complete one; those need to flow the other way (into MONETcommon) instead.

## Reality Check: Documented vs. Actual Dependencies

`STRUCTURE.md` shows both MONETN and MONETS depending on MONETcommon. That's true
for MONETS but not for MONETN:

| Repo | References MONETcommon? | How it gets MONETcommon's function blocks |
|------|--------------------------|--------------------------------------------|
| **MONETS** | Yes — `PlaceholderReference Include="MONETcommon"` in `MONETSRuntime.plcproj` | Consumes the library directly. MONETS's own project contains almost nothing beyond `MAIN.TcPOU`, site config, and two site-specific POUs. |
| **MONETN** | **No** — no `MONETcommon` reference anywhere in `MONETNRuntime.plcproj` | Vendored copies: 7 function blocks are duplicated verbatim (with local edits) inside `MONETN/MONETNRuntime/Components/` and `.../POUs/`. |

This is the root cause of the drift. MONETN never migrated to the MONETcommon
library — it kept its own fork of every FB and has been independently patched
since. Several of the duplicated FBs still share the exact same POU `Id` GUID as
their MONETcommon counterpart, confirming a common origin (Save-As style copy,
not independent authorship) — which also means most of these are safe content
swaps, not renames.

## File-by-File Comparison

| MONETcommon | MONETN | POU Id match? | Status | Action |
|---|---|:---:|---|---|
| `FB_MonetSafetyHandling` | `FB_SafetyHandling` | ✅ same | **Identical** (renamed only) | Delete MONETN copy, reference MONETcommon |
| `FB_MonetCabinetControl` | `FB_CabinetControl` | ✅ same | **Identical** (renamed only) | Delete MONETN copy, reference MONETcommon |
| `FB_MonetPowerMonitoring` | `FB_PowerMonitoring` | ✅ same | **Identical** (renamed only) | Delete MONETN copy, reference MONETcommon |
| `FB_MonetHydraulicsControl` | `FB_MonetHydraulicsControl` | — | **Byte-identical** | Delete MONETN copy, reference MONETcommon |
| `FB_MonetPendantControl` | `FB_MonetPendantControl` | — | **Byte-identical** | Delete MONETN copy, reference MONETcommon |
| `FB_MonetFocusControl` | `FB_MonetFocusControl` | ✅ same | **Diverged** — MONETcommon is a thin `EXTENDS FB_FocusControl` (HalfBROT), MONETN is a 211-line standalone pre-refactor reimplementation | Adopt MONETcommon's version |
| `FB_MonetTelescopeControl` | `FB_MonetTelescopeControl` | ✅ same | **Diverged**, non-trivially | See [dedicated section](#fb_monettelescopecontrol) below |
| *(none)* | `FB_MonetCoverControl` | — | **MONETN-only**, but MONETS's `MAIN.TcPOU` already calls a type of this exact name | **Bug**: promote into MONETcommon (see below) |
| *(none)* | `E_ModeLanguage.TcDUT` | — | **Byte-identical** to MONETS's copy, absent from MONETcommon | Move into MONETcommon |
| *(n/a)* | `FB_TelescopeAuxiliary`, `FB_WeatherCheck` | — | **MONETS-only** | Site-specific (Sutherland sensors/weather) — keep separate |

---

## 1. Trivial Unifications (delete-and-reference)

`FB_MonetSafetyHandling`/`FB_CabinetControl`/`FB_MonetPowerMonitoring` are
byte-identical to MONETcommon under a stripped `Monet` prefix — same POU Id, same
body, zero behavioral difference. `FB_MonetHydraulicsControl` and
`FB_MonetPendantControl` are fully byte-identical, no renaming even. All five are
pure copy-drift with no intentional divergence.

**Action per file:**
1. Delete the MONETN copy.
2. Add a `PlaceholderReference` to `MONETcommon` in `MONETNRuntime.plcproj` (see MONETS's `.plcproj` for the exact block to copy).
3. In MONETN's `MAIN.TcPOU`, rename the three renamed instantiations back to their MONETcommon names:
   - `FB_SafetyHandling` → `FB_MonetSafetyHandling`
   - `FB_CabinetControl` → `FB_MonetCabinetControl`
   - `FB_PowerMonitoring` → `FB_MonetPowerMonitoring`

Effort: trivial. Risk: none (verified byte-identical).

---

## 2. FB_MonetFocusControl

MONETcommon's version is nearly empty:

```st
FUNCTION_BLOCK FB_MonetFocusControl EXTENDS FB_FocusControl
```

All the real logic — `fMinPosition`/`fMaxPosition` clamping, homing position,
limit-switch properties (`InNegLimit`/`InPosLimit`), axis/calibration event
logging, MQTT telemetry (`SendTelemetry`) — lives in HalfBROT's `FB_FocusControl`,
which MONETcommon extends. (It even shares HalfBROT's `FB_FocusControl` POU Id,
`{27922653-...}` — likely an uncorrected Save-As artifact, harmless since it's a
different project namespace, but worth regenerating the Id on the next edit to
avoid confusion.)

MONETN's version predates that refactor: it `EXTENDS FB_BaseAxis IMPLEMENTS
I_Focus` directly and reimplements everything HalfBROT's `FB_FocusControl`
already provides — a duplicate of logic that now lives one layer down in the
dependency graph.

**Action:** Adopt MONETcommon's version. Once MONETN references MONETcommon (see
§1), `FB_MonetFocusControl` comes along automatically — just delete MONETN's
local copy. Site-specific tuning values (`fHomingPosition`, `fVelocity`, limit
positions) are passed as parameters from `MAIN.TcPOU`, not baked into the FB, so
no data is lost.

Effort: low (mechanical, once §1's library reference exists). Risk: low — the
HalfBROT base has been in production via MONETS.

---

## 3. FB_MonetCoverControl — a genuine gap, not just drift

This one is different from the others: **MONETcommon has no `FB_MonetCoverControl`
at all**, yet MONETS's `MAIN.TcPOU` instantiates one:

```st
CoverControl : FB_MonetCoverControl(comm := fbComm);
```

`FB_MonetCoverControl` is defined nowhere in MONETS's own project or in any
library it references (BROTLib, HalfBROT, AstroBROT, MONET_Roof, MONETcommon).
The only place this type exists in the entire org is MONETN's local copy. As
checked into source control, **MONETS's project cannot resolve this reference** —
it's presumably compiling today only because a stale/older MONETcommon library is
still installed in the TwinCAT library repository on the actual build machine,
outside of what's tracked in git.

HalfBROT does have a generic `FB_CoverControl implements I_MirrorCovers`, but
it's a different, timer-based sequencing algorithm (open/close ordering driven by
`TON` delays against limit switches) than MONETN's `FB_MonetCoverControl`, which
uses interlocked boolean chaining instead (close order 2→3→1, open order 1→3→2,
each stage gated on the previous stage's limit switches rather than a timer) — a
more deterministic sequencing model than HalfBROT's.

**Action:** Promote MONETN's `FB_MonetCoverControl` into MONETcommon as-is (name
already matches the `FB_Monet*` convention). This simultaneously:
- fixes MONETS's dangling/unresolved reference, and
- gives MONETN a shared copy to delete its local one in favor of.

Effort: low-medium (needs a compile-and-hardware-test pass on both N and S since
neither has verifiably built against a real `FB_MonetCoverControl` in
MONETcommon before). Risk: medium — this is the one place where "unify" means
*adding* new code to MONETcommon rather than just deleting a duplicate, so it
deserves real testing on both telescopes before rollout, not just a diff review.

---

## 4. E_ModeLanguage.TcDUT

Byte-identical `TYPE E_ModeLanguage : (Deutsch:=1, English:=2)` in both MONETN
and MONETS, absent from MONETcommon. Trivial move: add to MONETcommon, delete
both app-level copies.

Effort: trivial. Risk: none.

---

## 5. FB_MonetTelescopeControl

The big one — 1640 lines (MONETcommon) vs. 1564 (MONETN), same POU Id (confirmed
common origin), but real behavioral divergence in both directions. This is
**not** a safe blind copy-over.

### 5a. Where MONETcommon is ahead (adopt MONETcommon)

**Pointing model wiring.** MONETcommon declares `fbPointing`/`fbPointingInverse`
as `REFERENCE TO`, injected from `MAIN.TcPOU` with per-site calibration constants
— exactly the pattern MONETS's `MAIN.TcPOU` already uses. MONETN instead embeds a
`FB_PointingModelForward(...)` instance with hardcoded coefficients *inside*
`FB_MonetTelescopeControl` itself, plus a second, fully commented-out calibration
block (dead code) left over from a previous calibration run. MONETcommon's
injected-reference design is strictly more flexible (recalibrating means editing
`MAIN.TcPOU`, not the shared library).

**`fReadyState`.** MONETcommon implements the full state documented in
`STRUCTURE.md` (`-1`=error, `0.7`=powering, `0`=parked, `0.3`=parking, `1`=ready,
`-2`=other) with an `ELSE` branch. MONETN only sets three of the six values
(`1`, `-1`, `0`) and has **no `ELSE` branch**, meaning `fReadyState` can go stale
— e.g. while `bPark` is true but not yet parked, MONETN's `fReadyState` just
holds whatever value it had before, rather than reporting `0.3`.

### 5b. Where MONETN is ahead (port into MONETcommon, don't just discard)

**Azimuth/derotator wrap-around.** MONETcommon's *active* wrap logic is a
simple threshold check with no direction awareness:
```st
IF (fAzimuthCalc > 270.0) THEN ...
ELSIF (fAzimuthCalc < -274.0) THEN ...
```
Immediately below it, MONETcommon has a **commented-out** block implementing the
velocity-aware version — checks `fAzimuthVelocity`'s sign before deciding to wrap,
avoiding the axis spinning the long way around near the boundary. That
velocity-aware block is exactly what MONETN has **active**:
```st
IF (fAzimuthCalc > 310.0 AND fAzimuthVelocity > 0.0) OR (fAzimuthCalc > 440.0) THEN ...
ELSIF (fAzimuthCalc < 80.0 AND fAzimuthVelocity < 0.0) OR (fAzimuthCalc < -50.0) THEN ...
```
This is the one clear regression risk in blindly taking MONETcommon's file
wholesale: MONETcommon's checked-in "current" wrap logic is actually the older,
simpler algorithm, with the better one sitting dead in a comment. **Uncomment and
use MONETcommon's own commented-out velocity-aware block** (it already matches
MONETN's) rather than treating this as MONETN-specific code to port over.

### 5c. Needs a judgment call, not a mechanical pick

**`_PowerOn` staging style.** MONETcommon uses an explicit persistent
`CASE nStage OF 0/10/30/100` state machine that inlines a "move all three axes to
home position" stage directly inside `_PowerOn`. MONETN's `_PowerOn` is flatter —
no `nStage`, and once covers/axes are calibrated it just sets `bGoHome := TRUE`,
delegating the actual axis-move to the already-existing `_HomeTelescope`/GoHome
path instead of duplicating that logic inline. MONETN's approach avoids code
duplication between `_PowerOn` and `_HomeTelescope`; MONETcommon's staged
approach is more explicit/traceable. Neither is obviously wrong — recommend
picking one during implementation and testing the full power-on sequence on
hardware rather than assuming MONETcommon's version is automatically correct
just because it's the target baseline.

**MQTT topic naming.** MONETcommon publishes `POSITION.EQUATORIAL.RA_ICRS` /
`DEC_ICRS`; MONETN publishes `RA_J2000`/`DEC_J2000` (and drops `_ICRS` entirely
from the `OBJECT.EQUATORIAL.*` topics). These are different topic names, not just
a formatting nit — anything subscribed to MQTT/InfluxDB for either telescope
today depends on whichever naming is currently live. Confirm which naming
Grafana/Influx dashboards actually expect before standardizing, don't assume
MONETcommon's is deployed anywhere.

**Elevation homing velocity.** `5.0` deg/s in MONETcommon vs. `10.0` deg/s in
MONETN. Could be intentional per-site tuning (McDonald vs. a shared default) or
just drift — worth a one-line confirmation from whoever tunes these before
unifying, since getting it wrong risks a hardware homing move at the wrong speed.

Effort: high. Risk: medium-high — this file has diverged in both directions and
touches live telemetry topics and a hardware homing sequence. Recommend an
explicit test pass on both telescopes (or at minimum a simulator) after merging,
not just a code review.

---

## 6. Explicitly Out of Scope (keep separate)

- **`MAIN.TcPOU`** (both N and S) — per-site config (coordinates, calibration
  constants, hardware addressing, MQTT broker IP). Same pattern as IAG50cm's
  `MAIN.TcPOU` in the FB_Axis unification: not a library, stays app-specific.
- **`FB_TelescopeAuxiliary`, `FB_WeatherCheck`** — Sutherland-only sensors/weather
  polling, no MONETN equivalent, legitimately site-specific per `STRUCTURE.md`.
- **MQTT watchdog (30s timeout → auto-park + roof close)** — currently MONETS-only.
  Not a duplication problem to unify, but worth a follow-up decision on whether
  MONETN should adopt the same safety behavior — flagging, not recommending here.

## 7. Noticed in passing, separate issue

MONETN's `MAIN.TcPOU` calls `RoofControl(... min_position := 0, max_position :=
202 ...)`, while MONETS calls it with `max_position_1 := 205, max_position_2 :=
203` — a different parameter set entirely (single vs. two independently-tracked
roof halves). This means MONETN is wired against an older version of
`MONETRoof`'s interface than MONETS is. Not part of this MONETcommon/N/S
unification (MONETRoof is a fourth repo), but likely worth its own follow-up —
MONETN may not have been rebuilt against current MONETRoof recently.

---

## Priority Summary

| Priority | Item | Effort | Risk |
|----------|------|--------|------|
| **High** | Add MONETcommon library reference to MONETN | Trivial | None |
| **High** | Delete MONETN's byte-identical FB copies (§1) | Trivial | None |
| **High** | Promote `FB_MonetCoverControl` into MONETcommon (§3) | Low–Medium | Medium (fixes a currently-broken MONETS reference) |
| **Medium** | Adopt MONETcommon's `FB_MonetFocusControl` (§2) | Low | Low |
| **Medium** | Move `E_ModeLanguage.TcDUT` into MONETcommon (§4) | Trivial | None |
| **High** | Unify `FB_MonetTelescopeControl` (§5) | High | Medium–High |
| **Low** | Restore velocity-aware wrap logic in MONETcommon (§5b) | Trivial | Low (already written, just commented out) |
| **Low** | Investigate MONETN's stale `MONETRoof` interface (§7) | Low | Low (separate repo) |
| **None** | `MAIN.TcPOU`, `FB_TelescopeAuxiliary`, `FB_WeatherCheck`, MQTT watchdog | — | Keep separate / site-specific |

---

## Git Workflow

Same pattern as the FB_Axis unification: three separate repos, no cross-repo PR
mechanism, so this lands as three independent branches/PRs, merged in dependency
order (MONETcommon first, since both MONETN and MONETS consume it).

Current branch state (checked 2026-07-16):

| Repo | Default branch today | `develop` exists? |
|------|----------------------|--------------------|
| MONETcommon | `main` | No |
| MONETN | `main` (currently checked out on `develop`) | **Yes** — already has `develop` plus stale feature branches (`feature/telescope-state-machine`, `modularization`, `astrobrot`) |
| MONETS | `master` | No |

Steps, per repo:

1. **MONETS**: rename `master` → `main` locally and on the remote, update GitHub's default-branch setting, delete the old `master` branch on origin (MONETcommon and MONETN don't need this step — already on `main`).
2. **Fork `develop` from `main`** in MONETcommon and MONETS (MONETN already has one — check whether its existing `develop` is current or needs rebasing onto `main` first, and whether the stale feature branches there are abandoned work worth checking before this lands on top of them).
3. **Fork a feature branch from `develop`** in each repo for this unification work (e.g. `feature/monet-unification`), and implement that repo's piece there.
4. **Open a PR from the feature branch into `develop`** (not `main`) in each repo.

Recommended merge order: **MONETcommon → MONETS → MONETN.** MONETcommon first
because it's gaining new content (`FB_MonetCoverControl`, `E_ModeLanguage`) that
MONETS's `MAIN.TcPOU` already silently depends on — merging MONETcommon first
means MONETS's PR can actually compile clean against it. MONETN last since it's
the one gaining a new library reference and losing the most local code, so it
benefits from both of the others having landed and been sanity-checked first.
