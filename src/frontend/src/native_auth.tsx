// Hosts the iOS Internet Identity bridge inside the certified TAGGR frontend.
// Native iOS opens this route in a system auth session and receives the result
// through the production Universal Link callback.
import * as React from "react";
import { ButtonWithLoading, getCanonicalDomain } from "./common";
import { MAINNET_MODE } from "./env";
import { Infinity } from "./icons";
import {
    buildCallbackUrl,
    canonicalOrigin,
    messageKind,
    nativeAuthEnvironment,
    nativeAuthRouteHash,
    normalizeAuthResponse,
    parseNativeAuthParams,
    textToBase64Url,
} from "./native_auth_core";

const interruptionCheckIntervalMs = 500;

const redirectToCallback = (
    callbackURL: string,
    statusCallback: (status: string) => void,
) => {
    window.location.href = callbackURL;
    statusCallback("Returning to TAGGR for iOS...");
};

export const NativeAuth = () => {
    const cleanupRef = React.useRef<() => void>(() => {});
    const [status, setStatus] = React.useState(
        "Continue in Internet Identity.",
    );
    const env = React.useMemo(
        () => nativeAuthEnvironment(getCanonicalDomain()),
        [],
    );

    React.useEffect(() => {
        if (MAINNET_MODE && window.location.origin != canonicalOrigin(env)) {
            window.location.replace(
                `${canonicalOrigin(env)}/${nativeAuthRouteHash(env)}`,
            );
        }
    }, [env]);

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
        setStatus("Waiting for Internet Identity...");

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
            redirectToCallback(callbackURL, setStatus);
        };

        const fail = (message: string) => {
            finish("error", textToBase64Url(message));
        };

        const checkInterruption = () => {
            if (!idpWindow || finished) return;
            if (idpWindow.closed) {
                fail("Internet Identity authorization was interrupted.");
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
                fail(
                    typeof text == "string"
                        ? text
                        : "Internet Identity authorization failed.",
                );
            }
        };

        window.addEventListener("message", handleMessage);
        cleanupRef.current = cleanup;
        idpWindow = window.open(identityURL.toString(), "taggrIdentity");
        if (!idpWindow) {
            fail("Internet Identity could not open.");
            return;
        }
        checkInterruption();
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
