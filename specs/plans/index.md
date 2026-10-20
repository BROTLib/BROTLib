# Plans

Dated `YYYY-MM-DD-<slug>.md` investigation and work logs, one per unit of work. Moved here from
IAG's specs 2026-09-20 (generic content, no IAG-private infrastructure/credential/incident details).

- [2026-09-15-twincat-ci-investigation.md](2026-09-15-twincat-ci-investigation.md) —
  TcBuild (run locally, not remotely) as a possible path to real CI (automated build/test, plus
  a live version GVL stamped from git as a secondary win) for the custom TwinCAT libraries; prior
  remote-XAE runner attempt failed on VS automation-interface gaps (why `ironplc` work exists).
  **proposed** — blocked on a dedicated Windows machine
- [2026-09-21-typed-influx-publishers.md](2026-09-21-typed-influx-publishers.md) —
  typed Influx publishers (`PublishLREAL`/`INT`/`BOOL`/`String`) to fix the integer/float flip left open in
  BROTLib#4: survey of about 550 call sites, the constraint of the field types already in InfluxDB, phased migration.
  **proposed**, nothing implemented
- [2026-09-20-code-review.md](2026-09-20-code-review.md) —
  full code review of BROTLib (bugs, security, design, CI/release). **draft**, no finding fixed yet;
  `BROTLibTests` added. Checked with Python ports against `erfa` where possible (`testing/`), TcUnit tests
  pass on the user-mode runtime, not verified on a telescope.
- [2026-09-23-multi-field-influx-message-parsing.md](2026-09-23-multi-field-influx-message-parsing.md) —
  `FB_InfluxMessage` only returns the first `parameter=value` pair in a multi-field Influx line, dropping the
  rest; return-the-remainder design so a caller can loop, prerequisite for BROTLib#6's "one message per
  command" fix. **implemented on a branch**, tests written, not yet run on the runtime (BROTLib#39)
- [2026-09-23-fb-axis-latching-and-self-mutation-fixes.md](2026-09-23-fb-axis-latching-and-self-mutation-fixes.md) —
  BROTLib#9's six findings re-verified against the merged `FB_Axis` (only one was fixed as a side effect of the
  `FB_Axis2`/`FB_Axis3` unification): the `Axis_SetpointEnable.Execute` error latch, `Axis_Home`'s stale
  reference position, the self-mutating `VAR_INPUT`s (flagged as a separate bigger effort), the unverified
  `MC_Power` default question, and the `OR`/`AND` busy-check fix. **partly implemented**: `OR`/`AND` in v0.6.1,
  the latch on PR #61, `MC_Power` answered, the reference and the flags moved to the 2026-10-08 plan

- [2026-10-06-fb-axis-rehome-check-and-0.5.5-release.md](2026-10-06-fb-axis-rehome-check-and-0.5.5-release.md) —
  handover: the `FB_Axis` re-home fix (`6dabd5a`) is on `develop` but unreleased and never run on a PLC; what is
  unknown (`MC_Home.Busy` timing), the on-site check, and the 0.5.5 release steps. **proposed**
- [2026-10-08-fb-axis-home-position-and-command-handshake.md](2026-10-08-fb-axis-home-position-and-command-handshake.md) —
  `FB_Axis` interface change, all repos together: mandatory homing reference (#62) and command methods
  `Move`/`Home(fReference)`/`Stop` (#63); merge order (BROTLib then HalfBROT back to back), IAG50cm to the new
  version, telescope checks. Design: `fb-axis-command-interface.md`. **accepted**, not started (B2; IAG50cm focus
  homes to its stored last position)
- [2026-10-20-command-field-separator-79.md](2026-10-20-command-field-separator-79.md) —
  `command azimuth=150 elevation=50 slew=1` (spaces instead of commas) applies only the first field and drops the
  rest silently: new `FB_InfluxMessage` outputs `trailing`/`trailingIgnored`, one ADS warning per message in
  `_DispatchPass`, README syntax example, MONET/S re-test. **proposed**, nothing implemented; open: also skip
  `track`/`slew` of such a message, publish the warning over MQTT (BROTLib#79)
- [2026-10-20-focus-command-guard-74.md](2026-10-20-focus-command-guard-74.md) —
  `command focus=..` moves the focus while the telescope is parked: new read-only `I_Telescope.ReadyState`,
  `FB_Comm_MQTT_Influx` applies `focus` only at READY_STATE 1 and logs the rejection; park/startup focus writes
  unaffected; IAG50cm adds the property (0.9.0), tests with a focus stub, MONET/S re-test. **proposed**, nothing
  implemented; open: gate 1 only or wider, interface vs `__QUERYINTERFACE`, no telescope connected (BROTLib#74)
