const fs = require("fs");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const identity = process.env.IOS_DFX_IDENTITY || "prod";
const productionCanister = "6qfxa-ryaaa-aaaai-qbhsq-cai";
const artifacts = [
    "target/wasm32-unknown-unknown/release/taggr.wasm.gz",
    "target/wasm32-unknown-unknown/release/bucket.wasm.gz",
];

const run = (label, cmd, args) => {
    const result = spawnSync(cmd, args, {
        encoding: "utf8",
        stdio: "pipe",
        timeout: 30_000,
    });
    const output = [result.stdout, result.stderr]
        .filter(Boolean)
        .join("\n")
        .trim();
    if (result.status === 0) {
        console.log(`PASS ${label}`);
        if (output) console.log(output);
        return true;
    }
    console.error(`FAIL ${label}`);
    if (output) console.error(output);
    process.exitCode = 1;
    return false;
};

const hashFile = (path) => {
    const bytes = fs.readFileSync(path);
    return crypto.createHash("sha256").update(bytes).digest("hex");
};

run("dfx 0.32.0", "npm", ["run", "ios:dfx"]);
run("production dfx identity", "npm", ["run", "ios:identity"]);
run("production canister controller access", "dfx", [
    "--identity",
    identity,
    "canister",
    "--network",
    "ic",
    "status",
    productionCanister,
]);
run("local iOS frontend bundle", "npm", ["run", "ios:frontend:local"]);
run("local AASA", "npm", ["run", "ios:aasa:local"]);

for (const artifact of artifacts) {
    if (fs.existsSync(artifact)) {
        console.log(`PASS ${artifact} exists`);
        console.log(`${hashFile(artifact)}  ${artifact}`);
    } else {
        console.error(`FAIL ${artifact} exists; run make build`);
        process.exitCode = 1;
    }
}

if (!process.exitCode) console.log("iOS deploy readiness passed.");
