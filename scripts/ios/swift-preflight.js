#!/usr/bin/env node
const { spawnSync } = require("child_process");

const run = (label, command, args) => {
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0) {
        console.error(`${label} failed`);
        process.exit(result.status || 1);
    }
};

const derivedDataPath = process.env.IOS_DERIVED_DATA_PATH || ".build/xcode";

run("Swift iOS static audit", process.execPath, ["scripts/ios/swift-audit.js"]);
run("Xcode availability", "xcodebuild", ["-version"]);
run("Xcode project listing", "xcodebuild", [
    "-project",
    "ios/TAGGR/TAGGR.xcodeproj",
    "-list",
]);
run("Swift iOS simulator build", "xcodebuild", [
    "-project",
    "ios/TAGGR/TAGGR.xcodeproj",
    "-scheme",
    "TAGGR",
    "-destination",
    "generic/platform=iOS Simulator",
    "-derivedDataPath",
    derivedDataPath,
    "build",
]);
