// Hosts the iOS identity bridge inside the certified TAGGR frontend.
// Native iOS opens this route in a system auth session and receives the result
// through the production Universal Link callback.
import * as React from "react";
import { ButtonWithLoading } from "./common";
import { Infinity } from "./icons";
import {
    buildCallbackUrl,
    canonicalOrigin,
    messageKind,
    nativeAuthEnvironment,
    normalizeAuthResponse,
    parseNativeAuthParams,
    textToBase64Url,
} from "./native_auth_core";

const interruptionCheckIntervalMs = 500;

const nativeAuthCanonicalDomain = () => window.location.host;

const nativeAuthCanonicalOrigin = () => window.location.origin;

const redirectToCallback = (callbackURL: string) => {
    window.location.href = callbackURL;
};

export const NativeAuth = () => {
    const cleanupRef = React.useRef<() => void>(() => {});
    const env = React.useMemo(
        () =>
            nativeAuthEnvironment(
                nativeAuthCanonicalDomain(),
                nativeAuthCanonicalOrigin(),
            ),
        [],
    );

    React.useEffect(() => () => cleanupRef.current(), []);

    const parsed = React.useMemo(() => {
        try {
            return { value: parseNativeAuthParams(env), error: "" };
        } catch (error) {
            return {
                value: null,
                error: error instanceof Error ? error.message : String(error),
            };
        }
    }, [env]);

    const start = async () => {
        if (!parsed.value) return;
        const params = parsed.value;
        cleanupRef.current();

        const identityURL = new URL(params.identityProvider);
        identityURL.hash = "#authorize";
        const identityOrigin = identityURL.origin;
        let idpWindow: Window | null = null;
        let interruptionTimer = 0;
        let finished = false;

        const cleanup = () => {
            window.removeEventListener("message", handleMessage);
            if (interruptionTimer) window.clearTimeout(interruptionTimer);
            cleanupRef.current = () => {};
        };

        const finish = (kind: "result" | "error", payload: string) => {
            if (finished) return;
            finished = true;
            cleanup();
            const callbackURL = buildCallbackUrl(
                params.callback,
                params.state,
                kind,
                payload,
            );
            redirectToCallback(callbackURL);
        };

        const fail = (message: string) => {
            finish("error", textToBase64Url(message));
        };

        const checkInterruption = () => {
            if (!idpWindow || finished) return;
            if (idpWindow.closed) {
                fail("Sign-in was interrupted.");
                return;
            }
            interruptionTimer = window.setTimeout(
                checkInterruption,
                interruptionCheckIntervalMs,
            );
        };

        const handleMessage = (event: MessageEvent<unknown>) => {
            if (event.origin != identityOrigin) return;
            if (!idpWindow || event.source != idpWindow) return;
            const kind = messageKind(event.data);
            if (kind == "authorize-ready") {
                idpWindow.postMessage(
                    {
                        kind: "authorize-client",
                        sessionPublicKey: params.sessionPublicKey,
                        maxTimeToLive: params.maxTimeToLive,
                        derivationOrigin: canonicalOrigin(env),
                    },
                    identityOrigin,
                );
                return;
            }
            if (kind == "authorize-client-success") {
                finish(
                    "result",
                    textToBase64Url(
                        JSON.stringify(normalizeAuthResponse(event.data)),
                    ),
                );
                return;
            }
            if (kind == "authorize-client-failure") {
                const text =
                    event.data && typeof event.data == "object"
                        ? Reflect.get(event.data, "text")
                        : "";
                fail(typeof text == "string" ? text : "Sign-in failed.");
            }
        };

        window.addEventListener("message", handleMessage);
        cleanupRef.current = cleanup;
        idpWindow = window.open(identityURL.toString(), "taggrIdentity");
        if (!idpWindow) {
            fail("Sign-in window could not open.");
            return;
        }
        checkInterruption();
    };

    return (
        <div className="native_auth_bridge text_centered">
            <div className="native_auth_content column_container">
                <h1 className="native_auth_title">
                    <Infinity /> Internet Identity
                </h1>
                <p
                    className="native_auth_status small_text"
                    style={parsed.error ? { color: "red" } : undefined}
                >
                    {parsed.error || "Sign in to TAGGR for iOS."}
                </p>
                <ButtonWithLoading
                    classNameArg="active native_auth_action"
                    disabled={!parsed.value}
                    label="Continue"
                    onClick={start}
                />
            </div>
        </div>
    );
};
