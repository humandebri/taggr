#!/usr/bin/env node
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const project = "ios/TAGGR/TAGGR.xcodeproj";
const scheme = "TAGGR";
const bundleId = "network.taggr.ios";
const derivedDataPath = ".build/xcode-local";
const backendArgsPath = ".icp/cache/init-args/internet_identity.did";
const frontendArgsPath = ".icp/cache/init-args/internet_identity_frontend.did";
const localGatewayPort = "8001";
const simulatorName = process.env.IOS_SIMULATOR_NAME || "iPhone 17";
const destination = process.env.IOS_SIMULATOR_ID
    ? `id=${process.env.IOS_SIMULATOR_ID}`
    : `platform=iOS Simulator,name=${simulatorName}`;

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        encoding: "utf8",
        stdio: options.capture ? "pipe" : "inherit",
        ...options,
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
        const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
        throw new Error(`${command} ${args.join(" ")} failed with ${result.status}${output ? `\n${output}` : ""}`);
    }
    return result.stdout?.trim() || "";
}

function runOptional(command, args) {
    const result = spawnSync(command, args, { encoding: "utf8", stdio: "inherit" });
    return result.status === 0;
}

function sleep(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function pidsUsingPort(port) {
    const result = spawnSync("lsof", ["-nP", `-tiTCP:${port}`], { encoding: "utf8", stdio: "pipe" });
    if (result.status !== 0 && result.status !== 1) {
        const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
        throw new Error(`lsof -nP -tiTCP:${port} failed with ${result.status}${output ? `\n${output}` : ""}`);
    }
    return result.stdout.split(/\s+/).filter(Boolean);
}

function releaseLocalGatewayPort() {
    const pids = pidsUsingPort(localGatewayPort);
    for (const pid of pids) run("kill", [pid]);
    if (pids.length > 0) sleep(3000);
}

function startNetwork() {
    try {
        run("icp", ["network", "start", "-d"]);
    } catch (error) {
        console.log("==> retrying icp local network start after port cleanup");
        releaseLocalGatewayPort();
        sleep(5000);
        run("icp", ["network", "start", "-d"]);
    }
}

function networkStatus() {
    const raw = run("icp", ["network", "status", "--json"], { capture: true });
    return JSON.parse(raw);
}

function apiURLFromStatus(status) {
    const value = status.api_url || status.apiUrl || status.gateway_url || status.gatewayUrl || "http://localhost:8000";
    return value.replace("localhost", "127.0.0.1").replace(/\/$/, "");
}

function localhostURLFromStatus(status, host) {
    const apiURL = new URL(status.api_url || status.apiUrl || status.gateway_url || status.gatewayUrl || "http://localhost:8000");
    return `${apiURL.protocol}//${host}:${apiURL.port || "8000"}`;
}

function portFromStatus(status) {
    const apiURL = new URL(status.api_url || status.apiUrl || status.gateway_url || status.gatewayUrl || "http://localhost:8000");
    return apiURL.port || "8000";
}

function httpStatus(url) {
    return run("curl", ["--noproxy", "*", "-sS", "-L", "-o", "/dev/null", "-w", "%{http_code}", url], { capture: true });
}

function writeInitArgs(filePath, args) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, args);
}

function renderInternetIdentityBackendArgs(status, frontendCanisterId, appCanisterId) {
    const port = portFromStatus(status);
    const frontendOrigin = `http://${frontendCanisterId}.localhost:${port}`;
    const frontendRawOrigin = `http://${frontendCanisterId}.raw.localhost:${port}`;
    const appOrigin = `http://${appCanisterId}.localhost:${port}`;
    const args = `(opt record {
  captcha_config = opt record {
    max_unsolved_captchas = 50:nat64;
    captcha_trigger = variant { Static = variant { CaptchaDisabled } };
  };
  related_origins = opt vec {
    "https://id.ai";
    "https://identity.ic0.app";
    "${frontendOrigin}";
    "${frontendRawOrigin}";
    "${appOrigin}";
  };
  new_flow_origins = opt vec {
    "https://id.ai";
    "${frontendOrigin}";
    "${frontendRawOrigin}";
    "${appOrigin}";
  };
  dummy_auth = opt opt record { prompt_for_index = true };
})`;
    writeInitArgs(backendArgsPath, args);
}

