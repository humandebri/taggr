#!/usr/bin/env node
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const ts = require("typescript");
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const sourcePath = path.join(
    root,
    "src",
    "frontend",
    "src",
    "native_auth_core.ts",
);
const tsSource = fs.readFileSync(sourcePath, "utf8");
const output = ts.transpileModule(tsSource, {
    compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
    },
}).outputText;
const moduleObject = { exports: {} };
const sandbox = {
    URL,
    URLSearchParams,
    ArrayBuffer,
    TextEncoder,
    Uint8Array,
    atob: (value) => Buffer.from(value, "base64").toString("binary"),
    btoa: (value) => Buffer.from(value, "binary").toString("base64"),
    exports: moduleObject.exports,
    module: moduleObject,
};
vm.runInNewContext(output, sandbox, { filename: sourcePath });

const {
    buildCallbackUrl,
    isAllowedIdentityProvider,
    messageKind,
    normalizeAuthResponse,
    parseNativeAuthParams,
    textToBase64Url,
} = moduleObject.exports;

const canonicalDomain = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
const callback = `https://${canonicalDomain}/ios-auth-callback`;
const nativeMaxTimeToLive = "2592000000000000";
const identityProvider = "https://id.ai/?feature_flag_guided_upgrade=true";

const validParams = (ttl, callbackURL = callback) => {
    const params = new URLSearchParams({
        state: "state-1",
        callback: callbackURL,
        sessionPublicKey: "AQID",
        identityProvider,
    });
    if (ttl != null) params.set("maxTimeToLive", ttl);
    return params;
};

const parse = (ttl, callbackURL = callback) =>
    parseNativeAuthParams({
        canonicalDomain,
        canonicalOrigin: `https://${canonicalDomain}`,
        hash: `#/native-auth?${validParams(ttl, callbackURL).toString()}`,
        search: "",
    });

assert.equal(parse(null).maxTimeToLive, BigInt(nativeMaxTimeToLive));
assert.equal(
    parse(nativeMaxTimeToLive).maxTimeToLive,
    BigInt(nativeMaxTimeToLive),
);
for (const invalidCallback of [
    "taggr://identity-callback",
    "taggr://identity-callback/extra",
    "taggr://evil",
    `https://${canonicalDomain}/bad-callback`,
    `https://user:pass@${canonicalDomain}/ios-auth-callback`,
]) {
    assert.throws(() => parse(null, invalidCallback), /Invalid callback/);
}
for (const value of [
    "0",
    "-1",
    "abc",
    "1.5",
    "1e3",
    `${nativeMaxTimeToLive}0`,
    "999999999999999999999999999999999999999999999999999999999999999999",
]) {
    assert.throws(() => parse(value), /Invalid max time to live/);
}

assert.equal(isAllowedIdentityProvider(identityProvider), true);
assert.equal(isAllowedIdentityProvider("https://id.ai/"), false);
assert.equal(
    isAllowedIdentityProvider(
        "https://user:pass@id.ai/?feature_flag_guided_upgrade=true",
    ),
    false,
);
assert.throws(
    () =>
        parseNativeAuthParams({
            canonicalDomain,
            canonicalOrigin: `https://${canonicalDomain}`,
            hash: `#/native-auth?${new URLSearchParams({
                ...Object.fromEntries(validParams(null)),
                identityProvider: "https://id.ai/",
            }).toString()}`,
            search: "",
        }),
    /Invalid identity provider/,
);

const bytes = new Uint8Array([1, 2, 3]);
assert.deepEqual(normalizeAuthResponse(bytes), "010203");
assert.deepEqual(normalizeAuthResponse({ signature: bytes }), {
    signature: "010203",
});
const buffer = new Uint8Array([4, 5, 6]).buffer;
assert.deepEqual(normalizeAuthResponse(buffer), "040506");
assert.deepEqual(normalizeAuthResponse({ userPublicKey: buffer }), {
    userPublicKey: "040506",
});

assert.equal(messageKind({ kind: "authorize-ready" }), "authorize-ready");
assert.equal(messageKind({ kind: 1 }), "");
assert.equal(textToBase64Url("denied"), "ZGVuaWVk");
assert.equal(
    buildCallbackUrl(callback, "state 1", "error", "ZGVuaWVk"),
    `${callback}?state=state%201&error=ZGVuaWVk`,
);

console.log("native auth core tests passed");
