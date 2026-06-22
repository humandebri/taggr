const assert = require("node:assert/strict");
const test = require("node:test");

const {
    isAllowedIdentityProvider,
    parseNativeAuthParams,
} = require("../../../dist/frontend-test/native_auth_core.js");

const canonicalDomain = "taggr.link";
const productionCallback = `https://${canonicalDomain}/ios-auth-callback`;
const mainnetII = "https://id.ai/?feature_flag_guided_upgrade=true";

const baseEnv = (overrides = {}) => ({
    canonicalDomain,
    hash: "#/native-auth",
    search: "",
    ...overrides,
});

const query = (overrides = {}) => {
    const params = new URLSearchParams({
        state: "state-1",
        callback: productionCallback,
        sessionPublicKey: "AQID",
        ...overrides,
    });
    return params.toString();
};

const parseWithQuery = (envOverrides, queryOverrides = {}) =>
    parseNativeAuthParams(
        baseEnv({
            hash: `#/native-auth?${query(queryOverrides)}`,
            ...envOverrides,
        }),
    );

test("parses native auth params from hash query", () => {
    const parsed = parseWithQuery();

    assert.equal(parsed.state, "state-1");
    assert.equal(parsed.callback, productionCallback);
    assert.equal(parsed.identityProvider, mainnetII);
    assert.deepEqual(Array.from(parsed.sessionPublicKey), [1, 2, 3]);
});

test("parses native auth params from search when hash has no query", () => {
    const parsed = parseNativeAuthParams(
        baseEnv({
            hash: "#/native-auth",
            search: `?${query()}`,
        }),
    );

    assert.equal(parsed.state, "state-1");
    assert.equal(parsed.callback, productionCallback);
    assert.deepEqual(Array.from(parsed.sessionPublicKey), [1, 2, 3]);
});

test("mainnet callback only allows canonical iOS callback", () => {
    assert.equal(parseWithQuery().callback, productionCallback);
    assert.throws(
        () =>
            parseWithQuery(undefined, {
                callback: "https://evil.test/ios-auth-callback",
            }),
        /Invalid callback/,
    );
});

test("mainnet identity provider only allows id.ai with the approved query", () => {
    assert.equal(isAllowedIdentityProvider("https://id.ai/"), true);
    assert.equal(isAllowedIdentityProvider(mainnetII), true);
    assert.equal(
        isAllowedIdentityProvider(
            "https://user:pass@id.ai/?feature_flag_guided_upgrade=true",
        ),
        false,
    );
    assert.equal(
        isAllowedIdentityProvider("https://id.ai/?unexpected=true"),
        false,
    );
    assert.equal(isAllowedIdentityProvider("http://id.ai/"), false);
});

test("required params must be present", () => {
    assert.throws(
        () => parseWithQuery(undefined, { state: "" }),
        /Missing state/,
    );
    assert.throws(
        () => parseWithQuery(undefined, { sessionPublicKey: "" }),
        /Missing session public key/,
    );
});

test("maxTimeToLive must be numeric and within native bounds", () => {
    assert.equal(
        parseWithQuery(undefined, { maxTimeToLive: "1" }).maxTimeToLive,
        1n,
    );
    assert.throws(
        () => parseWithQuery(undefined, { maxTimeToLive: "0" }),
        /Invalid max time to live/,
    );
    assert.throws(
        () =>
            parseWithQuery(undefined, {
                maxTimeToLive: "2592000000000001",
            }),
        /Invalid max time to live/,
    );
    assert.throws(
        () => parseWithQuery(undefined, { maxTimeToLive: "not-a-number" }),
        /Invalid max time to live/,
    );
});

test("local and tunnel identity providers are rejected", () => {
    assert.equal(
        isAllowedIdentityProvider(
            "http://localhost:9090/?canisterId=qhbym-qaaaa-aaaaa-aaafq-cai",
        ),
        false,
    );
    assert.equal(
        isAllowedIdentityProvider("https://example.ngrok-free.app/"),
        false,
    );
});

test("local URL scheme callback is rejected", () => {
    assert.throws(
        () =>
            parseWithQuery(undefined, {
                callback: "taggr://identity-callback",
            }),
        /Invalid callback/,
    );
});
