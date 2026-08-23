#!/usr/bin/env node
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const project = "ios/TAGGR/TAGGR.xcodeproj";
const scheme = "TAGGR";
const bundleId = "network.taggr.ios";
const derivedDataPath =
    process.env.IOS_DERIVED_DATA_PATH || ".build/xcode-staging-device";
const entitlementsPath = ".build/TAGGR-staging-device.entitlements";
const network = process.env.IOS_STAGING_NETWORK || "staging";
const identityURL = process.env.TAGGR_II_URL || "https://id.ai/authorize";
const apiBaseURL = process.env.TAGGR_API_BASE_URL || "https://ic0.app";
const canisterIds = JSON.parse(fs.readFileSync("canister_ids.json", "utf8"));
const canisterId =
    process.env.TAGGR_CANISTER_ID || canisterIds.taggr?.[network];

if (!canisterId) {
    throw new Error(`Missing taggr canister id for ${network}.`);
}

const domain = process.env.TAGGR_DOMAIN || `${canisterId}.icp0.io`;
const callbackDomain = `${canisterId}.icp0.io`;
const derivationOrigin =
    process.env.TAGGR_DERIVATION_ORIGIN || `https://${domain}`;

const childProcessPath = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    process.env.PATH || "",
]
    .filter(Boolean)
    .join(":");

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        encoding: "utf8",
        env: { ...process.env, PATH: childProcessPath },
        stdio: options.capture ? "pipe" : "inherit",
        ...options,
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
        const output = [result.stdout, result.stderr]
            .filter(Boolean)
            .join("\n");
        throw new Error(
            `${command} ${args.join(" ")} failed with ${result.status}${output ? `\n${output}` : ""}`,
        );
    }
    return result.stdout?.trim() || "";
}

function connectedDeviceId() {
    if (process.env.IOS_DEVICE_ID) return process.env.IOS_DEVICE_ID;
    const output = run("xcrun", ["xctrace", "list", "devices"], {
        capture: true,
    });
    const devices = output.split("== Simulators ==")[0] || "";
    const match = devices.match(/\(([0-9A-F]{8}-[0-9A-F]{16})\)/);
    if (!match) {
        throw new Error(
            "No physical iOS device found. Set IOS_DEVICE_ID to the target device UDID.",
        );
    }
    return match[1];
}

function writeEntitlements() {
    const domains = [
        "applinks:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
        "webcredentials:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
        `applinks:${callbackDomain}`,
        `webcredentials:${callbackDomain}`,
    ];
    fs.mkdirSync(path.dirname(entitlementsPath), { recursive: true });
    fs.writeFileSync(
        entitlementsPath,
        `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>com.apple.developer.associated-domains</key>
\t<array>
${domains.map((value) => `\t\t<string>${value}</string>`).join("\n")}
\t</array>
</dict>
</plist>
`,
    );
}

writeEntitlements();
const deviceId = connectedDeviceId();
const entitlements = path.resolve(entitlementsPath);

console.log(`==> building ${network} iOS app for device ${deviceId}`);
run("xcodebuild", [
    "-project",
    project,
    "-scheme",
    scheme,
    "-configuration",
    "Debug",
    "-destination",
    `id=${deviceId}`,
    "-derivedDataPath",
    derivedDataPath,
    "build",
    `TAGGR_CANISTER_ID=${canisterId}`,
    `TAGGR_API_BASE_URL=${apiBaseURL}`,
    `TAGGR_DOMAIN=${domain}`,
    `TAGGR_CALLBACK_DOMAIN=${callbackDomain}`,
    `TAGGR_II_URL=${identityURL}`,
    `TAGGR_DERIVATION_ORIGIN=${derivationOrigin}`,
    `CODE_SIGN_ENTITLEMENTS=${entitlements}`,
]);

const appPath = path.join(
    process.cwd(),
    derivedDataPath,
    "Build/Products/Debug-iphoneos/TAGGR.app",
);

console.log("==> installing and launching TAGGR");
run("xcrun", [
    "devicectl",
    "device",
    "install",
    "app",
    "--device",
    deviceId,
    appPath,
]);
run("xcrun", [
    "devicectl",
    "device",
    "process",
    "launch",
    "--device",
    deviceId,
    bundleId,
]);

console.log(`Network: ${network}`);
console.log(`Canister: ${canisterId}`);
console.log(`TAGGR: ${derivationOrigin}`);
console.log(`Callback: https://${callbackDomain}/ios-auth-callback`);
console.log(`Identity Provider: ${identityURL}`);
