const { spawnSync } = require("child_process");

const run = (label, cmd, args, options = {}) => {
    const result = spawnSync(cmd, args, {
        encoding: "utf8",
        stdio: "pipe",
        ...options,
    });

    if (result.status === 0) {
        console.log(`PASS ${label}`);
        return true;
    }

    console.error(`FAIL ${label}`);
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    if (output.trim()) console.error(output.trim());
    return false;
};

const runRequired = (label, cmd, args, options) => {
    if (!run(label, cmd, args, options)) process.exitCode = 1;
};

const checkMacOs = () => {
    if (process.platform === "darwin") {
        console.log("PASS host OS is macOS");
    } else {
        console.error(
            `FAIL host OS is macOS; current platform is ${process.platform}`,
        );
        process.exitCode = 1;
    }
};

const checkXcodeSelect = () => {
    const result = spawnSync("xcode-select", ["-p"], {
        encoding: "utf8",
        stdio: "pipe",
    });
    const path = result.stdout.trim();

    if (result.status === 0 && path.includes(".app/Contents/Developer")) {
        console.log(`PASS xcode-select points to full Xcode: ${path}`);
        return true;
    }

    console.error(
        `FAIL xcode-select points to full Xcode: ${path || "unavailable"}`,
    );
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    if (output.trim()) console.error(output.trim());
    process.exitCode = 1;
    return false;
};

const checkRustTargets = (targets) => {
    const result = spawnSync("rustup", ["target", "list", "--installed"], {
        encoding: "utf8",
        stdio: "pipe",
    });
    if (result.status !== 0) {
        console.error("FAIL Rust target list is readable");
        const output = [result.stdout, result.stderr]
            .filter(Boolean)
            .join("\n");
        if (output.trim()) console.error(output.trim());
        process.exitCode = 1;
        return;
    }

    const installed = new Set(result.stdout.split(/\s+/).filter(Boolean));
    for (const target of targets) {
        if (installed.has(target)) {
            console.log(`PASS Rust target ${target} is installed`);
        } else {
            console.error(`FAIL Rust target ${target} is installed`);
            process.exitCode = 1;
        }
    }
};

if (process.argv.includes("--help") || process.argv.includes("-h")) {
    console.log("Usage: npm run ios:preflight -- [--build]");
    console.log("");
    console.log(
        "Checks full Xcode, iOS SDK, static audit, Rust tests, and iOS target typecheck.",
    );
    console.log("Use --build to also run `tauri ios build`.");
    process.exit(0);
}

const build = process.argv.includes("--build");

checkMacOs();
runRequired("Node.js is available", "node", ["--version"]);
runRequired("npm is available", "npm", ["--version"]);
runRequired("Tauri CLI is available", "npm", ["run", "tauri", "--", "info"]);
runRequired("CocoaPods is available", "pod", ["--version"]);
runRequired("rustup is available", "rustup", ["--version"]);
runRequired("iOS plist files are valid", "plutil", [
    "-lint",
    "src-tauri/Info.ios.plist",
    "src-tauri/gen/apple/taggr-ios_iOS/Info.plist",
    "src-tauri/gen/apple/taggr-ios_iOS/taggr-ios_iOS.entitlements",
]);
runRequired("iOS launch storyboard XML is valid", "xmllint", [
    "--noout",
    "src-tauri/gen/apple/LaunchScreen.storyboard",
]);
checkRustTargets([
    "aarch64-apple-ios",
    "x86_64-apple-ios",
    "aarch64-apple-ios-sim",
]);

const xcodeSelectOk = checkXcodeSelect();
const xcodeOk = run("full Xcode is selected", "xcodebuild", ["-version"]);
const simulatorOk = run("iOS simulator runtime is available", "xcrun", [
    "simctl",
    "list",
    "runtimes",
    "--json",
]);
const sdkOk = run("iphoneos SDK is available", "xcrun", [
    "--show-sdk-path",
    "--sdk",
    "iphoneos",
]);
if (!xcodeSelectOk || !xcodeOk || !simulatorOk || !sdkOk) process.exitCode = 1;

runRequired("static iOS Tauri audit", "npm", ["run", "ios:audit"]);
runRequired("Tauri host Rust tests", "cargo", [
    "test",
    "--manifest-path",
    "src-tauri/Cargo.toml",
]);

if (xcodeOk && sdkOk) {
    runRequired("Tauri iOS target typecheck", "cargo", [
        "check",
        "--manifest-path",
        "src-tauri/Cargo.toml",
        "--target",
        "aarch64-apple-ios",
        "--lib",
    ]);
} else {
    console.log(
        "SKIP Tauri iOS target typecheck; full Xcode and iphoneos SDK are required.",
    );
}

if (build && xcodeOk && simulatorOk && sdkOk) {
    runRequired("Tauri iOS build", "npm", ["run", "ios:build"]);
} else if (build) {
    console.log(
        "SKIP Tauri iOS build; full Xcode, simulator runtime, and iphoneos SDK are required.",
    );
} else {
    console.log(
        "SKIP Tauri iOS build; run `npm run ios:preflight -- --build`.",
    );
}
