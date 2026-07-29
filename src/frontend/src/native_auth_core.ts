// Keeps native iOS Internet Identity URL validation and payload conversion
// outside the React component so auth edge cases can be tested directly.

type NativeAuthEnvironment = {
    canonicalDomain: string;
    canonicalOrigin: string;
    hash: string;
    search: string;
};

type NativeAuthParams = {
    state: string;
    callback: string;
    identityProvider: string;
    sessionPublicKey: Uint8Array;
    maxTimeToLive: bigint;
};

export type NativeLoginMethod = "passkey" | "apple" | "google";

const nativeMaxTimeToLive = "2592000000000000";
const nativeMaxTimeToLiveNanos = BigInt(nativeMaxTimeToLive);
const nativeIdentityProvider =
    "https://id.ai/?feature_flag_guided_upgrade=true";
const nativeAppleIdentityProvider =
    "https://id.ai/authorize?openid=https://appleid.apple.com";
const nativeGoogleIdentityProvider =
    "https://id.ai/authorize?openid=https://accounts.google.com";

export const nativeAuthEnvironment = (
    canonicalDomain: string,
    canonicalOrigin = `https://${canonicalDomain}`,
): NativeAuthEnvironment => ({
    canonicalDomain,
    canonicalOrigin,
    hash: window.location.hash,
    search: window.location.search,
});

export const isAllowedIdentityProvider = (value: string) => {
    try {
        const url = new URL(value);
        if (url.username || url.password) return false;
        return (
            url.origin == "https://id.ai" &&
            url.pathname == "/" &&
            url.search == "?feature_flag_guided_upgrade=true"
        );
    } catch {
        return false;
    }
};

export const buildIdentityUrl = (
    identityProvider: string,
    method: NativeLoginMethod,
) => {
    if (!isAllowedIdentityProvider(identityProvider)) {
        throw new Error("Invalid identity provider.");
    }
    if (method == "apple") return new URL(nativeAppleIdentityProvider);
    if (method == "google") return new URL(nativeGoogleIdentityProvider);
    if (method != "passkey") throw new Error("Invalid login method.");

    const identityURL = new URL(identityProvider);
    identityURL.hash = "#authorize";
    return identityURL;
};

const base64UrlToBytes = (value: string) => {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = globalThis.atob(padded);
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

export const textToBase64Url = (value: string) =>
    globalThis
        .btoa(String.fromCharCode(...new TextEncoder().encode(value)))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=/g, "");

const bytesToHex = (bytes: Uint8Array) =>
    Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

export const normalizeAuthResponse = (value: unknown): unknown => {
    if (typeof value == "bigint") return value.toString(10);
    if (value instanceof Uint8Array) return bytesToHex(value);
    if (value instanceof ArrayBuffer) return bytesToHex(new Uint8Array(value));
    if (Array.isArray(value)) return value.map(normalizeAuthResponse);
    if (value && typeof value == "object") {
        const toUint8Array = Reflect.get(value, "toUint8Array");
        if (typeof toUint8Array == "function") {
            return bytesToHex(toUint8Array.call(value));
        }
        return Object.fromEntries(
            Object.entries(value).map(([key, nested]) => [
                key,
                normalizeAuthResponse(nested),
            ]),
        );
    }
    return value;
};

export const messageKind = (value: unknown) => {
    if (!value || typeof value != "object") return "";
    const kind = Reflect.get(value, "kind");
    return typeof kind == "string" ? kind : "";
};

export const buildCallbackUrl = (
    callback: string,
    state: string,
    kind: "result" | "error",
    payload: string,
) =>
    `${callback}?state=${encodeURIComponent(state)}&${kind}=${encodeURIComponent(payload)}`;

const parseMaxTimeToLive = (value: string) => {
    if (!/^[0-9]+$/.test(value)) throw new Error("Invalid max time to live.");
    const maxTimeToLive = BigInt(value);
    if (
        maxTimeToLive == BigInt(0) ||
        maxTimeToLive > nativeMaxTimeToLiveNanos
    ) {
        throw new Error("Invalid max time to live.");
    }
    return maxTimeToLive;
};

export const parseNativeAuthParams = (
    env: NativeAuthEnvironment,
): NativeAuthParams => {
    const queryStart = env.hash.indexOf("?");
    const query = queryStart >= 0 ? env.hash.slice(queryStart + 1) : "";
    const params = new URLSearchParams(query);
    const state = params.get("state") || "";
    const callback = params.get("callback") || "";
    const encodedPublicKey = params.get("sessionPublicKey") || "";
    const maxTimeToLive = params.get("maxTimeToLive") || nativeMaxTimeToLive;
    const identityProvider =
        params.get("identityProvider") || nativeIdentityProvider;
    if (!state) throw new Error("Missing state.");
    if (callback != `${env.canonicalOrigin}/ios-auth-callback`) {
        throw new Error("Invalid callback.");
    }
    if (!encodedPublicKey) throw new Error("Missing session public key.");
    if (!isAllowedIdentityProvider(identityProvider)) {
        throw new Error("Invalid identity provider.");
    }
    return {
        state,
        callback,
        identityProvider,
        sessionPublicKey: base64UrlToBytes(encodedPublicKey),
        maxTimeToLive: parseMaxTimeToLive(maxTimeToLive),
    };
};
