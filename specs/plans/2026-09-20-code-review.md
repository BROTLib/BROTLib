# Code review of BROTLib (develop @ 93b17fe)

**Status: draft. Review finished; the body below describes `develop` at the review commit. Only M1 has been fixed so far. Since then generated build outputs stopped being tracked (`22cbc40`) and `BROTLibTests` (32 TcUnit cases for the pure functions, pointing model and `FB_BLINK`, `fd50848`, plus 8 for `FB_AstroClockSync`) was added; it passes on the user-mode runtime. M1 is fixed (see below). Nothing has been verified on a telescope. Open items: GitHub issues.**

Reviewed at `develop` 93b17fe. `origin/main` is 3 commits ahead of `develop` and `develop` is 1 commit
ahead of `main` (see M9).

Scope: all 58 source files under `BROTLib/BROTLib/` (POUs, DUTs, interfaces, GVLs; about 4000 lines
including XML), `.github/workflows/`, `README.md`, `STRUCTURE.md` and `TRACKING.md` (now `specs/design/repository-structure.md` and
`specs/design/telescope-position-tracking.md`), and the generated
`BROTLib.tmc`. Consumers were sampled, not reviewed: `FB_MonetTelescopeControl` (MONETcommon, MONETN),
`FB_TelescopeControl` (IAG50cm) and the `MAIN` programs, plus greps across all sibling repos for who uses what.

## How this was checked (and what that is worth)

- **Static read** of every source file.
- **Ports to Python** of the parts that can be checked without a PLC, in `testing/`:
  `check_tracking_functions.py` (velocity and derotator formulas against `erfa`/SOFA, pyerfa 2.0.1.5),
  `check_pointing_inversion.py`, `check_influx_and_logic.py`, `check_blink_horn.py`. They need `numpy`,
  and `pyerfa` for the first one.
- **Limit:** these test my port, not the compiled ST. A TwinCAT-specific behavior (what `LREAL_TO_STRING`
  prints, TOF timing, `FB_FormatString` on overflow, MC blocks, MQTT client internals) is not covered.
  Findings are marked **verified (port)**, **read from code**, or **unsure**.
- Anything about Beckhoff library behavior that I state from memory is marked as such. Check it before acting.

## Findings, worst first

### High

**H1. The MQTT command channel has no authentication, no TLS and no input validation.** *Read from code,
member names verified in `BROTLib.tmc`.*
`FB_Comm_MQTT` connects to a plain port (default 1883) and never sets the credential, TLS or last-will
members of `FB_IotMqttClient` (`sUserName`, `sUserPassword`, `stTLS`, `stWill` all exist in the generated
`.tmc`, none is used). `FB_Comm_MQTT_Influx._handleMQTTMessage` then executes whatever arrives on
`sTopicSub`: power, park, gohome, track, slew, stop, reset, dome and roof open/close, cover open/close,
focus, filter, and all offsets. Nothing checks who sent it. Everything runs at QoS 0, so a `stop` can be lost
without any signal.
- Values are not validated. `STRING_TO_LREAL` is used on the payload with no range, NaN or limit check
  (`focus` position, `azimuthoffset`, `elevationoffset`, ... are written straight through). Garbage text
  probably converts to 0 (*unsure, not checked*), which is a valid coordinate.
- `azimuthoffset` is later divided by `COS(elevation)` in the consumers, so a large offset near the zenith is
  amplified.
- Impact depends on the network. The brokers are on private ranges (STRUCTURE.md), so this is not a remote
  exploit by itself, but anyone on that network who can publish to the `.../SET` topic can move the telescope
  or open the roof. The hardware E-stop is unaffected.
- Fix: add username/password/TLS inputs to `FB_Comm_MQTT` and set them; set the last-will (see M3); restrict
  write access on the broker to the TCS client with an ACL; range-check every numeric command in one place;
  do not rely on MQTT for anything safety related.

### Medium

