#!/usr/bin/env node
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const project = "ios/TAGGR/TAGGR.xcodeproj";
const scheme = "TAGGR";
const bundleId = "network.taggr.ios";
const teamId = "AKN976G7AK";
const productionCanister = "6qfxa-ryaaa-aaaai-qbhsq-cai";
const dryRun = process.argv.includes("--dry-run");

function tokyoTimestamp() {
    const parts = new Intl.DateTimeFormat("en-US", {
        timeZone: "Asia/Tokyo",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
        hourCycle: "h23",
    }).formatToParts(new Date());
    const value = Object.fromEntries(
        parts
            .filter((part) => part.type !== "literal")
            .map((part) => [part.type, part.value]),
    );
    return `${value.year}${value.month}${value.day}${value.hour}${value.minute}`;
}

function buildNumber() {
    const value = process.env.TAGGR_BUILD_NUMBER || tokyoTimestamp();
    if (!/^\d{12}$/.test(value)) {
        throw new Error(
            `TAGGR_BUILD_NUMBER must match YYYYMMDDHHmm, got ${value}.`,
        );
    }
    return value;
}

function readMarketingVersion() {
    const args = [
        "-project",
        project,
        "-scheme",
        scheme,
        "-configuration",
        "Release",
        "-showBuildSettings",
    ];
    const result = spawnSync("xcodebuild", args, {
        encoding: "utf8",
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
        const details = [result.stdout, result.stderr]
            .filter(Boolean)
            .join("\n");
        throw new Error(
            `xcodebuild ${args.join(" ")} failed while reading MARKETING_VERSION.\n${details}`,
        );
    }
    const match = result.stdout.match(/^\s*MARKETING_VERSION\s*=\s*(\S+)\s*$/m);
    if (!match) {
        throw new Error(
            "MARKETING_VERSION was not found in Xcode build settings.",
        );
    }
    return match[1];
}

function run(command, args) {
    const result = spawnSync(command, args, { stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0) {
        throw new Error(`${command} ${args.join(" ")} failed.`);
    }
}

function exportOptionsPlist() {
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>destination</key>
\t<string>upload</string>
\t<key>distributionBundleIdentifier</key>
\t<string>${bundleId}</string>
\t<key>manageAppVersionAndBuildNumber</key>
\t<false/>
\t<key>method</key>
\t<string>app-store-connect</string>
\t<key>signingStyle</key>
\t<string>automatic</string>
\t<key>stripSwiftSymbols</key>
\t<true/>
\t<key>teamID</key>
\t<string>${teamId}</string>
\t<key>uploadSymbols</key>
\t<true/>
</dict>
</plist>
`;
}

function writeExportOptions(file) {
    const contents = exportOptionsPlist();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, contents);
    return contents;
}

const currentBuildNumber = buildNumber();
const marketingVersion = readMarketingVersion();
const archivePath = path.join(
    ".build",
    "testflight",
    `TAGGR-${marketingVersion}-${currentBuildNumber}.xcarchive`,
);
const derivedDataPath = path.join(".build", "testflight-derived");
const exportPath = path.join(
    ".build",
    "testflight-upload",
    `${marketingVersion}-${currentBuildNumber}`,
);
const exportOptionsPath = path.join(
    ".build",
    "testflight-export-options.plist",
);

const archiveArgs = [
    "-project",
    project,
    "-scheme",
    scheme,
    "-configuration",
    "Release",
    "-destination",
    "generic/platform=iOS",
    "-archivePath",
    archivePath,
    "-derivedDataPath",
    derivedDataPath,
    "-allowProvisioningUpdates",
    "archive",
    `MARKETING_VERSION=${marketingVersion}`,
    `CURRENT_PROJECT_VERSION=${currentBuildNumber}`,
];

const uploadArgs = [
    "-exportArchive",
    "-archivePath",
    archivePath,
    "-exportPath",
    exportPath,
    "-exportOptionsPlist",
    exportOptionsPath,
    "-allowProvisioningUpdates",
];

console.log(`Version: ${marketingVersion} (${currentBuildNumber})`);
console.log(`App Store Connect build label: ビルド${currentBuildNumber}`);
console.log(`Bundle: ${bundleId}`);
console.log(`Default network: Mainnet ${productionCanister}`);
console.log(`Archive: ${archivePath}`);
console.log(`Export options path: ${exportOptionsPath}`);

const exportOptionsContents = writeExportOptions(exportOptionsPath);

if (dryRun) {
    console.log("Export options:");
    console.log(exportOptionsContents.trimEnd());
    console.log("Archive command:");
    console.log(`xcodebuild ${archiveArgs.join(" ")}`);
    console.log("Upload command:");
    console.log(`xcodebuild ${uploadArgs.join(" ")}`);
    process.exit(0);
}

run("xcodebuild", archiveArgs);
run("xcodebuild", uploadArgs);