function renderInternetIdentityFrontendArgs(status, backendCanisterId, frontendCanisterId, appCanisterId) {
    const port = portFromStatus(status);
    const appOrigin = `http://${appCanisterId}.localhost:${port}`;
    const args = `(record {
  backend_canister_id = principal "${backendCanisterId}";
  backend_origin = "http://${backendCanisterId}.localhost:${port}";
  related_origins = opt vec {
    "http://${frontendCanisterId}.localhost:${port}";
    "http://${frontendCanisterId}.raw.localhost:${port}";
    "${appOrigin}";
  };
  fetch_root_key = opt true;
  analytics_config = null;
  dummy_auth = opt opt record { prompt_for_index = true };
  dev_csp = opt true;
  featured_dashboard_apps = opt vec {};
})`;
    writeInitArgs(frontendArgsPath, args);
}

function main() {
    console.log("==> starting icp local network");
    runOptional("icp", ["network", "stop"]);
    releaseLocalGatewayPort();
    sleep(5000);
    startNetwork();

    const status = networkStatus();
    run("icp", ["canister", "create", "internet_identity"]);
    run("icp", ["canister", "create", "internet_identity_frontend"]);
    run("icp", ["canister", "create", "taggr"]);
    const identityBackendCanisterId = run("icp", ["canister", "status", "internet_identity", "-i"], { capture: true });
    const identityFrontendCanisterId = run("icp", ["canister", "status", "internet_identity_frontend", "-i"], { capture: true });
    const canisterId = run("icp", ["canister", "status", "taggr", "-i"], { capture: true });
    renderInternetIdentityBackendArgs(status, identityFrontendCanisterId, canisterId);
    renderInternetIdentityFrontendArgs(status, identityBackendCanisterId, identityFrontendCanisterId, canisterId);

    console.log("==> deploying local Internet Identity backend");
    run("icp", ["deploy", "internet_identity", "--mode", "reinstall", "-y", "--args-file", backendArgsPath]);
    console.log("==> deploying local Internet Identity frontend");
    run("icp", ["deploy", "internet_identity_frontend", "--mode", "reinstall", "-y", "--args-file", frontendArgsPath]);
    console.log("==> deploying local TAGGR canister");
    run("icp", ["deploy", "taggr", "--mode", "reinstall", "-y"]);

    const apiBaseURL = apiURLFromStatus(status);
    const identityOrigin = localhostURLFromStatus(status, `${identityFrontendCanisterId}.localhost`);
    const identityURL = `${identityOrigin}/#authorize`;
    const authOrigin = localhostURLFromStatus(status, `${canisterId}.localhost`);

    console.log("==> smoke query local TAGGR canister");
    run("icp", ["canister", "call", "taggr", "icrc1_name", "()", "--query"]);
    console.log("==> smoke query local Internet Identity canister");
    run("icp", ["canister", "call", "internet_identity", "stats", "()", "--query"]);
    const identityStatus = httpStatus(identityURL);
    if (identityStatus !== "200") {
        throw new Error(`Local Internet Identity returned HTTP ${identityStatus}: ${identityURL}`);
    }

    console.log("==> building iOS app for local ICP");
    run("xcodebuild", [
        "-project", project,
        "-scheme", scheme,
        "-configuration", "Debug",
        "-destination", destination,
        "-derivedDataPath", derivedDataPath,
        "build",
        `TAGGR_CANISTER_ID=${canisterId}`,
        `TAGGR_API_BASE_URL=${apiBaseURL}`,
        "TAGGR_DOMAIN=localhost",
        `TAGGR_II_URL=${identityURL}`,
        `TAGGR_AUTH_ORIGIN=${authOrigin}`,
        "TAGGR_AUTOMATE_LOCAL_II=1",
    ]);

    const appPath = path.join(process.cwd(), derivedDataPath, "Build/Products/Debug-iphonesimulator/TAGGR.app");
    console.log(`==> booting simulator ${simulatorName}`);
    runOptional("xcrun", ["simctl", "boot", simulatorName]);
    run("xcrun", ["simctl", "bootstatus", simulatorName, "-b"]);

    console.log("==> installing and launching TAGGR");
    run("xcrun", ["simctl", "install", simulatorName, appPath]);
    run("xcrun", ["simctl", "launch", simulatorName, bundleId]);

    console.log(`Local TAGGR: ${authOrigin}`);
    console.log(`Local II: ${identityURL}`);
}

main();
