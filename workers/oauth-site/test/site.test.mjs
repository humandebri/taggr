import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.mjs";

async function request(path, init) {
    return worker.fetch(
        new Request(`https://taggr.kasane.network${path}`, init),
    );
}

test("serves every public policy route", async () => {
    for (const [path, heading] of [
        ["/", "Social publishing"],
        ["/privacy", "Privacy Policy"],
        ["/terms", "Terms of Use"],
    ]) {
        const response = await request(path);
        assert.equal(response.status, 200);
        assert.match(response.headers.get("content-type"), /^text\/html/);
        assert.match(await response.text(), new RegExp(heading));
    }
});

test("privacy policy describes both YouTube scopes and deletion", async () => {
    const body = await (await request("/privacy")).text();
    assert.match(body, /youtube\.readonly/);
    assert.match(body, /youtube\.upload/);
    assert.match(body, /Google API Services User Data Policy/);
    assert.match(body, /Disconnecting and deleting Google data/);
});

test("supports crawlers and rejects unsupported methods", async () => {
    assert.equal((await request("/robots.txt")).status, 200);
    assert.equal((await request("/missing")).status, 404);
    assert.equal((await request("/", { method: "POST" })).status, 405);
});