**M1. `FB_AstroClock` has no validity flag and mishandles errors.** *(#3: fixed on `develop` in 4dddb73 and the
unused `RTC`/`RTC_EX` blocks removed. `FB_AstroClockSync` syncs only after a successful read and drives the new
`bValid`/`nSyncErrors` outputs, covered by `FB_AstroClockSync_Tests`. IAG50cm, MONETcommon and MONETN hold the JD and
refuse goto/slew/track while `bValid` is FALSE. Time zone: `NT_GetTime` returns local Windows time, per the Beckhoff
docs; the production PCs are set to UTC, and this is now documented on the block and in the README. Not verified on a
telescope.)* *Read from code. Magnitudes computed,
not measured.* It is the only time source for pointing and tracking (MONETcommon, MONETN and IAG50cm all call
`fJd := DateTime2JD(fbTime.time_RTCEX2)` unconditionally).
- The three RTC blocks only start after the first sync. `syncTimer` has `PT := T#5S`, so the first sync
  happens 5 s or more after start. Until then `time_RTCEX2` is zero and the JD is garbage. No output tells
  the caller whether the time is valid.
- `syncTrigger(CLK := bBusy AND NOT bError)` detects the falling edge of "busy and not error". When
  `NT_GetTime` finishes with an error, `bError` rises as `bBusy` falls, so the falling edge fires and the RTCs
  are loaded from `presetTime`, which was not updated (stale, or zero on the first call). A stale value is
  5 s or more old, which is 75" or more of RA (15.04"/s). The check must be done at the moment busy falls.
- `NT_GetTime` returns the local time of the target, as far as I remember the Beckhoff docs (**unsure, check**).
  `DateTime2JD` needs UTC (AstroBROT review, L6). Nothing in BROTLib converts or checks the time zone. Since
  tracking works in operation, the PLC clocks are probably set to UTC, but nothing enforces it.
- README calls this "sub-millisecond synchronisation". It resyncs every 5 s over ADS and copies whatever the
  service returns. It also runs `RTC`, `RTC_EX` and `RTC_EX2` side by side, and only the last is used.

**M2. Influx line-protocol typing loses data.** *Verified (port) for the string logic; what `LREAL_TO_STRING`
prints is from memory.* Every telemetry value is converted to a string and re-classified in `Publish` by
`F_IsNumericValue` and "has no `.`, so append `i`".
- The same field flips between integer and float depending on its value. `LREAL_TO_STRING(15.0)` prints `15`
  (from memory), so it is sent as `15i`, and `15.5` as a float. InfluxDB rejects a point whose type differs
  from the one it already holds for that field (documented behavior, not tested against a server).
- `F_IsNumericValue` accepts exponents, but `Publish` only looks for `.`. `1e5` and `1E-05` become `1e5i`,
  which is invalid line protocol. Verified (port).
- Lines longer than 255 characters overflow `sPayloadPub`. `bError`/`nErrID` from `FB_FormatString` are
  read into locals and ignored, and the (truncated) line is published anyway. With host `CX-4E6032` and level
  `WARNING`, a log message longer than 212 characters (after escaping) no longer fits. What `FB_FormatString`
  does on overflow is *unsure*.
- Tag values (`domain`, `location`, `HostName`, `level`) are not escaped. A space, comma or `=` in the host
  name breaks the line.
- Fix: decide the type at the call site (`PublishLREAL`, `PublishBOOL`, `PublishString`, or a typed argument)
  instead of guessing from the text. That removes the whole classification block.

**M3. Delivery semantics are weak and silent.** *Read from code.*
- `bQueue := FALSE`, and the caller ignores `published`. When the client cannot send, the message is
  dropped. `_PublishTelemetry` sends about 33 messages in one PLC cycle, each with its own `FB_FormatString`,
  so it is exactly the kind of burst that fails first. Cycle-time cost is unmeasured.
- The method return value of `Publish` is never assigned (only the `published` output is), so `Publish`
  always returns FALSE.
- Boolean values are sent with `bRetain := TRUE`. The lines carry no timestamp. When Telegraf restarts, the
  broker replays every retained boolean and the values are stored as fresh data, even if the PLC has been
  dead for hours. *Inference from the retain semantics and the missing timestamp, not tested.*
- No last-will message, so consumers cannot tell that the PLC is gone.
- `sClientId := HostName`. Two PLCs with the same host name (a cloned image) disconnect each other in a loop.
- If `FB_GetHostName` fails, state 0 never leaves and nothing reports it.
- `sent : INT` counts every publish and wraps after 32767 (about 16 minutes at 33 messages/s). It is not used.

