import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import worker from "../src/index.mjs";
import { CANISTERS } from "../src/moderation.mjs";
import { statements } from "../scripts/moderate.mjs";
const canisterID = CANISTERS[0];
function fixture(t) {
    const raw = new DatabaseSync(":memory:");
    raw.exec(
        readFileSync(
            new URL("../migrations/0001_moderation.sql", import.meta.url),
            "utf8",
        ),
    );
    t.after(() => raw.close());
    const prepare = (sql) => {
        let args = [];
        const stmt = raw.prepare(sql);
        return {
            bind(...values) {
                args = values;
                return this;
            },
            async run() {
                return stmt.run(...args);
            },
            async first() {
                return stmt.get(...args) ?? null;
            },
            async all() {
                return { results: stmt.all(...args) };
            },
        };
    };
    const env = {
        MODERATION_DB: {
            prepare,
            async batch(items) {
                raw.exec("BEGIN");
                try {
                    const out = await Promise.all(items.map((s) => s.all()));
                    raw.exec("COMMIT");
                    return out;
                } catch (e) {
                    raw.exec("ROLLBACK");
                    throw e;
                }
            },
        },
        REPORT_LIMITER: {
            async limit() {
                return { success: true };
            },
        },
    };
    return {
        raw,
        env,
        send(path, body, headers = {}) {
            return worker.fetch(
                new Request(
                    "https://taggr.kasane.network" + path,
                    body === undefined
                        ? { headers }
                        : {
                              method: "POST",
                              headers: {
                                  "content-type": "application/json",
                                  ...headers,
                              },
                              body:
                                  typeof body === "string"
                                      ? body
                                      : JSON.stringify(body),
                          },
                ),
                env,
            );
        },
    };
}
const report = () => ({
    id: crypto.randomUUID(),
    canisterID,
    userID: 7,
    postID: 42,
    reason: "日本語 & test",
});

test("reports are saved once, conflicting retries rejected, and remain private", async (t) => {
    const { send, raw } = fixture(t);
    const body = report();
    assert.equal((await send("/api/reports", body)).status, 201);
    assert.equal((await send("/api/reports", body)).status, 201);
    assert.equal(raw.prepare("SELECT count(*) AS n FROM reports").get().n, 1);
    assert.equal(
        (await send("/api/reports", { ...body, reason: "changed" })).status,
        409,
    );
    assert.equal((await send("/api/reports")).status, 405);
    const response = await send("/api/moderation?canisterID=" + canisterID);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(await response.json(), {
        canisterID,
        version: 0,
        postIDs: [],
        userIDs: [],
    });
});

test("invalid requests, oversized bodies, rate excess, origin and missing DB fail", async (t) => {
    const { send, env } = fixture(t);
    for (const extra of [
        { userID: -1 },
        { postID: 1.5 },
        { canisterID: "other" },
        { id: "bad" },
        { reason: " " },
        { reason: "x".repeat(2001) },
    ]) {
        assert.equal(
            (await send("/api/reports", { ...report(), ...extra })).status,
            400,
        );
    }
    assert.equal((await send("/api/reports", "x".repeat(8193))).status, 413);
    assert.equal(
        (await send("/api/reports", report(), { origin: "https://other.test" }))
            .status,
        403,
    );
    env.REPORT_LIMITER.limit = async () => ({ success: false });
    assert.equal((await send("/api/reports", report())).status, 429);
    delete env.MODERATION_DB;
    assert.equal((await send("/api/reports", report())).status, 503);
    assert.equal(
        (await send("/api/moderation?canisterID=" + canisterID)).status,
        503,
    );
});

test("CLI decisions hide and restore only intended targets and keep history", async (t) => {
    const { send, raw } = fixture(t);
    for (const sql of statements(
        ["hide", canisterID, "post", "42", "reason with ' quote"],
        10,
    ))
        raw.exec(sql);
    for (const sql of statements(
        ["hide", canisterID, "user", "7", "manual check"],
        20,
    ))
        raw.exec(sql);
    let value = await (
        await send("/api/moderation?canisterID=" + canisterID)
    ).json();
    assert.deepEqual(value.postIDs, [42]);
    assert.deepEqual(value.userIDs, [7]);
    assert.equal(value.version, 2);
    for (const sql of statements(
        ["restore", canisterID, "post", "42", "appeal accepted"],
        30,
    ))
        raw.exec(sql);
    value = await (
        await send("/api/moderation?canisterID=" + canisterID)
    ).json();
    assert.deepEqual(value.postIDs, []);
    assert.deepEqual(value.userIDs, [7]);
    assert.equal(value.version, 3);
    assert.equal(
        raw.prepare("SELECT count(*) AS n FROM restrictions").get().n,
        3,
    );
    assert.throws(() =>
        statements(["hide", canisterID, "post", "0;DROP TABLE reports", "bad"]),
    );
    assert.throws(() => statements(["hide", "other", "post", "42", "bad"]));
    assert.throws(() => statements(["hide", canisterID, "post", "42", ""]));
});

test("CLI closes reports and prunes only reports closed over 90 days ago", async (t) => {
    const { send, raw } = fixture(t);
    const body = report();
    await send("/api/reports", body);
    for (const sql of statements(["close", body.id], 1000)) raw.exec(sql);
    const open = report();
    await send("/api/reports", open);
    for (const sql of statements(["list"], 1000 + 91 * 86400000)) raw.exec(sql);
    assert.equal(raw.prepare("SELECT count(*) AS n FROM reports").get().n, 1);
    assert.equal(raw.prepare("SELECT id FROM reports").get().id, open.id);
});

test("storage failures cannot report success or publish a fabricated empty list", async (t) => {
    const { send, env } = fixture(t);
    env.MODERATION_DB.prepare = () => {
        throw new Error("storage down");
    };
    for (const [path, body] of [
        ["/api/reports", report()],
        ["/api/moderation?canisterID=" + canisterID, undefined],
    ]) {
        const response = await send(path, body);
        assert.equal(response.status, 503);
        const value = await response.json();
        assert.equal(value.status, undefined);
        assert.equal(value.postIDs, undefined);
    }
});
