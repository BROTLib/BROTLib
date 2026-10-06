# BROTLibTests

TcUnit tests for BROTLib. A separate PLC project, so no test code ends up in the shipped library. It
references the *installed* BROTLib (`BROTLib, * (BROT)`), exactly like a telescope project does.

## What is covered

| Suite | Tests | What it checks |
|---|---|---|
| `FB_IsNumericValue_Tests` | `F_IsNumericValue` | which strings the Influx publisher writes as numbers: signs, exponents, malformed input, text |
| `FB_EscapeInfluxString_Tests` | `F_EscapeInfluxString` | `"` and `\` are escaped, nothing else is, length doubles for all-quote input |
| `FB_YREAL_Tests` | `F_YREAL` | linear scaling, offset ranges, clamping with `cut`, zero-width input range |
| `FB_Tracking_Tests` | `F_Azimuthvelocity`, `F_Elevationvelocity`, `F_Derotatorvelocity`, `F_DerotatorPosition2` | hand-checkable anchors, golden values, zenith guard, result stays in [0, 360) |
| `FB_PointingModel_Tests` | `FB_PointingModelForward`, `FB_PointingModelInversion` | every one of the nine terms on its own, the zenith clamp, a combined golden vector, inversion round trip |
| `FB_Axis_Tests` | `FB_Axis` (no NC axis) | actual position (plain and modulo), `isTracking` envelope, move ignored and home request kept without calibration, modulo-wrap limitation pinned. Homing completion and the setpoint generator need an NC and are not covered |
| `FB_Blink_Tests` | `FB_BLINK` | off/on modes, timing per mode, measured high/low durations (real time, +-60 ms) |
| `FB_InfluxLineProtocol_Tests` | `F_InfluxFieldValue`, `F_EscapeInfluxTag`, `F_TruncateInfluxEscaped` | integer / float / boolean / quoted typing (exponents are floats), escaping of tag values, field keys and measurement names, cutting an escaped string without splitting an escape pair |
| `FB_AstroClockSync_Tests` | `FB_AstroClockSync` | the sync and validity logic behind `FB_AstroClock`: no sync and no validity before the first good read, no sync on a failed read, error counting, recovery |

60 test cases in total.

Expected values are either hand-derivable (sin/cos of 0, 45, 60, 90 degrees) or golden values printed by
[`testing/golden_vectors.py`](../testing/golden_vectors.py). That script first checks the tracking formulas
against numerical derivatives of an independent HA/Dec -> Az/El transform (they agree to about 4e-10 deg/s), so
the golden values are not just the ST code compared with itself. Re-run it after changing a formula.

### Deliberately not covered

Tests that would fail today are left out rather than written red. Add them when the code is fixed.

- `F_YREAL` with an inverted output range and `cut = TRUE` returns a constant (code review L2).
- `FB_Horn` never pauses (L1).
- The velocity functions return 0 above 89.943 deg elevation, where the true rate is not 0 (L3). The current
  behaviour is pinned by `Azimuthvelocity_Near_Zenith_Guard`; update it together with the fix.

## Running the tests

TcBuild only compiles. Running needs a TwinCAT runtime that executes the PLC, plus a (trial) license for it.

**Windows 11 note.** The TwinCAT 3.1 Build 4024 *real-time* runtime does not run on Windows 11
([Beckhoff system requirements](https://infosys.beckhoff.com/content/1033/tc3_overview/6162419083.html)); Run mode
fails with `Init4\RTime: Start Interrupt: Ticker started >> AdsError: 6 (port 200)`. XAE and TcBuild are fine.
Use the beta **user-mode runtime** that ships with TwinCAT instead (`C:\TwinCAT\3.1\Runtimes\UmRT_Default`, see
the `Readme.txt` there for its terms of use). It has no real-time guarantees, which is why the timing test has a
tolerance.

One-time setup on a machine:

1. Install TcUnit into the local library repository. This starts a hidden XAE instance:
   ```powershell
   .\BROTLibTests\tools\Install-TcUnit.ps1
   ```
2. Make sure the current BROTLib is installed too (the tests use the *installed* copy, not the source tree):
   ```powershell
   & "C:\Program Files\Industrial Brains B.V\TcBuild\TcBuild.exe" install BROTLib.sln -x BROTLib -p BROTLib -l BROTLib.library
   ```

Every run:

1. Start the user-mode runtime **from its own folder** (`Start.bat` uses the current directory for its config):
   ```powershell
   cd C:\TwinCAT\3.1\Runtimes\UmRT_Default; .\Start.bat
   ```
   On the CI machine this is done at boot by the scheduled task `TwinCAT UmRT_Default` (runs `Start.bat` as
   SYSTEM, hidden, restarted up to 3 times if it fails), so there is nothing to start by hand there.
2. Build, deploy and run. Exit code 0 = all passed, 1 = a test failed, 2 = no result within the timeout:
   ```powershell
   & "C:\Program Files\Industrial Brains B.V\TcBuild\TcBuild.exe" build BROTLibTests.sln
   .\BROTLibTests\tools\Run-Tests.ps1
   ```
   It overwrites whatever boot project is on the target runtime (default `192.168.4.1.1.1`, override with
   `-TargetNetId`). The counters are printed; the individual failing assertions are in the TwinCAT ADS log
   (XAE error list) when you open the project in XAE and connect to the target.

To debug interactively instead: open `BROTLibTests.sln` in XAE, choose the user-mode runtime as target, activate
the configuration, log in and start the PLC. TcUnit prints every result to the error list.

## In CI

`.github/workflows/tests.yml` runs on every push (never on pull requests: the runner is self-hosted) and does, in
order: check that the trial license has not expired and the user-mode runtime is running, install the checked-out
BROTLib into the machine's library repository, build `BROTLibTests.sln`, run `tools/Run-Tests.ps1`. Runs are queued
and not cancelled, because a cancelled run leaves a stray hidden XAE behind. `tcbuild.yml` is the plain compile check
of `BROTLib.sln`; it runs on pushes to `main` (the release merges) and on demand.

The runner and the runtime share the machine with whoever works in XAE there. `Run-Tests.ps1` and `Install-TcUnit.ps1`
only quit and kill the XAE instance they started themselves, so an XAE you open meanwhile is left alone. They do
overwrite the boot project on the target runtime (`192.168.4.1.1.1`) and restart TwinCAT, so do not be connected to
that runtime while a run is going, and expect the library repository to change after a run.

## Things to know

- **Trial license.** The PLC trial license (TC1000, TC1100, TC1200) lasts 7 days and is renewed by hand (captcha):
  XAE > SYSTEM > License > Manage Licenses > 7 Days Trial License. It is bound to the machine's System ID (shown on
  the Order Information (Runtime) tab; it stays the same across a runtime restart and a reboot) and its expiry is
  in `C:\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Target\License\TrialLicense.tclrs`. `tests.yml` fails with a clear
  message once it has expired. A permanent TC1200 license is needed for unattended CI.
- **TcUnit sizing.** TcUnit's defaults (1000 suites x 100 tests x 1000 assertions) allocate about 78 MB of PLC
  data, which the user-mode runtime cannot start. The project overrides them to 32 / 32 / 256 in the
  `TcUnit` reference (`Parameters` in `BROTLibTests.plcproj`). TcUnit needs tests-per-suite <= suites, or it does
  not compile. If you add a suite with more than 32 tests or 256 assertions, raise the numbers together.
- **Every test method is called every PLC cycle.** Multi-cycle tests (see `Timing_Follows_Mode`) therefore guard
  their own state and call `TEST_FINISHED()` once.
- **Library functions and `FB_init` need every argument.** Defaults declared in BROTLib do not apply at the call
  site from another project, so `F_YREAL`, `F_DerotatorPosition2` and `FB_PointingModelForward(...)` are called
  with all inputs spelled out.
- **Identifier pitfall.** ST is case-insensitive: a parameter named `sIn` collides with the `SIN` operator and
  produces a wall of parse errors.
- `.tmc`, `_Boot/`, `_CompileInfo/` and `_Libraries/` are generated and ignored by git.