**M4. Coordinates and commands arrive as separate messages with persistent buffers.** *Read from code.*
`rightascension`, `declination`, `elevation`, `azimuth` fill a buffer, and `track` or `slew` consumes it.
- With QoS 0 and no acknowledgement, a lost RA message plus a stale RA from an earlier, aborted sequence can
  produce a target that mixes two objects. The buffers are only reset by `track`/`slew`.
- An incomplete pair is dropped silently. There is no reply, no log line, no error.
- `power` with any value other than 1 or 2 does nothing (there is no power-off), also silently. `derotator`
  and `derotatoroffset` are two names for the same action. `gohome` calls `Telescope.Home()`, which is an
  empty method in `FB_BaseTelescopeControl` (see M8).
- Fix: one message per command with all arguments, plus an acknowledgement or error on the log topic.

**M5. Unassigned interface references crash the PLC.** *Read from code, not run.*
`fbComm` in `FB_BaseTelescopeControl` and `FB_BaseAxis` is only set through `FB_Init(comm := ...)`, and
`Comm` in `FB_EventLog` is a plain input. None of them is checked before use (`fbComm.Publish(...)` in the
telescope base, `Comm.PublishLog(...)` in the event log, and whatever the axis subclasses do with `fbComm`). In TwinCAT a call through an unassigned interface pointer raises a runtime exception
and stops the task. `FB_Comm_MQTT_Influx` does check its own references with `<> 0`, so the pattern is known.
`FB_PointingModelInversion.fbPointing` (a `REFERENCE TO`) has the same problem (`__ISVALIDREF` is not used).
The MONETN and MONETS `MAIN` programs pass `comm` correctly, so this is a hazard for the next consumer,
not a current fault.

**M6. `FB_Axis2` does not do what TRACKING.md says it does.** *Read from code.*
TRACKING.md says tracking "sends both position and velocity to the NC axis controllers". In `FB_Axis2`,
`TrackVelocity := 0.0` and `TrackAcceleration := 0.0` always (the real expressions are commented out), so
the `Velocity` input is ignored while tracking, even though the consumers compute and write it every cycle.
- The set point is `ActualPosition + LIMIT(Position - ActualPosition, -0.002, 0.002)`, so it is built from the
  measured position each cycle, not from the previous set point. Encoder noise goes straight into the
  set point, and there is no feed-forward. Whether this is a problem is a matter of loop tuning; it may be
  deliberate. It should be written down, and the doc corrected.
- `MC_ExtSetPointGenFeed` is called every cycle, also when the generator is not enabled.
  *Unsure whether that is harmless.*
- `PositionDifference` keeps a stale value when `Tracking` is FALSE.

**M7. `FB_Axis2` latches and mutates its own inputs.** *Read from code.*
- `Axis_SetpointEnable.Execute` is set while tracking and only cleared when `NOT Busy AND Done`. After an
  error, `Done` is FALSE and `Busy` is FALSE, so `Execute` stays TRUE, the error output stays set (MC blocks
  clear it when `Execute` falls), and re-enabling needs a rising edge that cannot happen. `Axis_Reset` does
  not touch this block.
- `Calibrated` is set on `HomeDone` and never cleared. After an NC error or a lost reference it still reports
  TRUE. It does not read the NC's own homed flag.
- `Axis_Home` uses `Position := position`, the move target, as the reference position. Homing while a stale
  target is in `Position` calibrates the axis to that value. The commented `//DEFAULT_HOME_POSITION` shows a
  constant used to be there.
- `MoveAxis`, `HomeAxis`, `StopAxis`, `Jog_Forward`, `Jog_Backwards` are `VAR_INPUT` and are written by the
  block itself. A caller that assigns them in the call parameter list fights the block every cycle. Same
  pattern as AstroBROT M1.
- `Enable_Positive` and `Enable_Negative` default to TRUE, so an unwired limit switch means "no limit".
  `MC_Power` itself defaults them to FALSE, as far as I remember (*unsure*).
