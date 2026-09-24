#!/usr/bin/env node
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const project = "ios/TAGGR/TAGGR.xcodeproj";
const scheme = "TAGGR";
const bundleId = "network.taggr.ios";
const derivedDataPath = ".build/xcode-local-device";
const localGatewayPort = "8000";
const previousLocalGatewayPort = "8001";
const staleLocalGatewayPort = "4943";
const localEntitlementsPath = ".build/TAGGR-local-device.entitlements";
const taggrCloudflaredLogPath = ".build/cloudflared-taggr-local-device.log";
const proxyScriptPath = "ios/scripts/host-header-proxy.js";
const frontendDistPath = "dist/frontend";
const taggrProxyPort = "8121";
const localTaggrDomain = "localhost";
const icpBin = process.env.ICP_BIN || "/Users/0xhude/.local/bin/icp";
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

function sleep(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function runOptional(command, args) {
    const result = spawnSync(command, args, {
        encoding: "utf8",
        env: { ...process.env, PATH: childProcessPath },
        stdio: "ignore",
        timeout: 10000,
    });
    return result.status === 0;
}

function commandExists(command) {
    const result = spawnSync("which", [command], {
        encoding: "utf8",
        env: { ...process.env, PATH: childProcessPath },
        stdio: "ignore",
        timeout: 10000,
    });
    return result.status === 0;
}

function pidsListeningOn(port) {
    const result = spawnSync("lsof", ["-nP", `-tiTCP:${port}`], {
        encoding: "utf8",
        stdio: "pipe",
    });
    return result.stdout?.split(/\s+/).filter(Boolean) || [];
}

function pidsMatching(pattern) {
    const result = spawnSync("pgrep", ["-f", pattern], {
        encoding: "utf8",
        stdio: "pipe",
    });
    return result.stdout?.split(/\s+/).filter(Boolean) || [];
}

function stopExistingCloudflared() {
    const pids = pidsMatching("cloudflared tunnel --url http://127.0.0.1:");
    for (const pid of pids) runOptional("kill", [pid]);
    if (pids.length > 0) sleep(1000);
    for (const pid of pids) runOptional("kill", ["-9", pid]);
}

function stopExistingProxy() {
    const pids = pidsListeningOn(taggrProxyPort);
    for (const pid of pids) runOptional("kill", [pid]);
    sleep(1000);
}

function ensureLocalNetwork() {
    stopLocalNetwork();
    run(icpBin, ["network", "start", "-d"]);
    if (!localNetworkListening()) {
        throw new Error(
            `Local icp network is not listening on 127.0.0.1:${localGatewayPort}.`,
        );
    }
}

function stopLocalNetwork() {
    runOptional(icpBin, ["network", "stop"]);
    const pids = [
        ...pidsListeningOn(localGatewayPort),
        ...pidsListeningOn(previousLocalGatewayPort),
        ...pidsListeningOn(staleLocalGatewayPort),
    ];
    for (const pid of pids) runOptional("kill", [pid]);
    if (pids.length > 0) sleep(1000);
    for (const pid of pids) runOptional("kill", ["-9", pid]);
}

function apiURL() {
    return `http://127.0.0.1:${localGatewayPort}`;
}

function localNetworkListening() {
    const result = spawnSync("lsof", ["-nP", `-tiTCP:${localGatewayPort}`], {
        encoding: "utf8",
        stdio: "pipe",
    });
    return result.status === 0 && result.stdout.trim().length > 0;
}

function deployTaggr() {
    if (process.env.TAGGR_SKIP_LOCAL_DEPLOY === "1") {
        console.log("==> skipping local TAGGR canister deploy");
        return;
    }
    run(icpBin, ["deploy", "taggr", "--mode", "auto"]);
}

function taggrCanisterId() {
    return run(icpBin, ["canister", "status", "taggr", "-e", "local", "-i"], {
        capture: true,
    });
}

function writeFile(filePath, body) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, body);
}

function startProxy(
    listenPort,
    upstreamHost,
    upstreamPort,
    staticRoot = frontendDistPath,
) {
    const args = [proxyScriptPath, listenPort, upstreamHost, upstreamPort];
    if (staticRoot) args.push(staticRoot);
    const child = spawn(process.execPath, args, {
        detached: true,
        env: { ...process.env, PATH: childProcessPath },
        stdio: "ignore",
    });
    child.unref();
    return child;
}

function startCloudflared(originPort, logPath) {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.writeFileSync(logPath, "");
    const fd = fs.openSync(logPath, "a");
    const child = spawn(
        "cloudflared",
        [
            "tunnel",
            "--url",
            `http://127.0.0.1:${originPort}`,
            "--no-autoupdate",
            "--edge-ip-version",
            "4",
        ],
        {
            detached: true,
            env: { ...process.env, PATH: childProcessPath },
            stdio: ["ignore", fd, fd],
        },
    );
    child.unref();
    return child;
}

