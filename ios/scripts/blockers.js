const fs = require("fs");
const { spawnSync } = require("child_process");

const identity = process.env.IOS_ICP_IDENTITY || "prod";
const productionCanister = "6qfxa-ryaaa-aaaai-qbhsq-cai";
const run = (label, cmd, args, options = {}) => {
    const result = spawnSync(cmd, args, {
        encoding: "utf8",
        stdio: "pipe",
        timeout: 20_000,
        ...options,
    });
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    const ok = result.status === 0;
    console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
    if (!ok && output.trim()) console.log(output.trim());
    return ok;
};

const read = (path) => fs.readFileSync(path, "utf8");
const hasNoPlaceholders = () => {
    const review = read("ios/docs/app_store_review.md");
    return ![
        "<email or Internet Identity instructions>",
        "<invite code>",
        "<support contact>",
        "APPREVIEW-TODO-PRODUCTION-INVITE",
    ].some((placeholder) => review.includes(placeholder));
};

const deviceEvidenceComplete = () => {
    const deviceDoc = read("ios/docs/device_verification.md");
    return (
        !deviceDoc.includes("TODO") &&
        [
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
        ].every((text) => deviceDoc.includes(text))
    );
};

let failed = false;
const check = (ok) => {
    if (!ok) failed = true;
};

check(run("full Xcode is selected", "xcodebuild", ["-version"]));
check(
    run("iOS simulator runtime is available", "xcrun", [
        "simctl",
        "list",
        "runtimes",
        "--json",
    ]),
);
check(
    run("iphoneos SDK is available", "xcrun", [
        "--show-sdk-path",
        "--sdk",
        "iphoneos",
    ]),
);
check(
    run("production icp identity is available", "npm", ["run", "ios:identity"]),
);
check(
    run("production canister controller access is available", "icp", [
        "canister",
        "status",
        "--identity",
        identity,
        "--network",
        "ic",
        productionCanister,
    ]),
);
check(run("production AASA is live", "npm", ["run", "ios:aasa"]));

const reviewOk = hasNoPlaceholders();
console.log(`${reviewOk ? "PASS" : "FAIL"} App Review access data is filled`);
check(reviewOk);

const deviceOk = deviceEvidenceComplete();
console.log(`${deviceOk ? "PASS" : "FAIL"} iOS device evidence is complete`);
check(deviceOk);

if (failed) {
    console.error("iOS external blockers remain.");
    process.exit(1);
}

console.log("No iOS external blockers detected.");