- `IF MoveDone AND (NOT Axis_Modulo.Busy OR NOT Axis_Move.Busy)` should be `AND`. It works only because one
  of the two blocks is never executed.

**M8. `FB_BaseTelescopeControl` and `FB_RaDecTelescopeControl` are unfinished.** *Read from code; usage
verified by grep over all sibling repos.*
- `fJd`, `fLst` and `fbTime` are declared in the base class, but the base never calls `fbTime` or assigns
  `fJd`/`fLst`. Every consumer does it itself. The base still publishes `POSITION.LOCAL.JD` and
  `SIDEREAL_TIME`, which are 0 unless the derived class fills them.
- `FB_RaDecTelescopeControl` uses `fJD` (never set), reads `fRightAscensionCurrent` and `fDeclinationCurrent`
  (never set), sets `fHourAngleCalc := 0.0` and overwrites it, and has the pointing and velocity code
  commented out (the commented lines name functions that do not exist). Its `hor2eq` call omits `refract_to_observed`, so it
  gets the AstroBROT default `TRUE`, which is the wrong direction for a measured altitude (AstroBROT H3).
  **No sibling repo uses it** (0 files). README says it is "used by IAG50cm"; IAG50cm has its own
  `FB_TelescopeControl`.
- `Home()` is an empty method with a `{warning 'add method implementation '}` pragma (the recent commit
  removed the others). It is reachable from the MQTT `gohome` command.
- `bEstopTriggered` (`// TODO: CHANGE`, default FALSE) is copied into IAG50cm as well. No `MAIN` in the sibling
  repos assigns it (it could be linked in the `.tsproj`; I did not check). If unlinked, `STATUS.GLOBAL = 1`
  (E-stop) is never published.
- Both `FB_AltAzTelescopeControl` and `FB_RaDecTelescopeControl` declare `VAR PERSISTENT` pointing
  coefficients (`EOFF`, `AN_E`, ...) that nothing reads (`FB_PointingModelForward` has its own copies).
  Whether `PERSISTENT` inside a function block persists per instance is *unsure*. The comments of `AN_E`
  and `AN_A` are identical.

**M9. The next release will fail half way, because `main` has diverged from `develop`.** *Read from code,
divergence verified with `git rev-list`.* `origin/main` has 3 commits `develop` lacks
(`b120547`, `e568a83`, `dab5f84`) and `develop` has 1 that `main` lacks (`93b17fe`). `release.yml` pushes the
version bump to `develop`, then runs `git merge --ff-only develop` on `main`. That cannot succeed, so the job
stops with the bump already on `develop`, `main` not updated and no tag. `main` also has a second TcBuild
workflow (`tcbuild-service-test.yml`, with the shared runner labels) that `develop` lacks, while
`tcbuild-test.yml` is the same on both and still has the old `test` label. Merge `main` into `develop` before releasing. I did not run the workflow.
Same problem as AstroBROT M8.

**M10. `FB_InfoConnection` decodes the FSoE diagnostic byte wrongly.** *Verified (port).* The code tests bits
in an `ELSIF` chain, but the combined cases are placed after the single-bit tests, so they can never be
reached. Assuming the byte holds the numeric FSoE code (the order of the strings matches values 1 to 11 as bit
patterns, *check against the Beckhoff EL1904/EL6900 documentation*), 7 of 11 codes decode to the wrong text:
3, 5, 6, 7, 9, 10, 11 show as "Invalid Command" or "Unknown Command". It is used by the safety handling blocks
of MONETN, MONETcommon and IAG50cm, so this is what an engineer reads while debugging a safety fault. Fix: `CASE` on the value. `FB_InfoEStop` reports only the first set bit, which is a smaller issue.

**M11. No tests, and no way to run any.** There is no test project, no TcUnit reference and no CI step that
runs code. The only CI is the manual TcBuild compile job. The numeric parts are correct where I checked them
(see Design assessment), but that is because I checked them, not because the repository does.

### Low

