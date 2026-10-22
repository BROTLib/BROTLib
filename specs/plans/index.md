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
- [2026-10-21-telescope-state-machine-unification.md](2026-10-21-telescope-state-machine-unification.md) —
  the telescope state machine exists twice (MONETcommon `FB_MonetTelescopeControl`, IAG50cm `FB_TelescopeControl`;
  the MONETN copy of BROTLib#25 is gone): block-by-block comparison (identical / diverged with the newer fix /
  site-specific), characterization tests first (mock rig subclassing the real axis blocks, scenario suites in
  MONETcommonTests and IAG50cmTests), neutral refactors, pure units and one N-axis stop transaction into BROTLib,
  then `FB_CommandArbiter` and the template body in `FB_BaseTelescopeControl`; release chain and on-site checks per
  step. **proposed**, nothing implemented, starts after #122; open: base in BROTLib vs a new library, arbiter-only
  end state, policy per divergence, time seam, IAG cabinet in tests (BROTLib#25, #67, MONETcommon#36, #24)
- [2026-10-21-axis-stop-idempotent-93-92.md](2026-10-21-axis-stop-idempotent-93-92.md) —
  `FB_Axis.Stop()` no longer restarts `MC_Stop` while a stop is pending, running or finishing (a repeated call
  joins it and gets one more `StopDone` pulse, so the `StopAxis` setters and both transaction blocks need no
  change); `FB_AxisCommand` releases `Execute` on `Done OR CommandAborted` (#92); 16 TcUnit cases, BROTLib 0.9.1,
  then pin bumps, IAG50cm last with an on-site check. **proposed**, nothing implemented; open: join vs plain
  no-op, `MC_Home` abort vs error, retry after `MC_Stop` error (BROTLib#93, #92)
- [2026-10-21-focus-retarget-stop-range-122.md](2026-10-21-focus-retarget-stop-range-122.md) —
  `focus=500` runs the focus to the clamp limit 100 (beyond the far switch at ~92), a new target and `stop=1` are
  ignored: re-target while moving (`FB_MoveFollower`), new `I_Focus.Stop()` called by the telescopes' stop, `I_Focus`
  `MinPosition`/`MaxPosition` and an out-of-range rejection in `FB_Comm_MQTT_Influx`, site limits 0.5..91.5 in
  MONETS/MONETN. **implemented** and released 2026-10-21 (BROTLib 0.10.0, HalfBROT 0.6.0, MONETcommon 0.9.4, MONETS
  1.4.3, MONETN 0.4.3, IAG50cm 0.4.1); on-site re-test open (MONETcommon#122)
- [2026-10-22-focus-manual-home.md](2026-10-22-focus-manual-home.md) — manual re-home of a calibrated MONET focus through a `bManualHome` variable (XAE/ADS/program, not MQTT): cam homing, pure `FB_FocusManualHome` in HalfBROT tested in MONETcommonTests, `HomePending` guard, restore of the target, stop handling. **implemented** and released 2026-10-22 (HalfBROT 0.7.1, MONETcommon 0.9.7, MONETS 1.4.4, MONETN 1.4.4); on-site test on MONET/S open