function waitForCloudflaredTunnel(logPath) {
    let lastLog = "";
    for (let i = 0; i < 60; i += 1) {
        if (fs.existsSync(logPath)) {
            lastLog = fs.readFileSync(logPath, "utf8");
            const match = lastLog.match(
                /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i,
            );
            if (match) return match[0];
        }
        sleep(1000);
    }
    throw new Error(`cloudflared tunnel did not start.\n${lastLog}`);
}

function assertSupportedTunnelProvider() {
    if (process.env.TAGGR_TUNNEL_PROVIDER === "ngrok") {
        throw new Error(
            "TAGGR_TUNNEL_PROVIDER=ngrok is not supported for local device auth. Install cloudflared and use HTTPS tunnels.",
        );
    }
}

function startPublicTunnel(originPort, logPath) {
    assertSupportedTunnelProvider();
    if (!commandExists("cloudflared")) {
        throw new Error(
            "cloudflared is required for local device auth. LAN HTTP origins are blocked by browser passkey requirements.",
        );
    }
    const child = startCloudflared(originPort, logPath);
    return { child, origin: waitForCloudflaredTunnel(logPath) };
}

function httpStatus(url) {
    return runCurl(
        [
            "--noproxy",
            "*",
            "-sS",
            "-L",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            url,
        ],
        url,
    );
}

function httpBody(url) {
    return runCurl(["--noproxy", "*", "-sS", "-L", url], url);
}

function curlResolveArgs(url) {
    const parsed = new URL(url);
    if (
        parsed.protocol !== "https:" ||
        !parsed.hostname.endsWith(".trycloudflare.com") ||
        !commandExists("dig")
    ) {
        return [];
    }
    const output = run("dig", ["+short", parsed.hostname, "@1.1.1.1"], {
        capture: true,
    });
    const ip = output
        .split(/\s+/)
        .find((line) => /^\d+\.\d+\.\d+\.\d+$/.test(line));
    return ip ? ["--resolve", `${parsed.hostname}:443:${ip}`] : [];
}

function runCurl(args, url) {
    try {
        return run("curl", args, { capture: true });
    } catch (error) {
        const resolveArgs = curlResolveArgs(url);
        if (resolveArgs.length === 0) throw error;
        return run("curl", [...resolveArgs, ...args], { capture: true });
    }
}

function waitForHTTPStatus(url, expectedStatus, attempts = 240) {
    let lastStatus = "";
    for (let i = 0; i < attempts; i += 1) {
        try {
            lastStatus = httpStatus(url);
            if (lastStatus === expectedStatus) return;
        } catch (error) {
            lastStatus = error.message;
        }
        sleep(500);
    }
    throw new Error(
        `${url} did not return HTTP ${expectedStatus}. Last status: ${lastStatus}`,
    );
}

function stopProcess(child) {
    if (!child?.pid) return;
    runOptional("kill", [String(child.pid)]);
    sleep(1000);
    runOptional("kill", ["-9", String(child.pid)]);
}

function startReachablePublicTunnel(originPort, logPath) {
    let lastError = null;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
        const tunnel = startPublicTunnel(originPort, logPath);
        try {
            waitForHTTPStatus(tunnel.origin, "200");
            return tunnel.origin;
        } catch (error) {
            lastError = error;
            console.warn(
                `Cloudflare quick Tunnel is not reachable yet; retrying (${attempt}/3).`,
            );
            stopProcess(tunnel.child);
        }
    }
    throw lastError;
}

function checkAASA(taggrOrigin) {
    const url = `${taggrOrigin}/.well-known/apple-app-site-association`;
    const body = httpBody(url);
    const data = JSON.parse(body);
    const detail = data?.applinks?.details?.[0];
    if (detail?.appID !== "AKN976G7AK.network.taggr.ios") {
        throw new Error(`AASA at ${url} has unexpected appID.`);
    }
    if (JSON.stringify(detail?.paths) !== JSON.stringify(["/*"])) {
        throw new Error(`AASA at ${url} must publish path /*.`);
    }
    if (!data?.webcredentials?.apps?.includes("AKN976G7AK.network.taggr.ios")) {
        throw new Error(
            `AASA at ${url} must publish webcredentials for TAGGR.`,
        );
    }
}