- **L1. `FB_Horn` never pauses.** `PAUSE` is declared but never called, so `IMPULS` restarts itself each cycle.
  *Verified (port):* `beep` gives 510 ms on, 10 ms off, repeating forever; `short` gives 3 s on, 10 ms off;
  `long` 5 s on, 10 ms off. The enum names suggest one-shot signals. No sibling repo uses `FB_Horn` or
  `E_Horn`. (`FB_BLINK` looked suspicious but simulates correctly, 500/500 gives 510/520 ms, because the second
  block sees the updated output of the first. That works only through call order, which is fragile.)
- **L2. `F_YREAL` with an inverted output range returns a constant.** `LIMIT(fYmin, y, fYmax)` with
  `fYmin > fYmax` gives `fYmax`. *Verified (port):* mapping 0.25 on [0,1] to [1,0] returns 0 instead of 0.75
  with `cut = TRUE`. It returns 0 silently when `fXmax = fXmin`, takes `REAL` limits for an `LREAL` input
  (precision loss), and the comment block has delta X and delta Y swapped. README calls it a "REAL formatting
  helper".
- **L3. Tracking functions.** *Verified (port) unless noted.*
  - `F_Azimuthvelocity`, `F_Elevationvelocity` and `F_Derotatorvelocity` match a numerical derivative of the
    erfa HA/Dec to Az/El transform to 3e-10 deg/s, and the parallactic angle in `F_DerotatorPosition2` equals
    `erfa.hd2pa` to 2e-12 deg. These are correct.
  - `F_DerotatorPosition2` takes `sign`, `F_Derotatorvelocity` does not. For `sign = -1` the velocity is off
    by up to 5.2e-3 deg/s (more than the sidereal rate of 4.2e-3). All consumers use `+1`, so it is latent.
  - The `declination` input of `F_DerotatorPosition2` is clamped into a local (`de`) and never used. `el` is
    clamped for the trigonometry but the raw `elevation` is used in the final line.
  - Argument order differs: `F_DerotatorPosition2(azimuth, elevation, ...)` but
    `F_Derotatorvelocity(elevation, azimuth, ...)`. Consumers get it right today.
  - At `cos(el) <= 1e-3` (el > 89.943 deg) the velocity functions return 0 where the true azimuth rate is
    about 1.75 deg/s (lat 51.56, az 45). The consumers stop tracking at 89.5 deg, so unreachable in practice.
- **L4. `FB_PointingModelInversion`.** *Verified (port).* With the MONETN coefficients from TRACKING.md the
  fixed-point iteration converges to under 0.1" in 2 passes at every elevation tried (30 to 85 deg, worst
  azimuth), and the residual after the 11 passes is 0.000". It runs the forward model 11 times per cycle per
  instance for no gain. The forward model itself is singular at the zenith: with those coefficients the
  azimuth offset is 7.5 deg at 89.5 deg elevation, and it is clamped to 37 deg above 89.9 deg. No guard
  exists inside the library. The README says "8-term" model; the code has 9 terms.
- **L5. `FB_EventLog`.** Level is compared with `=` against the raw ADS constants, so a combined flag value
  reads as "ERROR". `LEN(...)>0` decides the ADS log but `LEN(...)>1` decides the MQTT log, so a one
  character message is only logged locally. It writes to its own `OffLevel` input.
