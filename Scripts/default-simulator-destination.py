#!/usr/bin/env python3
"""Resolve the default iPhone against installed runtimes, not OS:latest."""

import json
import re
import subprocess
import sys


def main():
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    candidates = []
    for runtime, devices in json.loads(result.stdout)["devices"].items():
        version = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([0-9-]+)", runtime)
        if version is None:
            continue
        for device in devices:
            if device["name"] == "iPhone 17 Pro" and device.get("isAvailable", False):
                candidates.append((tuple(map(int, version[1].split("-"))), device["udid"]))

    if not candidates:
        sys.exit("No available iPhone 17 Pro simulator found. Set DESTINATION or create that simulator.")

    _, device_id = max(candidates)
    print(f"platform=iOS Simulator,id={device_id}")


if __name__ == "__main__":
    main()
