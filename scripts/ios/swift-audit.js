#!/usr/bin/env node
const fs = require("fs");

const required = [
    "ios/TAGGR/TAGGR.xcodeproj/project.pbxproj",
    "ios/TAGGR/TAGGR/TAGGRApp.swift",
    "ios/TAGGR/TAGGR/TaggrAPI/TaggrAPI.swift",
    "ios/TAGGR/TAGGR/TaggrAPI/CandidEncoder.swift",
    "ios/TAGGR/TAGGR/TaggrIdentity/IdentityWebView.swift",
    "ios/TAGGR/TAGGR/TaggrNavigation/TaggrNavigation.swift",
    "ios/TAGGR/TAGGR/TAGGR.entitlements",
];

const read = (path) => fs.readFileSync(path, "utf8");
const missing = required.filter((path) => !fs.existsSync(path));
const failures = [];

if (missing.length) failures.push(`missing files: ${missing.join(", ")}`);
if (fs.existsSync("src-tauri")) failures.push("src-tauri must be removed");

const project = read("ios/TAGGR/TAGGR.xcodeproj/project.pbxproj");
if (!project.includes("PRODUCT_BUNDLE_IDENTIFIER = network.taggr.ios")) {
    failures.push("Swift app bundle id must be network.taggr.ios");
}

const entitlements = read("ios/TAGGR/TAGGR/TAGGR.entitlements");
if (!entitlements.includes("applinks:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io")) {
    failures.push("Associated Domains entitlement is missing canonical TAGGR host");
}

const api = read("ios/TAGGR/TAGGR/TaggrAPI/TaggrAPI.swift");
if (api.includes("icp_transfer") || api.includes("icrc_transfer")) {
    failures.push("App Store iOS build must not expose ICP/ICRC transfer APIs");
}

const packageJson = read("package.json");
if (packageJson.includes("@tauri-apps/") || packageJson.includes("\"tauri\"")) {
    failures.push("package.json must not contain Tauri dependencies or scripts");
}

if (failures.length) {
    console.error("Swift iOS audit failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
}

console.log("Swift iOS audit passed.");
