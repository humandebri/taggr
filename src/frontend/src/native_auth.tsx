// src/frontend/src/native_auth.tsx
// Hosts the iOS Internet Identity bridge inside the certified TAGGR frontend.
// Native iOS opens this route in a system auth session and receives the result
// through either the production Universal Link callback or the local URL scheme.
import * as React from "react";
import { ButtonWithLoading, getCanonicalDomain } from "./common";
import { II_URL, MAINNET_MODE } from "./env";
import { Infinity } from "./icons";

const localCallback = "taggr://identity-callback";
const nativeMaxTimeToLive = "2592000000000000";

const isLocalHost = () => {
    const { hostname } = window.location;
    return (
        hostname == "localhost" ||
        hostname == "127.0.0.1" ||
        hostname.endsWith(".localhost")
    );
};

const isNgrokHost = (hostname: string) =>
    hostname.endsWith(".ngrok-free.app") ||
    hostname.endsWith(".ngrok-free.dev") ||
    hostname.endsWith(".ngrok.app");

const isDevTunnelHost = () =>
    !MAINNET_MODE && isNgrokHost(window.location.hostname);

const productionCallback = () =>
    `https://${getCanonicalDomain()}/ios-auth-callback`;

const isAllowedCallback = (callback: string) =>
    callback == productionCallback() ||
    (!MAINNET_MODE &&
        (isLocalHost() || isDevTunnelHost()) &&
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

const isAllowedIdentityProvider = (value: string) => {
    if (sameIdentityProvider(value, II_URL)) return true;
    if (MAINNET_MODE) return false;
    try {
        const url = new URL(value);
        if (url.origin == "https://id.ai") return true;
        return (
            url.hostname == "localhost" ||
            url.hostname == "127.0.0.1" ||
            url.hostname.endsWith(".localhost") ||
            (isDevTunnelHost() && isNgrokHost(url.hostname))
        );
    } catch {
        return false;
    }
};

const base64UrlToBytes = (value: string) => {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = window.atob(padded);
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

const bytesToBase64Url = (bytes: Uint8Array) =>
    window
        .btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=/g, "");

const textToBase64Url = (value: string) =>
    bytesToBase64Url(new TextEncoder().encode(value));

const normalize = (value: unknown): unknown => {
    if (typeof value == "bigint") return value.toString(10);
    if (value instanceof Uint8Array) return Array.from(value);
    if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
    if (Array.isArray(value)) return value.map(normalize);
    if (value && typeof value == "object") {
        const toUint8Array = Reflect.get(value, "toUint8Array");
        if (typeof toUint8Array == "function") {
            return Array.from(toUint8Array.call(value));
        }
        return Object.fromEntries(
            Object.entries(value).map(([key, nested]) => [
                key,
                normalize(nested),
            ]),
        );
    }
    return value;
};

const messageKind = (value: unknown) => {
    if (!value || typeof value != "object") return "";
    const kind = Reflect.get(value, "kind");
    return typeof kind == "string" ? kind : "";
};

const parseNativeAuthParams = () => {
    const query = window.location.hash.split("?")[1] || "";
    const params = new URLSearchParams(query);
    const state = params.get("state") || "";
    const callback = params.get("callback") || "";
    const encodedPublicKey = params.get("sessionPublicKey") || "";
    const maxTimeToLive = params.get("maxTimeToLive") || nativeMaxTimeToLive;
    const identityProvider = params.get("identityProvider") || II_URL;
    if (!state) throw new Error("Missing state.");
    if (!isAllowedCallback(callback)) throw new Error("Invalid callback.");
    if (!encodedPublicKey) throw new Error("Missing session public key.");
    if (!isAllowedIdentityProvider(identityProvider)) {
        throw new Error("Invalid identity provider.");
    }
    return {
        state,
        callback,
        identityProvider,
        sessionPublicKey: base64UrlToBytes(encodedPublicKey),
        maxTimeToLive: BigInt(maxTimeToLive),
    };
};

export const NativeAuth = () => {
    const cleanupRef = React.useRef<() => void>(() => {});
    const [status, setStatus] = React.useState(
        "Continue in Internet Identity.",
    );
    const parsed = React.useMemo(() => {
        try {
            return { value: parseNativeAuthParams(), error: "" };
        } catch (error) {
            return {
                value: null,
                error: error instanceof Error ? error.message : String(error),
            };
        }
    }, []);

    const start = async () => {
        if (!parsed.value) return;
        cleanupRef.current();
        setStatus("Waiting for Internet Identity...");
        const identityURL = new URL(parsed.value.identityProvider);
        identityURL.hash = "#authorize";
        const identityOrigin = identityURL.origin;
        const idpWindow = window.open(identityURL.toString(), "taggrIdentity");
        if (!idpWindow) {
            setStatus("Internet Identity could not open.");
            return;
        }

        const cleanup = () => {
            window.removeEventListener("message", handleMessage);
        };
        cleanupRef.current = cleanup;

        const finish = (kind: "result" | "error", payload: string) => {
            cleanup();
            const callbackURL = `${parsed.value.callback}?state=${encodeURIComponent(parsed.value.state)}&${kind}=${payload}`;
            idpWindow.location.href = callbackURL;
        };

        const handleMessage = (event: MessageEvent<unknown>) => {
            if (event.origin != identityOrigin) return;
            const kind = messageKind(event.data);
            if (kind == "authorize-ready") {
                idpWindow.postMessage(
                    {
                        kind: "authorize-client",
                        sessionPublicKey: parsed.value.sessionPublicKey,
                        maxTimeToLive: parsed.value.maxTimeToLive,
                    },
                    identityOrigin,
                );
                return;
            }
            if (kind == "authorize-client-success") {
                finish(
                    "result",
                    textToBase64Url(JSON.stringify(normalize(event.data))),
                );
                return;
            }
            if (kind == "authorize-client-failure") {
                const text =
                    event.data && typeof event.data == "object"
                        ? Reflect.get(event.data, "text")
                        : "";
                finish(
                    "error",
                    textToBase64Url(
                        typeof text == "string"
                            ? text
                            : "Internet Identity authorization failed.",
                    ),
                );
            }
        };

        window.addEventListener("message", handleMessage);
    };

    return (
        <div className="column_container text_centered vertically_spaced">
            <h1>
                <Infinity /> Internet Identity
            </h1>
            <p
                className="small_text"
                style={parsed.error ? { color: "red" } : undefined}
            >
                {parsed.error || status}
            </p>
            <ButtonWithLoading
                classNameArg="active"
                disabled={!parsed.value}
                label="CONTINUE WITH INTERNET IDENTITY"
                onClick={start}
            />
        </div>
    );
};
