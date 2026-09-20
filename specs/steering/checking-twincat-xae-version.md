# How to check a machine's installed TwinCAT XAE version

Needed whenever comparing engineering-PC tooling across the fleet — e.g. confirming whether a
`Becky` matches the version a checked-in `.plcproj`'s embedded visualization profile expects (see
[2026-09-15-twincat-ci-investigation.md](../plans/2026-09-15-twincat-ci-investigation.md),
which found a real mismatch this way: IAG50cm's `Becky` on Build 4024 vs. a checked-in profile
referencing Build 4026).

Run this from a plain PowerShell prompt — no TwinCAT UI needs to be open:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "TwinCAT|XAE" } |
  Select-Object DisplayName, DisplayVersion
```

The two lines that matter:

- `Beckhoff TwinCAT 3.1 (Build NNNN)` / `DisplayVersion` like `3.1.4024.66` — the core TwinCAT
  system build. This is the number that matters for `.plcproj` visualization-profile compatibility
  and for matching a project's stated target build.
- `Beckhoff TwinCAT XAE Shell` / `DisplayVersion` like `1.17.0.0` — the XAE Shell (standalone
  engineering IDE, not full Visual Studio) product version, a separate versioning scheme from the
  TwinCAT build number above. Both numbers are worth recording; they don't move in lockstep.

**Don't** rely on `TcXaeShell.exe`'s own file version (`C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe`)
— it reports `15.0.0.0`, the underlying Visual Studio shell interop version, not anything
TwinCAT-specific. Not useful for this comparison.

If checking the **runtime** version on an actual CX controller instead of an engineering PC's
installed tooling, that's a different, ADS-based check — see
IAG's private `tools/Ads-Query.ps1` and its use in IAG's own
`specs/design/monetn-hardware-inventory.md` (reads the auto-generated
`Global_Version` GVL live). The two numbers answer different questions: engineering-PC tooling
version (this doc) vs. what's actually compiled into the running boot project (the ADS approach).
