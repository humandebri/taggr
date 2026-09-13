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
    const result = run("idb", ["list-targets", "--json"], { capture: true });
    if (result.status !== 0)
        throw new Error(`idb target discovery failed: ${result.stderr}`);
    const targets = result.stdout
        .trim()
        .split("\n")
        .filter(Boolean)
        .flatMap((line) => JSON.parse(line));
    const simulators = targets.filter(
        (target) =>
            target.type === "simulator" && /^iPhone\b/.test(target.name),
    );
    const booted = simulators.filter((target) => target.state === "Booted");
    const candidates = booted.length ? booted : simulators;
    if (candidates.length !== 1)
        throw new Error(
            "Specify IOS_SIM_DESTINATION with the intended Simulator UDID.",
        );
    return `platform=iOS Simulator,id=${candidates[0].udid}`;
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
            process.env.IOS_SIM_DESTINATION || availableSimulatorDestination(),
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
    "-skipPackagePluginValidation",
];

if (destination.simulator) {
    args.splice(7, 0, "-maximum-concurrent-test-simulator-destinations", "1");
}

console.log(`==> xcodebuild test destination: ${destination.value}`);

const result = spawnSync("xcodebuild", args, { stdio: "inherit" });

process.exit(result.status || 0);
