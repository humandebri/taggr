const { spawnSync } = require("child_process");

const IDENTITY_CHECK_TIMEOUT_MS = 15_000;
const identity = process.env.IOS_DFX_IDENTITY || "prod";
const identityWasExplicit = Boolean(process.env.IOS_DFX_IDENTITY);
const result = spawnSync(
    "dfx",
    ["identity", "--identity", identity, "get-principal"],
    {
        encoding: "utf8",
        stdio: "pipe",
        timeout: IDENTITY_CHECK_TIMEOUT_MS,
    },
);
const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();

if (result.status === 0 && output) {
    console.log(`PASS dfx identity ${identity} is available`);
} else {
    console.error(`FAIL dfx identity ${identity} is available`);
    if (result.error?.code === "ETIMEDOUT") {
        console.error(
            `dfx identity check timed out after ${IDENTITY_CHECK_TIMEOUT_MS / 1000}s.`,
        );
    }
    if (output) console.error(output);
    if (!identityWasExplicit) {
        console.error(
            "Set IOS_DFX_IDENTITY=<name> if the production identity is not named prod.",
        );
    } else {
        console.error(
            "Confirm the selected identity exists and its encrypted PEM can be loaded from keyring.",
        );
    }
    process.exit(1);
}
