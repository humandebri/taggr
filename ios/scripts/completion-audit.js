#!/usr/bin/env node
const { spawnSync } = require("child_process");
const fs = require("fs");

const run = (label, command, args) => {
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0) {
        console.error(`${label} failed`);
        process.exit(result.status || 1);
    }
};

run("Swift iOS audit", process.execPath, ["ios/scripts/swift-audit.js"]);
run("Swift authored file line counts", process.execPath, [
    "ios/scripts/line-count-check.js",
]);
run("Swift iOS preflight", process.execPath, [
    "ios/scripts/swift-preflight.js",
]);
run("local AASA build output check", process.execPath, [
    "ios/scripts/local-aasa-check.js",
]);
run("App Review preflight", process.execPath, [
    "ios/scripts/review-preflight.js",
]);

const deviceDoc = fs.readFileSync("ios/docs/device_verification.md", "utf8");
const requiredDeviceEvidence = [
    "Simulator launch: PASS",
    "Physical device launch: PASS",
    "Production URL load: PASS",
    "Internet Identity continuity: PASS",
    "Internal navigation: PASS",
    "External navigation: PASS",
    "Universal link: PASS",
    "Share sheet: PASS",
    "Offline reload UI: PASS",
    "iPhone SE moderation reachability: PASS",
];

if (deviceDoc.includes("TODO")) {
    console.error("Device verification TODO remains.");
    process.exit(1);
}
for (const text of requiredDeviceEvidence) {
    if (!deviceDoc.includes(text)) {
        console.error(`Device verification missing: ${text}`);
        process.exit(1);
    }
}

console.log("Swift iOS completion audit passed.");
