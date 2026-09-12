import * as React from "react";
import { IDL } from "@dfinity/candid";
import { fetchCanisterStatus, upgradeBucket } from "./user_storage";
import { Principal } from "@dfinity/principal";
import { CANISTER_ID } from "./env";
import {
    icrcTransfer,
    ICP_LEDGER_ID,
    ICP_DEFAULT_FEE,
    ButtonWithLoading,
    signOut,
    getCanonicalDomain,
    onCanonicalDomain,
} from "./common";

export type DeletionStatus = {
    state: "active" | "deleting" | "deleted";
    processed: number;
    total: number;
    balance: number;
    treasury_e8s: number;
    bucket: string | null;
    media_closed: boolean;
};
export let deletionStatus: DeletionStatus | null = null;
export const setDeletionStatus = (status: DeletionStatus | null) => {
    deletionStatus = status;
};

export const DeletedAccount = () => {
    const [error, setError] = React.useState("");
    const [, refresh] = React.useReducer((n: number) => n + 1, 0);
    const running = React.useRef(false);
    const mounted = React.useRef(false);
    const cancelled = React.useRef(false);
    React.useEffect(() => {
        mounted.current = true;
        const cancel = () => {
            cancelled.current = true;
        };
        window.addEventListener("hashchange", cancel);
        window.addEventListener("pagehide", cancel);
        return () => {
            mounted.current = false;
            cancel();
            window.removeEventListener("hashchange", cancel);
            window.removeEventListener("pagehide", cancel);
        };
    }, []);
    const resume = async () => {
        if (running.current || !onCanonicalDomain()) return;
        running.current = true;
        cancelled.current = false;
        const api = window.api;
        const principal = window.principalId;
        const current = () =>
            mounted.current &&
            !cancelled.current &&
            window.api === api &&
            window.principalId === principal;
        setError("");
        try {
            const status = deletionStatus;
            if (!status || status.state !== "deleting") return;
            if (!status.media_closed && status.bucket) {
                const bucket = Principal.fromText(status.bucket);
                const storage = await fetchCanisterStatus(bucket);
                if (!current()) return;
                const hash = storage.module_hash
                    ?.map((b) => b.toString(16).padStart(2, "0"))
                    .join("");
                // Same legacy release recognized by the iOS deletion client.
                if (
                    hash ===
                    "418202879263a81a9479620628be4e0543367c178addb92d5fd5873ba23bde10"
                ) {
                    await upgradeBucket(bucket, current);
                    if (!current()) return;
                }
                const closed = await api.call_raw(
                    bucket,
                    "close_media",
                    IDL.encode([], []),
                );
                if (!current()) return;
                if (closed === null)
                    throw new Error(
                        "Image storage could not be closed. Unknown storage code is not automatically upgraded.",
                    );
            }
            while (current()) {
                const result = (await api.call(
                    "continue_account_deletion",
                )) as { Ok?: DeletionStatus; Err?: string } | null;
                if (!current()) return;
                if (
                    !result?.Ok ||
                    !["deleting", "deleted"].includes(result.Ok.state)
                ) {
                    throw new Error(
                        result?.Err ||
                            "Deletion status could not be confirmed. Please retry.",
                    );
                }
                setDeletionStatus(result.Ok);
                refresh();
                if (result.Ok.state === "deleted") break;
            }
        } catch (e) {
            if (current()) setError(e instanceof Error ? e.message : String(e));
        } finally {
            running.current = false;
        }
    };
    const status = deletionStatus;
    if (!status) return null;
    const config = window.backendCache.config;
    return (
        <main className="spaced">
            <h1>
                {status.state === "deleted"
                    ? "Account deleted"
                    : "Deletion in progress"}
            </h1>
            <p>
                Posts processed: {status.processed} / {status.total}. SNS
                actions are no longer available.
            </p>
            <p>
                Profile and post contents are removed. Image storage stops
                serving images; image bytes are not physically erased.
                Transaction and governance records remain.
            </p>
            {status.state === "deleting" &&
                (onCanonicalDomain() ? (
                    <ButtonWithLoading
                        label="CONTINUE DELETION"
                        onClick={resume}
                    />
                ) : (
                    <p>
                        To continue deletion,{" "}
                        <a href={`https://${getCanonicalDomain()}/#/sign-in`}>
                            sign in on the canonical domain
                        </a>{" "}
                        with the account that owns your image storage.
                    </p>
                ))}
            {error && <p role="alert">{error}</p>}
            <h2>Asset recovery</h2>
            <p>
                Remaining TAGGR:{" "}
                {status.balance / Math.pow(10, config.token_decimals)}
            </p>
            <ButtonWithLoading
                label="SEND TAGGR"
                onClick={async () => {
                    await icrcTransfer(
                        Principal.fromText(CANISTER_ID),
                        config.token_symbol,
                        config.token_decimals,
                        config.transaction_fee,
                    );
                    await window.reloadUser();
                }}
            />
            <ButtonWithLoading
                label="SEND ICP"
                onClick={async () => {
                    await icrcTransfer(
                        ICP_LEDGER_ID,
                        "ICP",
                        8,
                        ICP_DEFAULT_FEE,
                    );
                }}
            />
            <ButtonWithLoading
                label="WITHDRAW ICP REWARDS"
                onClick={async () => {
                    const result: any =
                        await window.api.call("withdraw_rewards");
                    if (!result || result.Err) {
                        setError(
                            result?.Err ||
                                "Withdrawal could not be confirmed. Refresh your balance before retrying.",
                        );
                        return;
                    }
                    setError("");
                    await window.reloadUser();
                }}
            />
            <ButtonWithLoading
                label="SIGN OUT"
                onClick={async () => {
                    cancelled.current = true;
                    await signOut();
                }}
            />
        </main>
    );
};
