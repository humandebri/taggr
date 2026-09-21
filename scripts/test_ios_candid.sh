#!/usr/bin/env bash
set -euo pipefail

# Run the generated Candid bindings in Xcode. The explicit flag is required for
# non-interactive builds because Xcode otherwise asks the developer to trust
# the package build tool plugin.
#
# The simulator is resolved instead of pinned by model name: runner images change
# which devices exist, and a cold CoreSimulator service can hide them on the first
# lookup.

simulator_udid() {
    xcrun simctl list devices available --json | python3 -c '
import json, sys

devices = json.load(sys.stdin).get("devices", {})
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
'
}

destination=""
for _ in 1 2 3; do
    destination="$(simulator_udid || true)"
    [ -n "$destination" ] && break
    sleep 5
done

if [ -z "$destination" ]; then
    echo "No available iPhone simulator found. Install an iOS simulator runtime first." >&2
    exit 1
fi

echo "Using simulator $destination"

xcodebuild \
    -project ios/TAGGR/TAGGR.xcodeproj \
    -scheme TAGGR \
    -destination "id=$destination" \
    -configuration Debug \
    -parallel-testing-enabled NO \
    build-for-testing \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO

xcodebuild \
    -project ios/TAGGR/TAGGR.xcodeproj \
    -scheme TAGGR \
    -destination "id=$destination" \
    -configuration Debug \
    -parallel-testing-enabled NO \
    test-without-building \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
