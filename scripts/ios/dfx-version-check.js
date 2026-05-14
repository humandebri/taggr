const { spawnSync } = require("child_process");

const expected = "dfx 0.32.0";
const result = spawnSync("dfx", ["--version"], {
    encoding: "utf8",
    stdio: "pipe",
});
const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();

if (result.status === 0 && output === expected) {
    console.log(`PASS ${expected} is available`);
} else {
    console.error(`FAIL expected ${expected}`);
    if (output) console.error(output);
    process.exit(1);
}
