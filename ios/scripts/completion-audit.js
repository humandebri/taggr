#!/usr/bin/env node
const { spawnSync } = require("child_process");

const run = (label, command, args) => {
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0) {
        console.error(`${label} failed`);
        process.exit(result.status || 1);
    }
};

run("Swift iOS preflight", process.execPath, [
    "ios/scripts/swift-preflight.js",
]);
run("local AASA build output check", process.execPath, [
    "ios/scripts/local-aasa-check.js",
]);
run("App Review preflight", process.execPath, [
    "ios/scripts/review-preflight.js",
]);

console.log("Swift iOS completion audit passed.");
