// src/frontend/src/native_auth_core.ts
// Keeps native iOS Internet Identity URL validation and payload conversion
// outside the React component so auth edge cases can be tested directly.
import { II_URL, MAINNET_MODE } from "./env";

export type NativeAuthEnvironment = {
    mainnetMode: boolean;
    iiUrl: string;
    currentHostname: string;
    canonicalDomain: string;
    hash: string;
};

export type NativeAuthParams = {
    state: string;
    callback: string;
    identityProvider: string;
    sessionPublicKey: Uint8Array;
    maxTimeToLive: bigint;
};

const localCallback = "taggr://identity-callback";
const nativeMaxTimeToLive = "2592000000000000";
const nativeMaxTimeToLiveNanos = BigInt(nativeMaxTimeToLive);
const allowedMainnetIIQuery = "?feature_flag_guided_upgrade=true";

export const nativeAuthEnvironment = (
    canonicalDomain: string,
): NativeAuthEnvironment => ({
    mainnetMode: MAINNET_MODE,
    iiUrl: II_URL,
    currentHostname: window.location.hostname,
    canonicalDomain,
    hash: window.location.hash,
});

export const canonicalOrigin = (env: NativeAuthEnvironment) =>
    `https://${env.canonicalDomain}`;

export const productionCallback = (env: NativeAuthEnvironment) =>
    `${canonicalOrigin(env)}/ios-auth-callback`;

export const isLocalHost = (hostname: string) =>
    hostname == "localhost" ||
    hostname == "127.0.0.1" ||
    hostname.endsWith(".localhost");

export const isNgrokHost = (hostname: string) =>
    hostname.endsWith(".ngrok-free.app") ||
    hostname.endsWith(".ngrok-free.dev") ||
    hostname.endsWith(".ngrok.app");

const isDevTunnelHost = (env: NativeAuthEnvironment) =>
    !env.mainnetMode && isNgrokHost(env.currentHostname);

export const isAllowedCallback = (
    callback: string,
    env: NativeAuthEnvironment,
) =>
    callback == productionCallback(env) ||
    (!env.mainnetMode &&
        (isLocalHost(env.currentHostname) || isDevTunnelHost(env)) &&
        callback == localCallback);

const sameIdentityProvider = (left: string, right: string) => {
    try {
        const leftURL = new URL(left);
        const rightURL = new URL(right);
        return (
            leftURL.origin == rightURL.origin &&
            leftURL.pathname == rightURL.pathname &&
            leftURL.search == rightURL.search
        );
    } catch {
        return false;
    }
};

const isAllowedMainnetIdentityProvider = (value: string) => {
    try {
        const url = new URL(value);
        if (url.username || url.password) return false;
        return (
            url.origin == "https://id.ai" &&
            url.pathname == "/" &&
            (url.search == "" || url.search == allowedMainnetIIQuery)
        );
    } catch {
        return false;
    }
};

export const isAllowedIdentityProvider = (
    value: string,
    env: NativeAuthEnvironment,
) => {
    if (env.mainnetMode) return isAllowedMainnetIdentityProvider(value);
    if (sameIdentityProvider(value, env.iiUrl)) return true;
    try {
        const url = new URL(value);
        if (url.username || url.password) return false;
        if (url.protocol != "http:" && url.protocol != "https:") return false;
        return (
            (isLocalHost(env.currentHostname) && isLocalHost(url.hostname)) ||
            (isDevTunnelHost(env) && url.hostname == env.currentHostname)
        );
    } catch {
        return false;
    }
};

export const base64UrlToBytes = (value: string) => {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = globalThis.atob(padded);
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

export const bytesToBase64Url = (bytes: Uint8Array) =>
    globalThis
        .btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=/g, "");

export const textToBase64Url = (value: string) =>
    bytesToBase64Url(new TextEncoder().encode(value));

export const normalizeAuthResponse = (value: unknown): unknown => {
    if (typeof value == "bigint") return value.toString(10);
    if (value instanceof Uint8Array) return Array.from(value);
    if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
    if (Array.isArray(value)) return value.map(normalizeAuthResponse);
    if (value && typeof value == "object") {
        const toUint8Array = Reflect.get(value, "toUint8Array");
        if (typeof toUint8Array == "function") {
            return Array.from(toUint8Array.call(value));
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
    const identityProvider = params.get("identityProvider") || env.iiUrl;
    if (!state) throw new Error("Missing state.");
    if (!isAllowedCallback(callback, env)) throw new Error("Invalid callback.");
    if (!encodedPublicKey) throw new Error("Missing session public key.");
    if (!isAllowedIdentityProvider(identityProvider, env)) {
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
