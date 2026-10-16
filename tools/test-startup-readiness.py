#!/usr/bin/env python3
"""Run the hardware-free TcUnit readiness scenarios with IronPLC's compiler/VM.

The assertions and FB under test are extracted from their actual TwinCAT sources.
This does not compile the NC-backed telescope controllers or replace TwinCAT CI.
Supported test shape: one local FB_StartupReadiness instance named ``fb`` per method,
positional single-line assertions with comma-free expressions, and simple quoted
messages. This is a narrow adapter, not a general ST parser; extend it or use
TcUnit directly when adding scenarios outside those shapes.
"""

import argparse
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ironplcc")
    parser.add_argument("--vm", default="ironplcvm")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    fb = ET.parse(root / "BROTLib/BROTLib/Telescope/FB_StartupReadiness.TcPOU").getroot().find("POU")
    suite = (
        ET.parse(root / "BROTLibTests/BROTLibTests/BROTLibTests/POUs/FB_StartupReadiness_Tests.TcPOU")
        .getroot()
        .find("POU")
    )
    declarations = ["failed : DINT;"]
    bodies = []
    assertions = 0
    for index, method in enumerate(suite.findall("Method")):
        instance = f"fb{index}"
        declarations.append(f"{instance} : FB_StartupReadiness;")
        body = method.findtext("Implementation/ST")
        body = re.sub(r"TEST\('[^']*'\);|TEST_FINISHED\(\);", "", body)
        body = re.sub(r"\bfb\b", instance, body)

        def equals(match: re.Match) -> str:
            nonlocal assertions
            assertions += 1
            expected, actual, delta = match.group(1, 2, 3)
            return f"IF ABS({expected} - {actual}) > {delta} THEN failed := failed + 1; END_IF;"

        body = re.sub(r"AssertEquals_LREAL\(([^,]+), ([^,]+), ([^,]+), '[^']*'\);", equals, body)
        for name, negation in (("AssertTrue", "NOT "), ("AssertFalse", "")):
            body, count = re.subn(
                rf"{name}\(([^,]+), '[^']*'\);",
                lambda match: f"IF {negation}({match.group(1)}) THEN failed := failed + 1; END_IF;",
                body,
            )
            assertions += count
        if "Assert" in body:
            raise ValueError("Unsupported assertion in portable test adapter")
        bodies.append(body)
    source = (
        fb.findtext("Declaration")
        + fb.findtext("Implementation/ST")
        + "\nEND_FUNCTION_BLOCK\nPROGRAM ReadinessTest\nVAR\n"
        + "\n".join(declarations)
        + "\nEND_VAR\n"
        + "\n".join(bodies)
        + "\nEND_PROGRAM\n"
    )
    with tempfile.TemporaryDirectory() as directory:
        st = Path(directory) / "readiness.st"
        bytecode = Path(directory) / "readiness.iplc"
        dump = Path(directory) / "variables.csv"
        st.write_text(source)
        subprocess.run([args.compiler, "compile", "--dialect", "twincat", "-o", str(bytecode), str(st)], check=True)
        subprocess.run([args.vm, "run", str(bytecode), "--scans", "1", "--dump-vars", str(dump)], check=True)
        output = dump.read_text()
        if not re.search(r"^failed:\s*0\s*$", output, re.MULTILINE | re.IGNORECASE):
            raise RuntimeError(f"Readiness assertions failed or result missing:\n{output}")
    print(f"Passed {assertions} assertions in {len(bodies)} readiness scenarios")


if __name__ == "__main__":
    main()
