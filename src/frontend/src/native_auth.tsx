// Hosts the iOS identity bridge inside the certified TAGGR frontend.
// Native iOS opens this route in a system auth session and receives the result
// through the production Universal Link callback.
import * as React from "react";
import { ButtonWithLoading } from "./common";
import { AppleLogo, GoogleLogo, Infinity } from "./icons";
import {
    buildCallbackUrl,
    buildIdentityUrl,
    messageKind,
    NativeLoginMethod,
    nativeAuthEnvironment,
    normalizeAuthResponse,
    parseNativeAuthParams,
    textToBase64Url,
} from "./native_auth_core";

const interruptionCheckIntervalMs = 500;

export const NativeAuth = () => {
    const cleanupRef = React.useRef<() => void>(() => {});
    const env = React.useMemo(
        () =>
            nativeAuthEnvironment(window.location.host, window.location.origin),
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

    const start = async (method: NativeLoginMethod) => {
        if (!parsed.value) return;
        const params = parsed.value;
        cleanupRef.current();

        const identityURL = buildIdentityUrl(params.identityProvider, method);
        const identityOrigin = identityURL.origin;
        let idpWindow: Window | null = null;
        let interruptionTimer = 0;
        let finished = false;

        const cleanup = () => {
            window.removeEventListener("message", handleMessage);
            if (interruptionTimer) window.clearTimeout(interruptionTimer);
            cleanupRef.current = () => {};
        };

        const finishInIdentityWindow = (
            kind: "result" | "error",
            payload: string,
        ) => {
            if (finished || !idpWindow || idpWindow.closed) return;
            finished = true;
            cleanup();
            idpWindow.location.href = buildCallbackUrl(
                params.callback,
                params.state,
                kind,
                payload,
            );
        };

        const checkInterruption = () => {
            if (!idpWindow || finished) return;
            if (idpWindow.closed) {
                finished = true;
                cleanup();
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
                        derivationOrigin: env.canonicalOrigin,
                    },
                    identityOrigin,
                );
                return;
            }
            if (kind == "authorize-client-success") {
                finishInIdentityWindow(
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
                finishInIdentityWindow(
                    "error",
                    textToBase64Url(
                        typeof text == "string" ? text : "Sign-in failed.",
                    ),
                );
            }
        };

        window.addEventListener("message", handleMessage);
        cleanupRef.current = cleanup;
        idpWindow = window.open(identityURL.toString(), "taggrIdentity");
        if (!idpWindow) {
            finished = true;
            cleanup();
            window.location.href = buildCallbackUrl(
                params.callback,
                params.state,
                "error",
                textToBase64Url("Sign-in window could not open."),
            );
            return;
        }
        checkInterruption();
    };

    return (
        <div className="vertically_spaced column_container">
            <div className="text_centered">
                <h1>Sign-in</h1>
                <p className={parsed.error ? "small_text banner" : undefined}>
                    {parsed.error || "Continue with Internet Identity."}
                </p>
                <div className="left_spaced right_spaced bottom_spaced">
                    <ButtonWithLoading
                        classNameArg="active"
                        disabled={!parsed.value}
                        label={
                            <>
                                <span className="native_auth_provider_icon">
                                    <Infinity />
                                </span>
                                Continue with Passkey
                            </>
                        }
                        onClick={() => start("passkey")}
                        styleArg={{ width: "100%" }}
                    />
                    <ButtonWithLoading
                        classNameArg="active top_spaced"
                        disabled={!parsed.value}
                        label={
                            <>
                                <span className="native_auth_provider_icon">
                                    <AppleLogo />
                                </span>
                                Continue with Apple
                            </>
                        }
                        onClick={() => start("apple")}
                        styleArg={{ width: "100%" }}
                    />
                    <ButtonWithLoading
                        classNameArg="active top_spaced"
                        disabled={!parsed.value}
                        label={
                            <>
                                <span className="native_auth_provider_icon">
                                    <GoogleLogo />
                                </span>
                                Continue with Google
                            </>
                        }
                        onClick={() => start("google")}
                        styleArg={{ width: "100%" }}
                    />
                </div>
            </div>
        </div>
    );
};
