#!/usr/bin/env node
const { spawnSync } = require("child_process");

const destination =
    process.env.IOS_SIM_DESTINATION || "platform=iOS Simulator,name=iPhone 17";
const derivedDataPath = process.env.IOS_DERIVED_DATA_PATH || ".build/xcode";

const result = spawnSync(
    "xcodebuild",
    [
        "test",
        "-project",
        "ios/TAGGR/TAGGR.xcodeproj",
        "-scheme",
        "TAGGR",
        "-destination",
        destination,
        "-maximum-concurrent-test-simulator-destinations",
        "1",
        "-parallel-testing-enabled",
        "NO",
        "-parallel-testing-worker-count",
        "1",
        "-derivedDataPath",
        derivedDataPath,
    ],
    { stdio: "inherit" },
);

process.exit(result.status || 0);