- **L6. Constants copy-pasted.** `Omega = 4.178074605556E-3` in three functions, plus
  `fSiderialVelocity = 360/86164.099` in the base class (differs by 1e-7, about 0.0015" per hour, harmless),
  and `d2r` declared in seven places. `GVL_Math` holds only `LREAL_MIN`.
- **L7. `FB_BaseAxis`.** `InNegLimit` and `InPosLimit` have empty getters and return FALSE (the safe-looking
  value) unless a derived block overrides them. `Calibrated` returns `bCalibrated` but `Busy` returns
  `fbAxis.Busy`, and the body is empty, so `fbAxis` is never called in the base. Every axis has two ways to
  be commanded (the `bXxx` inputs and the properties), and `Reset()` sets `bReset := TRUE` with nothing that
  clears it.
- **L8. `MAIN` in a library.** It instantiates `FB_Comm_MQTT_Influx` with an empty host name and port 0. It is
  harmless while `PlcTask` is not activated from this project, but it is confusing next to the "library only"
  description.
- **L9. Telemetry content.** *Unsure, check against the TCS spec.* `OBJECT.INSTRUMENTAL.RA` is published in
  degrees and `OBJECT.EQUATORIAL.RA` in hours (`/15`). `EQUATORIAL.EPOCH/EQUINOX` are hard-coded `J2000.0`
  while the input is documented as "apparent right ascension". `CAPABILITIES` is hard-coded `0`. The static
  `INFO`/`CONFIG` fields (7 messages) are republished every 1 to 5 s. The comment says "every second" but the
  idle interval is 5 s.
- **L10. Unused things.** `E_TCSErrors` (0 uses anywhere), `FB_Horn`/`E_Horn` (0), `FB_LightTimer` (0),
  `FB_RaDecTelescopeControl` (0), and several base-class variables (`TCS_command`, `tonCommandTimeout`,
  `nStatusWord`, the `TCS*Event` blocks) that only consumers touch. The references to `Tc3_IotCommunicator`
  and `Tc3_Module` have no symbol I could find by grep (*unsure, remove and build to confirm*).
  `NCError_TO_STRING` knows 16 codes and two of them are states ("no error"); I did not check the texts
  against Beckhoff's list.
- **L11. `FB_InfluxMessage`** keeps the quotes of a string value, ignores a trailing timestamp, and
  `sPayloadRcv` in `FB_Comm_MQTT` is a plain `STRING` (80 characters) while the handler takes `STRING(255)`,
  so longer messages are cut. Harmless for today's short commands.

## Security

- **S1 (High). See H1.** Unauthenticated command channel.
- **S2 (Low). Script injection in `release.yml`.** The "Validate version format" step interpolates
  `${{ inputs.version }}` into the shell before the regex runs, so a `$(...)` payload executes first. Only
  users who can dispatch the workflow (write access, `contents: write`) can use it. Fix: pass it through
  `env:`. Same as AstroBROT S1.
- **S3 (Low to Medium). The release job pushes to `develop` and `main` and tags with no build or test gate.**
  `main` is not protected (GitHub API returns 404 for branch protection). `actions/checkout@v4` is pinned by
  tag, not commit SHA. Nothing produces a `.library` artifact, so the tag says nothing about whether the
  library compiles.
- **S4 (Low). The repository is public** (`gh repo view`: `PUBLIC`) and discloses some internals.
  - STRUCTURE.md lists two MQTT broker addresses with port (`169.254.146.10:1883`, `192.168.127.10:1883`).
    Both are non-routable ranges, but they name the command topics too.
  - `FB_BaseTelescopeControl.TcPOU` links a private GitLab snippet (`gitlab.aip.de/bmk10k/...`).
  - `BROTLib.project.~u` is tracked although `.gitignore` lists `*.~u`. It holds a machine and user name
    (`BECKY`, `Default User`). `git rm --cached` fixes it. The generated `BROTLib.tmc` is tracked too.
  - No credentials, tokens or keys in the text files (grep for password, secret, token, API key, AmsNetId,
    IP addresses). I did not open binary files; there are none tracked beyond the XML.
- **S5 (Low, watch). A self-hosted runner on a public repository.** `tcbuild-test.yml` is
  `workflow_dispatch` only, which is the safe setting (the runner doc says PR triggers were removed for this
  reason). If a `pull_request` trigger is added later, forks can run code on that runner.

## Design assessment

1. **The "core library" is mostly a shared variable set.** The telescope command state machine is
   `FB_MonetTelescopeControl` in MONETcommon (about 1400 lines), a second copy in MONETN (about 1300) and a
   third in IAG50cm's `FB_TelescopeControl` (about 1800), counted as XML lines before the line-id block. BROTLib's base class holds the inputs, outputs and helper
   variables those copies use, and the telemetry method. README says BROTLib provides "the command/state
   layer" and a "command-priority dispatcher"; it does not, since the state machine was removed (commit
   736cff3). This is the largest maintainability problem in the ecosystem, and the unification docs already
   say so. Until it is fixed, README should say what the base class is.
