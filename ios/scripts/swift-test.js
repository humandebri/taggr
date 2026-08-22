#!/usr/bin/env node
const { spawnSync } = require("child_process");

const derivedDataPath = process.env.IOS_DERIVED_DATA_PATH || ".build/xcode";

function run(command, args, options = {}) {
    return spawnSync(command, args, {
        encoding: "utf8",
        stdio: options.capture ? "pipe" : "inherit",
        ...options,
    });
}

function availableSimulatorDestination() {
    const result = run(
        "xcrun",
        ["simctl", "list", "devices", "available", "-j"],
        {
            capture: true,
        },
    );
    if (result.status === 0) {
        try {
            const devices = Object.values(
                JSON.parse(result.stdout).devices || {},
            )
                .flat()
                .filter(
                    (device) =>
                        device.isAvailable &&
                        device.deviceTypeIdentifier?.includes(
                            ".SimDeviceType.iPhone-",
                        ),
                );
            const selected =
                devices.find((device) => device.state === "Booted") ||
                devices[0];
            if (selected) return `platform=iOS Simulator,id=${selected.udid}`;
        } catch {
            // Fall through to Xcode's destination listing.
        }
    }

    const destinations = run(
        "xcodebuild",
        [
            "-showdestinations",
            "-project",
            "ios/TAGGR/TAGGR.xcodeproj",
            "-scheme",
            "TAGGR",
        ],
        { capture: true },
    );
    if (destinations.status !== 0) return null;
    const match = destinations.stdout.match(
        /\{\s*platform:iOS Simulator,[^}]*id:([0-9A-F-]+),[^}]*name:[^}]*iPhone[^}]*\}/,
    );
    return match ? `platform=iOS Simulator,id=${match[1]}` : null;
}

function testDestination() {
    if (process.env.IOS_TEST_DESTINATION) {
        return { value: process.env.IOS_TEST_DESTINATION, simulator: false };
    }
    if (process.env.IOS_DEVICE_ID) {
        return { value: `id=${process.env.IOS_DEVICE_ID}`, simulator: false };
    }
    return {
        value:
            process.env.IOS_SIM_DESTINATION ||
            availableSimulatorDestination() ||
            "platform=iOS Simulator,name=iPhone 17",
        simulator: true,
    };
}

const destination = testDestination();
const args = [
    "test",
    "-project",
    "ios/TAGGR/TAGGR.xcodeproj",
    "-scheme",
    "TAGGR",
    "-destination",
    destination.value,
    "-parallel-testing-enabled",
    "NO",
    "-parallel-testing-worker-count",
    "1",
    "-derivedDataPath",
    derivedDataPath,
];

if (destination.simulator) {
    args.splice(7, 0, "-maximum-concurrent-test-simulator-destinations", "1");
}

console.log(`==> xcodebuild test destination: ${destination.value}`);

const result = spawnSync("xcodebuild", args, { stdio: "inherit" });

process.exit(result.status || 0);
