#!/usr/bin/env node
const { spawnSync } = require("child_process");

const run = (label, command, args) => {
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0) {
        console.error(`${label} failed`);
        process.exit(result.status || 1);
    }
};

run("Swift iOS audit", process.execPath, ["scripts/ios/swift-audit.js"]);
run("Swift authored file line counts", process.execPath, ["scripts/ios/line-count-check.js"]);
run("Swift iOS preflight", process.execPath, ["scripts/ios/swift-preflight.js"]);
run("local AASA build output check", process.execPath, ["scripts/ios/local-aasa-check.js"]);
run("App Review preflight", process.execPath, ["scripts/ios/review-preflight.js"]);

console.log("Swift iOS completion audit passed.");
