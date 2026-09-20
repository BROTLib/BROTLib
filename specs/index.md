# BROTLib specs

Design docs, ADRs, investigation plans, and steering notes for BROTLib and the shared TwinCAT
library ecosystem it anchors (MONETcommon, HalfBROT, AstroBROT, MONETRoof, and how IAG50cm/MONETN/
MONETS consume them). Split out 2026-09-20 from IAG's previously-consolidated `specs/` tree: docs
that are generic to the library/tooling and don't contain IAG-private infrastructure, credential,
or live-incident details live here; docs that do stay in IAG's own private `specs/` repo. A doc
here that references a specific live telescope controller or a private connection detail points
to IAG's private specs for that part rather than including it directly.

- **[design/](design/index.md)** — Living design notes per subsystem or interface. Updated in place as understanding evolves; not tied to a single point in time.
- **[plans/](plans/index.md)** — Dated investigation/work logs, one per bug fix, feature, or review.
- **[steering/](steering/index.md)** — Cross-cutting operational knowledge and gotchas, added only once a real recurring convention warrants it.

Filename convention: `<slug>.md`, `<slug>-YYYY-MM-DD.md`/`YYYY-MM-DD-<slug>.md` for dated plans. A
doc naming another repo it also covers (e.g. `iag50cm-axis-unification-plan.md`) keeps that
project's name in the filename; a doc scoped to BROTLib alone doesn't need a redundant `brotlib-`
prefix now that it lives in BROTLib's own tree.
