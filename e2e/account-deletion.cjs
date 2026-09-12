// Isolated recovery UI tests: no canister calls or asset transfers.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const webpack = require("webpack");
const { chromium } = require("@playwright/test");
const root = path.resolve(__dirname, "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "taggr-deletion-"));
fs.writeFileSync(
    path.join(temp, "mock.tsx"),
    `
import * as React from "react";
export const onCanonicalDomain = () => window.scenario !== "custom";
export const getCanonicalDomain = () => "test.icp0.io";
export const signOut = async () => { window.principalId = undefined; };
export const icrcTransfer = async () => {};
export const ICP_LEDGER_ID = "";
export const ICP_DEFAULT_FEE = 0;
export const ButtonWithLoading = ({label, onClick}) => {
 const [busy, setBusy] = React.useState(false);
 return <button disabled={busy} onClick={async () => { setBusy(true); await onClick(); setBusy(false); }}>{label}</button>;
};
export const fetchCanisterStatus = async () => {
 window.calls.push("status");
 if (window.scenario === "denied") throw Error("controller required");
 return { module_hash: window.scenario === "legacy" ? Array.from("418202879263a81a9479620628be4e0543367c178addb92d5fd5873ba23bde10".match(/../g), x => parseInt(x,16)) : [0] };
};
export const upgradeBucket = async () => { window.calls.push("upgrade"); };
`,
);
fs.writeFileSync(
    path.join(temp, "entry.tsx"),
    `
import * as React from "react";
import { createRoot } from "react-dom/client";
import { DeletedAccount, setDeletionStatus } from ${JSON.stringify(path.join(root, "src/frontend/src/account_deletion"))};
import { upgradeBucket as realUpgradeBucket } from ${JSON.stringify(path.join(root, "src/frontend/src/user_storage"))};
import { Principal } from "@dfinity/principal";
window.checkUpgradeCancellation = async () => {
 let active = true;
 let installed = false;
 window.api = {
  query_raw: async () => { active = false; return new ArrayBuffer(0); },
  call_raw: async () => { installed = true; return new ArrayBuffer(0); }
 };
 await realUpgradeBucket(Principal.fromText("aaaaa-aa"), () => active);
 return !installed;
};
window.scenario = new URL(location.href).searchParams.get("scenario") || "legacy";
window.calls = [];
window.principalId = "owner";
window.backendCache = { config: {token_decimals: 2}, stats: {canister_id: "test"} };
let progress = { state: "deleting", processed: 0, total: 60, balance: 0, treasury_e8s: 0, bucket: window.scenario === "none" ? null : "aaaaa-aa", media_closed: ["none", "closed"].includes(window.scenario) };
setDeletionStatus(progress);
let failed = false;
window.api = {
 call_raw: async (_, method) => {
  window.calls.push(method);
  if (window.scenario === "close-fail" && !failed) { failed = true; return null; }
  if (["pause", "navigate"].includes(window.scenario)) await new Promise(resolve => { window.release = resolve; });
  return new ArrayBuffer(0);
 },
 call: async method => {
  window.calls.push(method);
  if (window.scenario === "continue-fail" && !failed) { failed = true; return {Err: "network unavailable"}; }
  progress = {...progress, processed: progress.processed + 20, media_closed: true};
  if (progress.processed >= progress.total) progress.state = "deleted";
  return {Ok: progress};
 }
};
createRoot(document.getElementById("root")).render(<DeletedAccount />);
`,
);
const compiler = webpack({
    mode: "development",
    entry: path.join(temp, "entry.tsx"),
    output: { path: temp, filename: "bundle.js" },
    resolve: {
        extensions: [".tsx", ".ts", ".js"],
        modules: [path.join(root, "node_modules")],
        alias: {
            "./common$": path.join(temp, "mock.tsx"),
            "./user_storage$": path.join(temp, "mock.tsx"),
        },
    },
    module: {
        rules: [
            {
                test: /\.tsx?$/,
                use: {
                    loader: require.resolve("ts-loader"),
                    options: {
                        transpileOnly: true,
                        configFile: path.join(root, "tsconfig.json"),
                    },
                },
            },
        ],
    },
    plugins: [
        new webpack.DefinePlugin({
            "process.env.CANISTER_ID": JSON.stringify("aaaaa-aa"),
            "process.env.DFX_NETWORK": JSON.stringify("ic"),
        }),
    ],
});
(async () => {
    await new Promise((resolve, reject) =>
        compiler.run((err, stats) =>
            err || stats.hasErrors()
                ? reject(err || Error(stats.toString()))
                : resolve(),
        ),
    );
    await new Promise((resolve) => compiler.close(resolve));
    const server = http.createServer((req, res) => {
        res.setHeader(
            "Content-Type",
            req.url.startsWith("/bundle.js") ? "text/javascript" : "text/html",
        );
        res.end(
            req.url.startsWith("/bundle.js")
                ? fs.readFileSync(path.join(temp, "bundle.js"))
                : '<div id="root"></div><script src="/bundle.js"></script>',
        );
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const url = `http://127.0.0.1:${server.address().port}`;
    if (process.argv.includes("--serve")) {
        console.log(url);
        const cleanup = () => {
            server.close();
            fs.rmSync(temp, { recursive: true, force: true });
            process.exit(0);
        };
        process.once("SIGINT", cleanup);
        process.once("SIGTERM", cleanup);
        return;
    }
    let browser;
    try {
        browser = await chromium.launch({
            executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
        });
        const page = await browser.newPage();
        for (const scenario of [
            "none",
            "closed",
            "legacy",
            "unknown",
            "close-fail",
            "continue-fail",
            "denied",
            "custom",
            "pause",
            "navigate",
        ]) {
            await page.goto(`${url}/?scenario=${scenario}`);
            if (scenario === "custom") {
                assert.equal(
                    await page.getByRole("link").getAttribute("href"),
                    "https://test.icp0.io/#/sign-in",
                );
                assert.equal(
                    await page
                        .getByRole("button", { name: "CONTINUE DELETION" })
                        .count(),
                    0,
                );
                continue;
            }
            const button = page.getByRole("button", {
                name: "CONTINUE DELETION",
            });
            await button.click();
            if (scenario === "denied") {
                await page.getByRole("alert").waitFor();
                assert.deepEqual(await page.evaluate(() => window.calls), [
                    "status",
                ]);
                continue;
            }
            if (["pause", "navigate"].includes(scenario)) {
                await page.waitForFunction(() => !!window.release);
                assert.equal(await button.isDisabled(), true);
                if (scenario === "pause")
                    await page
                        .getByRole("button", { name: "SIGN OUT" })
                        .click();
                else
                    await page.evaluate(() =>
                        window.dispatchEvent(new HashChangeEvent("hashchange")),
                    );
                await page.evaluate(() => window.release());
                await page.waitForFunction(
                    () => !document.querySelector("button").disabled,
                );
                assert.deepEqual(await page.evaluate(() => window.calls), [
                    "status",
                    "close_media",
                ]);
                continue;
            }
            if (scenario.endsWith("-fail")) {
                await page.getByRole("alert").waitFor();
                await button.click();
            }
            await page
                .getByRole("heading", { name: "Account deleted", exact: true })
                .waitFor();
            const calls = await page.evaluate(() => window.calls);
            if (scenario === "legacy")
                assert.deepEqual(calls.slice(0, 3), [
                    "status",
                    "upgrade",
                    "close_media",
                ]);
            if (scenario === "unknown")
                assert.deepEqual(calls.slice(0, 2), ["status", "close_media"]);
            if (["none", "closed"].includes(scenario))
                assert.deepEqual(
                    calls,
                    Array(3).fill("continue_account_deletion"),
                );
        }
        assert.equal(
            await page.evaluate(() => window.checkUpgradeCancellation()),
            true,
        );
        console.log("PASS: 10 recovery scenarios and upgrade cancellation");
    } finally {
        await browser?.close();
        server.close();
        fs.rmSync(temp, { recursive: true, force: true });
    }
})().catch((err) => {
    console.error(err);
    process.exitCode = 1;
});
