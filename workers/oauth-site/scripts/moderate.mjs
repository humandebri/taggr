import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { CANISTERS, validID } from "../src/moderation.mjs";
const quote = (value) => "'" + String(value).replaceAll("'", "''") + "'";
const reportID = (value) =>
    typeof value === "string" && /^[\da-f-]{36}$/i.test(value);

export function statements(args, now = Date.now()) {
    const [action, ...values] = args;
    if (action === "list" && values.length === 0)
        return [
            `DELETE FROM reports WHERE closed_at IS NOT NULL AND closed_at < ${now - 90 * 86400000}`,
            "SELECT id,canister_id,post_id,user_id,received_at FROM reports WHERE closed_at IS NULL ORDER BY received_at LIMIT 100",
        ];
    if (
        ["show", "close"].includes(action) &&
        values.length === 1 &&
        reportID(values[0])
    )
        return [
            action === "show"
                ? `SELECT * FROM reports WHERE id=${quote(values[0].toLowerCase())}`
                : `UPDATE reports SET closed_at=${now} WHERE id=${quote(values[0].toLowerCase())} AND closed_at IS NULL RETURNING id,closed_at`,
        ];
    if (["hide", "restore"].includes(action) && values.length === 4) {
        const [canister, kind, target, reason] = values;
        if (
            !CANISTERS.includes(canister) ||
            !["post", "user"].includes(kind) ||
            !/^\d+$/.test(target) ||
            !validID(Number(target)) ||
            !reason.trim() ||
            [...reason].length > 2000
        )
            throw new Error("Invalid target or reason");
        return [
            `INSERT INTO restrictions(canister_id,kind,target_id,active,reason,created_at) VALUES(${quote(canister)},${quote(kind)},${Number(target)},${action === "hide" ? 1 : 0},${quote(reason.trim())},${now}) RETURNING *`,
        ];
    }
    if (action === "history" && values.length === 0)
        return ["SELECT * FROM restrictions ORDER BY id DESC LIMIT 100"];
    throw new Error(
        "Usage: node scripts/moderate.mjs [--remote | --local] list | show UUID | close UUID | hide CANISTER post|user ID REASON | restore CANISTER post|user ID REASON | history\nlist also deletes reports closed more than 90 days ago.",
    );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    try {
        const args = process.argv.slice(2);
        const remote = args[0] === "--remote";
        if (!["--remote", "--local"].includes(args[0]))
            throw new Error("Specify --local or --remote explicitly.");
        const sql = statements(args.slice(1)).join(";\n") + ";";
        const result = spawnSync(
            process.execPath,
            [
                "node_modules/wrangler/bin/wrangler.js",
                "d1",
                "execute",
                remote ? "taggr-ios-moderation" : "taggr-ios-moderation-local",
                ...(remote ? ["--remote"] : ["--local", "--env", "local"]),
                "--command",
                sql,
                "--json",
            ],
            {
                cwd: fileURLToPath(new URL("..", import.meta.url)),
                encoding: "utf8",
                maxBuffer: 8 * 1024 * 1024,
            },
        );
        if (result.error) throw result.error;
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        process.exitCode = result.status ?? 1;
    } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
    }
}
