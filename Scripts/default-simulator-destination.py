#!/usr/bin/env python3
"""Resolve the default iPhone against installed runtimes, not OS:latest.

Picks an installed "iPhone 17 Pro" on the newest iOS runtime and prints, by
default, the `platform=iOS Simulator,id=<udid>` destination the wrappers pass
to xcodebuild. Two other outputs serve CI, which pins its simulator to the same
device before `prepare-simulator.sh` boots it (architecture review 2026-11,
gap-ipad-and-os-floor#3):

  --udid      the device's UDID alone, for SIMULATOR_ID
  --describe  one line naming the device, its runtime and its UDID, so a runner
              image that changes the runtime shows as a changed line in the log
"""

import json
import re
import subprocess
import sys


def main():
    mode = "destination"
    if len(sys.argv) == 2 and sys.argv[1] in ("--udid", "--describe"):
        mode = sys.argv[1][2:]
    elif len(sys.argv) != 1:
        sys.exit(f"usage: {sys.argv[0]} [--udid | --describe]")

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
                candidates.append((tuple(map(int, version[1].split("-"))), device["udid"], runtime))

    if not candidates:
        sys.exit("No available iPhone 17 Pro simulator found. Set DESTINATION or create that simulator.")

    version, device_id, runtime = max(candidates)
    if mode == "udid":
        print(device_id)
    elif mode == "describe":
        print(f"iPhone 17 Pro, iOS {'.'.join(map(str, version))} ({runtime}), {device_id}")
    else:
        print(f"platform=iOS Simulator,id={device_id}")


if __name__ == "__main__":
    main()
