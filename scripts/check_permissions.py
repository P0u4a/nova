#!/usr/bin/env python3
"""Run permission regression tests with a deadline to catch blocked workers."""

from pathlib import Path
import subprocess
import sys


try:
    result = subprocess.run(
        ["zig", "build", "test", "-Dtest-filter=permission"],
        cwd=Path(__file__).resolve().parent.parent,
        timeout=120,
        check=False,
    )
except subprocess.TimeoutExpired:
    sys.exit("Permission tests exceeded 120 seconds; check for a blocked approval worker.")
sys.exit(result.returncode)
