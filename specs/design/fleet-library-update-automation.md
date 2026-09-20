# Installing a prebuilt `.library` via `RepTool.exe`

Repos: BROTLib (and any consumer library needing to install a released `.library` artifact with
no source checkout)

## Problem

Once a TwinCAT engineering PC no longer clones a dependency's full source locally, installing the
*latest released* version of that dependency needs a different mechanism: fetch the pre-built
`.library` artifact already attached to the library's GitHub Release, and install just the binary
— see [twincat-ci-runner-setup.md](twincat-ci-runner-setup.md) for the build/release side that
produces those release assets.

## `RepTool.exe`: installing a `.library` file with no project/source involved

Every `TcBuild install` *builds from source* — it compiles a `.sln` and produces + installs the
resulting `.library` in one step. What's needed here is the reverse: given an already-built
`.library` file (downloaded, no source checkout at all), install it into the local TwinCAT library
repository from the command line. Normally this is a manual action in XAE's Library Manager (drag
in the file, click "Install...").

**`RepTool.exe`**, a repository-management CLI from TwinCAT's CODESYS lineage, does this directly:

```
RepTool.exe --profile="TwinCAT PLC Control_Build_4024.66" --installLibsRecurs "<directory>"
```

Installs every `.library` file found in the given directory (recursively), independent of any
project.

**Correction (verified against a real installed `RepTool.exe`, 2026-09-17):** the flag is
**`--installLibsRecurs`**, not `--installLibsRecursNoOverwrite` as originally sourced from web
research (that name doesn't appear anywhere in `RepTool.exe --help`'s actual output — the
web-research sources describing a `NoOverwrite` variant were wrong, or describe a different
tool/version). No overwrite/no-overwrite flag exists for library install at all;
`--installLibsRecurs` presumably always overwrites — not yet tested whether it errors, skips, or
silently replaces an existing installed version of the same library/version.

Path: `C:\TwinCAT\3.1\Components\Plc\Common\RepTool.exe`.

`RepTool` is a general repository-management tool, not just for libraries — it also handles
EtherCAT/CANopen device-description files (`--installDevice`, `--installDevicesRecurs`,
`--importDevice --converter=<guid>` for format conversion from EDS/GSD/GSDML/etc.).

### Finding the `--profile` value

The profile string must match the target machine's installed XAE build exactly. Confirmed method,
via a CODESYS forum thread on plain CODESYS (not TwinCAT specifically): scan a `Profiles` folder
for `*.profile` files, named after the profile string itself
(`C:\Program Files (x86)\3S CODESYS\CODESYS\Profiles` on plain CODESYS).

**Confirmed for TwinCAT (2026-09-17)**: `C:\TwinCAT\3.1\Components\Plc\Profiles` exists and
contains `*.profile` files named after the installed build (e.g.
`TwinCAT PLC Control_Build_4024.66.profile`) — the inferred path was correct. Different machines
can have a different build number and/or multiple `.profile` files present at once, so don't
assume there's exactly one.

### `RepTool.exe --help` (captured 2026-09-17)

Confirmed command set relevant to this design (full output is longer — also covers
`--createLibRepos`/`--removeLibRepos`/`--moveLibRepos`, visualization-element/style repos, and
`--convertLib`/`--compileLib`):

```
--installLib <libpath>
                 Install library to the system repos
--installLib --repos=<rootpath|name> <libpath>
                 Install library to the specified repos
--installLibsRecurs <folderpath>
                 Install all libraries in a folder to the system repos
--installLibsRecurs --repos=<rootpath|name> <libpath>
                 Install all libraries in a folder to the specified repos
--uninstallLib <libname>
                 Uninstall library from the system repos
--uninstallLib --repos=<rootpath|name> <libname>
                 Uninstall library from the specified repos
--uninstallLibs --repos=<name> <libname>,<libname>,...
                 Uninstall library from the specified repos
--installDevice <deviceName> [<deviceName_2>...<deviceName_n>]
                 Install the specified devdesc files
--installDevicesRecurs <folderpath>
                 Install all devdesc files in a folder to the system repository.
--importDevice --converter=<guid> [--parameters="key1=vallue1;...keyn=valluen;"] <deviceName> ...
                 Import device description files using the specified converter (EthernetIP, GSD,
                 Sercos3, Native, EDS, Ethercat, GSDML)
```

## Known gotchas

- **PowerShell's `&` call operator mangles `--profile` values containing spaces.** Every real
  TwinCAT profile name has spaces (e.g. `TwinCAT PLC Control_Build_4024.66`), so
  `& $RepTool --profile="$TcProfile" --installLibsRecurs $dir` fails immediately with `RepTool`'s
  `No profile name specified` — confirmed via isolated testing to be a PowerShell argument-
  marshalling bug, not a `RepTool` parsing bug or a wrong profile string (a no-space fake profile
  value gets past that check and fails differently, on not finding the made-up profile; the
  identical quoted string works when run through `cmd.exe /c "..."` instead). **Fix: route the
  `RepTool` call through `cmd.exe /c` instead of PowerShell's native `&` operator.**
- **The real "System" repos XAE's Library Manager reads from lives at
  `C:\TwinCAT\3.1\Components\Plc\Managed Libraries`** — not
  `C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries`, which looks plausible (and
  may contain old/vestigial copies) but is not what the Library Manager GUI's `Location: System`
  actually points at. Confirmed directly from the GUI's `Library Repository` dialog, `Location`
  field.
- **"BROT" (and `System`, `Intern`, `3S-Smart Software Solutions GmbH`, etc.) are not separate
  repos** — they're values of the `Company` column inside the single `System` repos, as shown in
  the GUI (`AstroBROT`/`BROTLib` under company `BROT`; `Base Interfaces` under company `System`;
  all listed together under one `Location: System`). Passing `--repos="BROT"` is rejected as
  unregistered for this reason — it was never a repos name to begin with.
- A `.library` file installed via `RepTool` keeps its original filename (e.g.
  `AstroBROT_v0.3.0.library`) — `RepTool` doesn't rename it — alongside generated
  `browsercache`/`dependencies`/`projectinfo` files.

## Known limitations, not yet addressed

- No rollback/dry-run mode — installs immediately once it decides an update is needed.
- Assumes exactly one `.library` asset per release; doesn't handle a release with zero or multiple
  `.library` files beyond picking the first found.
- Version comparison is exact string match against installed folder names, not semver-aware — a
  release tagged inconsistently (e.g. missing the `v` prefix, or a pre-release suffix) could be
  treated as "not installed" even if functionally equivalent.
- Never tested from an **elevated** PowerShell prompt, despite common guidance recommending it for
  TwinCAT tooling — not deliberately verified either way.