2. **`FB_Comm_MQTT_Influx` does transport, protocol, dispatch and formatting in one block.** The dispatch is a
   30-branch `ELSIF` ladder over strings, the telemetry API takes `(domain, location, 'DOTTED.NAME', string)`,
   and typing is recovered afterwards from the text (M2). A typed publish API, a command table or one method
   per command, and a validation step would remove M2 and most of M4. The `I_Comm` interface is the right
   seam.
3. **Inputs are written by the block that owns them** (`FB_Axis2`, `FB_EventLog`), the same pattern as
   AstroBROT M1. Commands should be methods or edge-triggered inputs that the block clears.
4. **Two sources for the same numbers.** Pointing coefficients live in `FB_PointingModelForward`, in the
   `PERSISTENT` variables of both telescope classes, and in the consumers' calibration. Only the first is
   connected to anything.
5. **Interfaces are the good part.** `I_Comm` injection through `FB_Init`, the `I_Telescope`/`I_Axis` split, and
   null checks on the optional subsystems in the command handler make consumers easy to assemble. The
   reconnect logic in `FB_Comm_MQTT` (state 3 back to state 1) is correct as far as I can tell. Escaping of
   string fields (`F_EscapeInfluxString`) exists and handles `"` and `\`.
6. **The math that exists is accurate.** Velocity and derotator formulas match numerical derivatives to
   3e-10 deg/s, the parallactic angle matches SOFA to 2e-12 deg, and the inversion converges. The weak parts
   are time handling, error paths, defaults and communication, not the astronomy.
7. **Documentation has drifted from the code.** README lists files that do not exist (`UNIFICATION.md`,
   `MONET_Unification.md`, `FB_Axis.md`, `specs/adrs/`, a `_Libraries/` folder), an old CI (`build.ps1`,
   `build.yml`, `test_errors.TcPOU`), tags up to `v0.4.1` (current version is 0.4.2), says
   `FB_ButtonEnable` is a debouncer (it is a toggle), `FB_PointingModelForward` produces tracking velocities
   (it does not), and that `FB_RaDecTelescopeControl` is used by IAG50cm (it is not). README also contradicts
   itself on the state machine. TRACKING.md describes consumer code, not BROTLib, and M6 above.

## CI and release

Investigated 2026-09-20 with `gh`. The compile check exists but is not part of the release.
- `tcbuild-test.yml` (`workflow_dispatch` only) builds `BROTLib.sln` with TcBuild. On both branches it still
  asks for the extra `test` runner label. `main` also has `tcbuild-service-test.yml` with the shared org-level
  labels (`self-hosted, twincat, windows`), which is the one that ran on 2026-09-16.
- The last six runs of the service-mode workflow on `main` (2026-09-16): 3 success, 3 failure. The runner
  doc lists flakiness as a known problem (also noted in the AstroBROT review).
- Nothing runs tests. TcBuild does not run tests (per its README, see the AstroBROT review). The options for
  numeric tests there (golden vectors, PLC-side runs, TcUnit-Runner being archived) apply here too.
- Recommendation: merge `main` into `develop` (M9), make the release job depend on a TcBuild run, upload the
  `.library` as an artifact, and pin actions by SHA.

## Suggested order of work

1. H1: credentials/TLS/last-will inputs, a broker ACL, and one range-check function for numeric commands.
   M5 (null checks) and M9 (merge `main` into `develop`) are small and independent.
2. M1 (validity flag, error edge, UTC check), M2 and M3 (typed publish, check `bError`, stop retaining
   booleans, last-will). Those change what lands in InfluxDB, so check dashboards afterwards.
3. M7 and M6 (axis latch after error, home position, `Calibrated`), together with a decision on whether
   tracking should feed velocity. Needs hardware testing.
4. M10 (`CASE` in `FB_InfoConnection`), M4 (one message per command with an acknowledgement).
5. Decide the future of `FB_BaseTelescopeControl`: either move the state machine in (the unification plan) or
   trim the base class and README to what it does. Delete or finish `FB_RaDecTelescopeControl` (M8).
6. Tests (M11): golden vectors for the tracking functions, and a `FB_Comm_MQTT_Influx` test with a fake
   `I_Comm`.
7. Repo hygiene: S2 to S4, README refresh, remove `FB_Horn`/`E_TCSErrors` or fix them.
