const fs = require("fs");
const { spawnSync } = require("child_process");

const APP_HOST = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
const APP_URL = `https://${APP_HOST}`;

const run = (label, cmd, args, options = {}) => {
    const result = spawnSync(cmd, args, {
        encoding: "utf8",
        stdio: "pipe",
        ...options,
    });
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    return {
        label,
        ok: result.status === 0,
        output: output.trim(),
    };
};

const read = (path) => fs.readFileSync(path, "utf8");
const has = (path, text) => fs.existsSync(path) && read(path).includes(text);
const tauriSrc = () =>
    fs
        .readdirSync("src-tauri/src")
        .filter((file) => file.endsWith(".rs"))
        .map((file) => read(`src-tauri/src/${file}`))
        .join("\n");
const tauriHas = (text) => tauriSrc().includes(text);
const launchHas = (text) =>
    has("src-tauri/gen/apple/LaunchScreen.storyboard", text);
const commonHas = (text) => has("src/frontend/src/common.tsx", text);
const evidence = [
    {
        name: "Tauri v2 iOS app base exists",
        ok:
            fs.existsSync("src-tauri/Cargo.toml") &&
            fs.existsSync("src-tauri/tauri.conf.json") &&
            fs.existsSync("src-tauri/gen/apple/project.yml") &&
            launchHas("TAGGR") &&
            launchHas("activityIndicatorView"),
    },
    {
        name: "Existing TAGGR production URL is configured",
        ok:
            tauriHas(APP_URL) &&
            tauriHas("Url::parse(ERROR_START_URL)") &&
            tauriHas("bootstrap_target_url") &&
            tauriHas("contains_supported_deep_link") &&
            tauriHas("external_initial_links") &&
            tauriHas("location.href = TAGGR_APP_URL") &&
            has("src-tauri/tauri.conf.json", APP_URL),
    },
    {
        name: "Deep link and universal link code exists",
        ok:
            tauriHas("map_deep_link") &&
            tauriHas("route_to_app_url") &&
            has(
                "src-tauri/gen/apple/taggr-ios_iOS/taggr-ios_iOS.entitlements",
                `applinks:${APP_HOST}`,
            ),
    },
    {
        name: "iOS share sheet command exists",
        ok:
            tauriHas("share_url") &&
            tauriHas("UIActivityViewController") &&
            tauriHas("popoverPresentationController") &&
            tauriHas("setSourceView") &&
            tauriHas("url.username().is_empty()") &&
            tauriHas("url.query().is_none()") &&
            has("src-tauri/capabilities/default.json", "capabilities.json") &&
            fs.existsSync("src-tauri/gen/schemas/capabilities.json") &&
            has("src-tauri/capabilities/default.json", "allow-share-url") &&
            !has("src-tauri/capabilities/default.json", "core:default"),
    },
    {
        name: "External link separation exists",
        ok:
            tauriHas("handle_navigation") &&
            tauriHas("should_open_externally") &&
            tauriHas("app.opener().open_url") &&
            tauriHas("originalWindowOpen") &&
            tauriHas("isIdentityUrl"),
    },
    {
        name: "Error screen and reload path exists",
        ok:
            tauriHas("taggr-ios-error") &&
            tauriHas("location.reload()") &&
            tauriHas("ERROR_PAGE_URL") &&
            tauriHas("error_page_url") &&
            tauriHas("about:blank#taggr-ios-error") &&
            tauriHas("on_web_content_process_terminate") &&
            tauriHas("FIRST_LOAD_TIMEOUT_MS") &&
            tauriHas("bootstrap_target_url") &&
            tauriHas("isBootstrapDocument") &&
            tauriHas("isAppDocument") &&
            tauriHas("!isBootstrapDocument() && !isAppDocument()") &&
            tauriHas("navigateToApp") &&
            tauriHas("initial_webview_url"),
    },
    {
        name: "Push notification scope is Phase 2 only",
        ok:
            has("docs/ios/tauri_requirements.md", "Push Notifications") &&
            has("docs/ios/tauri_requirements.md", "Phase 2 only") &&
            !tauriHas("push_notification") &&
            !tauriHas("notification") &&
            !has("src-tauri/Cargo.toml", "push-notification") &&
            !has("src-tauri/Cargo.toml", "apns"),
    },
    {
        name: "App Review privacy/support/token policy artifacts exist",
        ok:
            fs.existsSync("docs/ios/app_store_review.md") &&
            fs.existsSync("docs/ios/submission_runbook.md") &&
            fs.existsSync("docs/ios/app_privacy_answers.md") &&
            fs.existsSync("src/frontend/src/privacy.tsx") &&
            has("src/frontend/src/links.tsx", 'href="#/privacy"') &&
            commonHas("IOSReadOnlyTokenNotice") &&
            has("src/frontend/src/settings.tsx", 'shareLink="settings"') &&
            commonHas("shareOrigin = isIOSApp()") &&
            commonHas("toIOSUniversalLinkPath") &&
            commonHas("supported ? `/${route}` : url") &&
            commonHas("TAGGR_CANONICAL_DOMAIN") &&
            commonHas(APP_HOST) &&
            commonHas("window.backendCache.stats?.canister_id") &&
            commonHas("if (!firstSegment) return url") &&
            commonHas('"post"') &&
            commonHas('"user"') &&
            commonHas('"realm"') &&
            commonHas('"transaction"') &&
            commonHas('"transactions"') &&
            commonHas('"tokens"') &&
            commonHas("getCanonicalDomain()") &&
            has(
                "src/frontend/src/wallet.tsx",
                "Credit minting is unavailable in the iOS app.",
            ) &&
            has(
                "src/frontend/src/welcome.tsx",
                "Use an invite or the web app",
            ) &&
            has("src/frontend/src/distribution.tsx", "!isIOSApp()") &&
            has("src/frontend/src/distribution.tsx", "delay_weekly_chores") &&
            has("src/frontend/src/settings.tsx", "nextSettings.icrcWallet") &&
            has("src/frontend/src/form.tsx", "IOS_PROPOSAL_TYPES") &&
            has(
                "src/frontend/src/proposals.tsx",
                "token and ICP transfer proposals are read-only",
            ),
    },
];

