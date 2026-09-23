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
  command" fix. **proposed**, nothing implemented (BROTLib#39)
