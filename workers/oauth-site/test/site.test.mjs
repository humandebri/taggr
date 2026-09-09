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
        ["/", "TAGGR is a decentralized social network"],
        ["/about", "TAGGR is a decentralized social network"],
        ["/privacy", "TAGGR iOS App Privacy Policy"],
        ["/privacy-policy", "TAGGR iOS App Privacy Policy"],
        ["/terms", "Terms of Use"],
    ]) {
        const response = await request(path);
        assert.equal(response.status, 200);
        assert.match(response.headers.get("content-type"), /^text\/html/);
        assert.match(response.headers.get("cache-control"), /no-transform/);
        assert.equal(response.headers.get("x-frame-options"), "DENY");
        assert.match(
            response.headers.get("content-security-policy"),
            /frame-ancestors 'none'/,
        );
        assert.match(await response.text(), new RegExp(heading));
    }
});

test("homepage is a public app-information page", async () => {
    const body = await (await request("/about")).text();
    assert.match(
        body,
        /All app-information and legal pages are publicly accessible/,
    );
    assert.match(body, /What the TAGGR iOS app does/);
    assert.match(body, /Read the TAGGR Privacy Policy/);
    assert.doesNotMatch(body, /Open TAGGR/);
});

test("privacy policy comprehensively discloses Google data handling", async () => {
    const body = await (await request("/privacy-policy")).text();
    assert.match(body, /Google user data disclosure summary/);
    assert.match(body, /youtube\.readonly/);
    assert.match(body, /youtube\.upload/);
    assert.match(body, /Data collected or accessed:/);
    assert.match(body, /Purpose:/);
    assert.match(body, /Storage:/);
    assert.match(body, /Sharing:/);
    assert.match(body, /Retention and deletion:/);
    assert.match(body, /Google API Services User Data Policy/);
    assert.match(body, /Disconnecting and deleting Google data/);
});

test("supports crawlers and rejects unsupported methods", async () => {
    assert.equal((await request("/robots.txt")).status, 200);
    assert.equal((await request("/missing")).status, 404);
    assert.equal((await request("/", { method: "POST" })).status, 405);
});