const commandGates = [
    run("static Tauri iOS audit", "npm", ["run", "ios:audit"]),
    run("Tauri Rust tests", "cargo", [
        "test",
        "--manifest-path",
        "src-tauri/Cargo.toml",
    ]),
    run("backend AASA asset test", "cargo", [
        "test",
        "-p",
        "taggr",
        "assets::tests::serves_aasa_from_well_known_and_root_paths",
    ]),
    run("backend AASA HTTP test", "cargo", [
        "test",
        "-p",
        "taggr",
        "http::test::should_serve_aasa_without_upgrade",
    ]),
    run("backend full tests", "cargo", [
        "test",
        "-p",
        "taggr",
        "--",
        "--test-threads=1",
    ]),
    run("iOS plist lint", "plutil", [
        "-lint",
        "src-tauri/Info.ios.plist",
        "src-tauri/gen/apple/taggr-ios_iOS/Info.plist",
        "src-tauri/gen/apple/taggr-ios_iOS/taggr-ios_iOS.entitlements",
    ]),
    run("TypeScript typecheck", "./node_modules/.bin/tsc", ["--noEmit"]),
    run("production frontend build", "npm", ["run", "build"], {
        env: { ...process.env, NODE_ENV: "production" },
    }),
    run("iOS authored file line counts", "npm", ["run", "ios:lines"]),
    run("dfx 0.32.0 is available", "npm", ["run", "ios:dfx"]),
    run("production dfx identity is available", "npm", ["run", "ios:identity"]),
    run("production canister wasm build", "make", ["build"]),
    run("deploy readiness check", "npm", ["run", "ios:deploy:ready"]),
    run("local iOS frontend bundle check", "npm", [
        "run",
        "ios:frontend:local",
    ]),
    run("local AASA build output check", "npm", ["run", "ios:aasa:local"]),
    run("diff whitespace check", "git", ["diff", "--check"]),
    run("signed iOS build preflight", "npm", [
        "run",
        "ios:preflight",
        "--",
        "--build",
    ]),
    run("App Review preflight", "npm", ["run", "ios:review"]),
    run("production AASA check", "npm", ["run", "ios:aasa"]),
    run("external blocker check", "npm", ["run", "ios:blockers"]),
];

const deviceDoc = "docs/ios/device_verification.md";
const deviceFilled =
    fs.existsSync(deviceDoc) && !read(deviceDoc).includes("TODO");
const deviceHas = (text) => deviceFilled && has(deviceDoc, text);
const acceptanceEvidence = [
    ["Device verification evidence fields are filled", deviceFilled],
    ["Simulator launch verified", deviceHas("Simulator launch: PASS")],
    [
        "Physical device launch verified",
        deviceHas("Physical device launch: PASS"),
    ],
    [
        "Production canonical URL loads on iOS",
        deviceHas("Production URL load: PASS"),
    ],
    [
        "Internet Identity preserves TAGGR account identity",
        deviceHas("Internet Identity continuity: PASS"),
    ],
    [
        "Internal navigation stays in app",
        deviceHas("Internal navigation: PASS"),
    ],
    [
        "External navigation opens outside app",
        deviceHas("External navigation: PASS"),
    ],
    [
        "Universal and deep links open target TAGGR route",
        deviceHas("Universal link: PASS") && deviceHas("Deep link: PASS"),
    ],
    [
        "iOS share sheet opens with current TAGGR URL",
        deviceHas("Share sheet: PASS"),
    ],
    [
        "Offline or failed load shows reloadable error UI",
        deviceHas("Offline reload UI: PASS"),
    ],
    [
        "iPhone SE report/block/contact reachability verified",
        deviceHas("iPhone SE moderation reachability: PASS"),
    ],
].map(([name, ok]) => ({ name, ok }));

console.log(
    "Objective: implement every requirement in docs/ios/tauri_requirements.md.",
);
console.log("");
console.log("Prompt-to-artifact checklist:");

for (const item of evidence) {
    console.log(`${item.ok ? "PASS" : "FAIL"} ${item.name}`);
    if (!item.ok) process.exitCode = 1;
}

console.log("");
console.log("Command gates:");

for (const gate of commandGates) {
    console.log(`${gate.ok ? "PASS" : "FAIL"} ${gate.label}`);
    if (!gate.ok) {
        process.exitCode = 1;
        if (gate.output) {
            const start = gate.label === "external blocker check" ? 0 : -20;
            const lines = gate.output.split("\n").slice(start);
            for (const line of lines) console.log(`  ${line}`);
        }
    }
}

console.log("");
console.log("Acceptance evidence:");

for (const item of acceptanceEvidence) {
    console.log(`${item.ok ? "PASS" : "FAIL"} ${item.name}`);
    if (!item.ok) process.exitCode = 1;
}

if (process.exitCode) {
    console.log("");
    console.log("iOS completion audit failed.");
    console.log(
        "The goal is not complete until every checklist item and command gate passes.",
    );
} else console.log("\niOS completion audit passed.");
