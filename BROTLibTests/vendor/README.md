# Vendored libraries

`tcunit.library` is TcUnit 1.2.0.0 (`www.tcunit.org`), the unit test framework the tests are written with:
<https://github.com/tcunit/TcUnit>. It is checked in so that a fresh checkout, including a CI machine, can build
and run BROTLibTests without downloading anything. See the TcUnit project for its license terms.

SHA-256: `ed37b45e906c58b23384829959585378c1aa0cc0bbd2c79a6f835ab9716f5cb6`. This is byte-for-byte the copy that
sits unused in `AstroBROT/AstroBROT/AstroBROT/_Libraries/www.tcunit.org/tcunit/1.2.0.0/`.

Install it into the local library repository with `..\tools\Install-TcUnit.ps1`.

`*.library` is ignored by the repository's `.gitignore` (BROTLib's own build output); this file is the one
exception, listed explicitly there.
