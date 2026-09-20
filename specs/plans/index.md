# Plans

Dated `YYYY-MM-DD-<slug>.md` investigation and work logs, one per unit of work. Moved here from
IAG's specs 2026-09-20 (generic content, no IAG-private infrastructure/credential/incident details).

- [2026-09-15-twincat-ci-investigation.md](2026-09-15-twincat-ci-investigation.md) —
  TcBuild (run locally, not remotely) as a possible path to real CI (automated build/test, plus
  a live version GVL stamped from git as a secondary win) for the custom TwinCAT libraries; prior
  remote-XAE runner attempt failed on VS automation-interface gaps (why `ironplc` work exists).
  **proposed** — blocked on a dedicated Windows machine
- [2026-09-20-code-review.md](2026-09-20-code-review.md) —
  full code review of BROTLib (bugs, security, design, CI/release). **draft**, no fixes applied.
  Checked with Python ports against `erfa` where possible (`testing/`), not run on a PLC.
