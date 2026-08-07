#!/usr/bin/env node
// Local iOS/device testing helper.
// Sends ICP on the local PocketIC ledger from an existing funded icp-cli identity.
const { spawnSync } = require("child_process");

const identityName = process.env.TAGGR_LOCAL_MINTER_IDENTITY || "local-minter";
const icpBin = process.env.ICP_BIN || "/Users/0xhude/.local/bin/icp";
const childProcessPath = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    process.env.PATH || "",
]
    .filter(Boolean)
    .join(":");

function usage() {
    console.log(`Usage:
  node ios/scripts/local-icp-transfer.js <receiver-principal-or-account> [amount]
  node ios/scripts/local-icp-transfer.js <amount> <receiver-principal-or-account>

Examples:
  node ios/scripts/local-icp-transfer.js swqvp-...-wae
  node ios/scripts/local-icp-transfer.js swqvp-...-wae 1
  node ios/scripts/local-icp-transfer.js 1 swqvp-...-wae
  TAGGR_LOCAL_MINTER_IDENTITY=<existing-funded-identity> npm run ios:local:icp -- swqvp-...-wae 1

Environment:
  ICP_BIN=/path/to/icp
  TAGGR_LOCAL_MINTER_IDENTITY=<existing-funded-identity>`);
}

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        encoding: "utf8",
        env: { ...process.env, PATH: childProcessPath },
        stdio: options.capture ? "pipe" : "inherit",
    });
    if (result.error) throw result.error;
    if (result.status !== 0 && !options.allowFailure) {
        const output = [result.stdout, result.stderr]
            .filter(Boolean)
            .join("\n");
        throw new Error(
            `${command} ${args.join(" ")} failed with ${result.status}${output ? `\n${output}` : ""}`,
        );
    }
    return {
        status: result.status,
        stdout: result.stdout?.trim() || "",
        stderr: result.stderr?.trim() || "",
    };
}

function parseArgs(args) {
    if (args.includes("--help") || args.includes("-h")) {
        usage();
        process.exit(0);
    }
    if (args.length < 1 || args.length > 2) {
        usage();
        process.exit(2);
    }
    const [first, second] = args;
    if (second && /^\d+(\.\d+)?$/.test(first)) {
        return { amount: first, receiver: second };
    }
    return { amount: second || "1", receiver: first };
}

function ensureLocalMinterIdentity() {
    const principal = run(
        icpBin,
        ["identity", "principal", "--identity", identityName],
        { capture: true, allowFailure: true },
    );
    if (principal.status === 0) {
        console.log(
            `Using existing icp-cli identity ${identityName}: ${principal.stdout}`,
        );
        return;
    }

    throw new Error(
        [
            `Missing icp-cli identity ${identityName}.`,
            "This helper does not create or import identities.",
            "Run `icp identity list` and choose an existing funded icp-cli identity.",
            "Then run:",
            "  TAGGR_LOCAL_MINTER_IDENTITY=<identity> npm run ios:local:icp -- <receiver> 1",
        ].join("\n"),
    );
}

function balance(receiver) {
    return run(
        icpBin,
        [
            "token",
            "balance",
            "--identity",
            identityName,
            "-e",
            "local",
            "--of-principal",
            receiver,
            "--quiet",
        ],
        { capture: true },
    ).stdout;
}

function main() {
    const { amount, receiver } = parseArgs(process.argv.slice(2));
    ensureLocalMinterIdentity();

    let before = null;
    if (!/^[0-9a-f]{64}$/i.test(receiver)) {
        before = balance(receiver);
        console.log(`Before: ${before}`);
    }

    const block = run(
        icpBin,
        [
            "token",
            "transfer",
            "--identity",
            identityName,
            "-e",
            "local",
            amount,
            receiver,
            "--quiet",
        ],
        { capture: true },
    ).stdout;

    console.log(`Transferred ${amount} ICP to ${receiver}`);
    console.log(`Block: ${block}`);

    if (before !== null) {
        console.log(`After: ${balance(receiver)}`);
    }
}

try {
    main();
} catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
}
