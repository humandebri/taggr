// Keeps native iOS Internet Identity URL validation and payload conversion
// outside the React component so auth edge cases can be tested directly.

type NativeAuthEnvironment = {
    canonicalDomain: string;
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

const nativeMaxTimeToLive = "2592000000000000";
const nativeMaxTimeToLiveNanos = BigInt(nativeMaxTimeToLive);
const allowedMainnetIIQuery = "?feature_flag_guided_upgrade=true";
const nativeIdentityProvider = `https://id.ai/${allowedMainnetIIQuery}`;

export const nativeAuthEnvironment = (
    canonicalDomain: string,
): NativeAuthEnvironment => ({
    canonicalDomain,
    hash: window.location.hash,
    search: window.location.search,
});

export const canonicalOrigin = (env: NativeAuthEnvironment) =>
    `https://${env.canonicalDomain}`;

const productionCallback = (env: NativeAuthEnvironment) =>
    `${canonicalOrigin(env)}/ios-auth-callback`;

export const nativeAuthRouteHash = (env: NativeAuthEnvironment) => {
    const hash = env.hash || "#/native-auth";
    if (hash.includes("?") || !env.search) return hash;
    return `${hash}${env.search}`;
};

const isAllowedCallback = (callback: string, env: NativeAuthEnvironment) =>
    callback == productionCallback(env);

export const isAllowedIdentityProvider = (value: string) => {
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

const base64UrlToBytes = (value: string) => {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = globalThis.atob(padded);
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

const bytesToBase64Url = (bytes: Uint8Array) =>
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
    const hashQuery = queryStart >= 0 ? env.hash.slice(queryStart + 1) : "";
    const query = hashQuery || env.search.replace(/^\?/, "");
    const params = new URLSearchParams(query);
    const state = params.get("state") || "";
    const callback = params.get("callback") || "";
    const encodedPublicKey = params.get("sessionPublicKey") || "";
    const maxTimeToLive = params.get("maxTimeToLive") || nativeMaxTimeToLive;
    const identityProvider =
        params.get("identityProvider") || nativeIdentityProvider;
    if (!state) throw new Error("Missing state.");
    if (!isAllowedCallback(callback, env)) throw new Error("Invalid callback.");
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