function axResponse(url) {
    const args = [url, "--fresh", "--headers"];
    try {
        return JSON.parse(run("ax", args, { capture: true }));
    } catch (initialError) {
        const parsed = new URL(url);
        const address = run("dig", ["+short", parsed.hostname, "@1.1.1.1"], {
            capture: true,
        })
            .split(/\s+/)
            .find((line) => /^\d+\.\d+\.\d+\.\d+$/.test(line));
        if (!address) throw initialError;
        const resolvedURL = new URL(url);
        resolvedURL.hostname = address;
        return JSON.parse(
            run(
                "ax",
                [
                    resolvedURL.toString(),
                    "-k",
                    "-H",
                    `host: ${parsed.host}`,
                    "--fresh",
                    "--headers",
                ],
                { capture: true },
            ),
        );
    }
}

function checkICRC167Callbacks(taggrOrigin) {
    const callbacksURL = `${taggrOrigin}/.well-known/ii-auth-callbacks`;
    const callbacksResponse = axResponse(callbacksURL);
    const expectedCallback = `${taggrOrigin}/ios-auth-callback`;
    if (callbacksResponse.status !== 200) {
        throw new Error(`${callbacksURL} must return HTTP 200.`);
    }
    if (callbacksResponse.headers?.["access-control-allow-origin"] !== "*") {
        throw new Error(`${callbacksURL} must return CORS allow-origin *.`);
    }
    if (!callbacksResponse.body?.callbacks?.includes(expectedCallback)) {
        throw new Error(`${callbacksURL} must declare ${expectedCallback}.`);
    }

    const callbackResponse = axResponse(expectedCallback);
    if (
        callbackResponse.status !== 200 ||
        !String(callbackResponse.body).includes("Authentication complete")
    ) {
        throw new Error(
            `${expectedCallback} must be a terminal HTTP 200 page.`,
        );
    }
}

function writeLocalEntitlements(taggrHost) {
    const domains = [
        "applinks:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
        "webcredentials:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
        `applinks:${taggrHost}`,
        `webcredentials:${taggrHost}`,
    ];
    writeFile(
        localEntitlementsPath,
        `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>com.apple.developer.associated-domains</key>
\t<array>
${domains.map((domain) => `\t\t<string>${domain}</string>`).join("\n")}
\t</array>
</dict>
</plist>
`,
    );
}

function hostFromOrigin(origin) {
    return new URL(origin).host;
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

function main() {
    assertSupportedTunnelProvider();
    console.log("==> starting local icp network");
    ensureLocalNetwork();
    const port = localGatewayPort;
    const apiBaseURL = apiURL();

    console.log("==> building frontend assets");
    run("npm", ["run", "build"]);

    console.log("==> deploying local TAGGR canister");
    deployTaggr();
    const canisterId = taggrCanisterId();

    console.log("==> starting public HTTPS tunnels");
    stopExistingCloudflared();
    stopExistingProxy();
    startProxy(taggrProxyPort, `${canisterId}.localhost:${port}`, port);
    waitForHTTPStatus(`http://127.0.0.1:${taggrProxyPort}`, "200");
    const taggrOrigin = startReachablePublicTunnel(
        taggrProxyPort,
        taggrCloudflaredLogPath,
    );
    const taggrHost = hostFromOrigin(taggrOrigin);
    const identityURL = process.env.TAGGR_II_URL || "https://id.ai/authorize";

    console.log("==> smoke check local device routes");
    checkAASA(taggrOrigin);
    checkICRC167Callbacks(taggrOrigin);
    writeLocalEntitlements(taggrHost);

    const deviceId = connectedDeviceId();
    console.log(`==> building iOS app for device ${deviceId}`);
    const buildArgs = [
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
        "-skipPackagePluginValidation",
        "build",
        `TAGGR_CANISTER_ID=${canisterId}`,
        `TAGGR_API_BASE_URL=${taggrOrigin}`,
        `TAGGR_DOMAIN=${localTaggrDomain}`,
        `TAGGR_CALLBACK_DOMAIN=${taggrHost}`,
        `TAGGR_II_URL=${identityURL}`,
        `TAGGR_DERIVATION_ORIGIN=${taggrOrigin}`,
    ];
    buildArgs.push(
        `CODE_SIGN_ENTITLEMENTS=${path.resolve(localEntitlementsPath)}`,
    );
    run("xcodebuild", buildArgs);

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

    console.log(`Local TAGGR: ${taggrOrigin}`);
    console.log(`Local callback: ${taggrOrigin}/ios-auth-callback`);
    console.log(`Identity Provider: ${identityURL}`);
    console.log(`Local API base: ${apiBaseURL}`);
    console.log(
        `Stop proxy/tunnel: pkill -f "host-header-proxy.js ${taggrProxyPort}"; pkill -f "cloudflared tunnel --url http://127.0.0.1:"`,
    );
}

main();
