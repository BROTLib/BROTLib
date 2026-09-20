# Design docs

Living architecture/design docs, one per subsystem, updated in place as understanding evolves;
kept around after landing, not deleted. Moved here from IAG's specs 2026-09-20 (generic content,
no IAG-private infrastructure/credential/incident details — those stay in IAG's own private specs).

- [twincat-scopeview-svdx-format.md](twincat-scopeview-svdx-format.md) — TwinCAT
  ScopeView `.svdx`/`.tcscopex` recording format and how to decode it
  (reverse-engineered from a MONETRoof roof-counter recording). *proposed*
  (Repos: BROTLib, MONETRoof)
- [telescope-telemetry-publish-chain.md](telescope-telemetry-publish-chain.md) — how
  `FB_BaseTelescopeControl._PublishTelemetry()` and its subclass overrides publish
  TCS-style MQTT telemetry, and how that ends up in InfluxDB via Telegraf. *implemented*
  (Repos: BROTLib, MONETcommon, MONETS)
- [mqtt-telemetry-patterns.md](mqtt-telemetry-patterns.md) — MQTT retain semantics
  (already used selectively for booleans), on-change vs. interval publish strategy,
  and Last Will and Testament as an unused mechanism. *informational/reference*
  (Repos: BROTLib, MONETS)
- [mqtt-domain-location-tagging.md](mqtt-domain-location-tagging.md) — every
  `(domain, location)` pair actually used across all repos, and proof (exact
  source line) that `pybrotlib` discards `domain`/`location`/`host` entirely
  when parsing telemetry. *informational/reference*
  (Repos: BROTLib, MONETS, MONETN, HalfBROT, IAG50cm, pyBROT)
- [iag50cm-axis-unification-plan.md](iag50cm-axis-unification-plan.md) —
  file-by-file comparison of BROTLib vs. IAG50cm (`FB_Axis`/`FB_BaseAxis` unification,
  pointing models, telescope-control hierarchy, interfaces). *in progress — see
  `feature/fb-axis-unification` (BROTLib) / `feature/fb-baseaxis-unification`
  (HalfBROT, IAG50cm) branches*
  (Repos: BROTLib, IAG50cm, HalfBROT)
- [iag50cm-fb-axis-comparison.md](iag50cm-fb-axis-comparison.md) —
  detailed `FB_Axis2` (BROTLib) vs. `FB_Axis3` (IAG50cm) comparison referenced by
  the axis-unification plan above. *reference*
  (Repos: BROTLib, IAG50cm)
- [custom-library-versioning.md](custom-library-versioning.md) — `Global_Version`/
  `stLibVersion_<Name>` design (renamed from an earlier `GVL_Version`/`stVersion` scheme to match
  Beckhoff's own convention, confirmed to merge into the compiler's auto-generated symbol) plus the
  `release.yml` version-bump/tag automation and what's actually required to get a new library
  version onto prod. *implemented and verified live on real hardware across the full transitive
  dependency chain* (2026-09-16)
  (Repos: BROTLib, MONETcommon, HalfBROT, AstroBROT, IAG50cm, MONETN, MONETS, MONETRoof)
- [twincat-ci-runner-setup.md](twincat-ci-runner-setup.md) — step-by-step
  self-hosted TwinCAT CI runner setup (dev tooling, TcBuild, org-level runner registration,
  workflow template, known gotchas/flakiness), distilled from the CI investigation so standing up
  a fresh dedicated build VM is quick. *reference* (2026-09-16)
  (Repos: BROTLib, AstroBROT, IAG50cm, MONETcommon, HalfBROT, MONETRoof)
- [fleet-library-update-automation.md](fleet-library-update-automation.md) — general
  `RepTool.exe` reference: installing a prebuilt `.library` with no source checkout (for a future
  where consumer PCs no longer clone library source), the `--installLibsRecurs`/`--profile` CLI,
  and known gotchas (PowerShell `&`-quoting, the real "Managed Libraries" path). Fleet-specific
  usage (which repos, actual bugs found in the deployed script) split out to IAG's own private
  specs 2026-09-20. *verified against a real `RepTool.exe` install* (2026-09-17)
  (Repos: BROTLib)
