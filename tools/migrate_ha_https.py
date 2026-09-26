#!/usr/bin/env python3
"""Prepare a private HA config with only the robot REST URLs moved to TLS.

Usage: migrate_ha_https.py SOURCE OUTPUT
The exact 2026-09-25 baseline has 25 REST commands and 16 REST sensors.
This tool refuses a different shape and never overwrites its output.
"""

import argparse
import os
from pathlib import Path


OLD = "http://192.168.1.31"
NEW = "https://mattjoslin-valetudo.duckdns.org"


def migrate(source: str) -> str:
    lines = source.splitlines(keepends=True)
    result = []
    commands = sensors = 0
    for line in lines:
        if line.startswith("    url:") and OLD in line:
            commands += 1
        elif line.startswith("    resource:") and OLD in line:
            sensors += 1
        else:
            result.append(line)
            continue

        if not line.endswith("\n"):
            raise ValueError("a target URL line has no newline")
        result.append(line.replace(OLD, NEW, 1))
        result.append("    verify_ssl: true\n")

    if (commands, sensors) != (25, 16):
        raise ValueError(f"expected 25 commands and 16 sensors; found {commands} and {sensors}")
    return "".join(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    content = migrate(args.source.read_text())
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write(content)
        out.flush()
        os.fsync(out.fileno())
    print("Prepared 25 REST commands and 16 REST sensors for verified HTTPS")


if __name__ == "__main__":
    main()
