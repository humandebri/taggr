import { Actor, HttpAgent } from "@dfinity/agent";
import { IDL } from "@dfinity/candid";
import { Ed25519KeyIdentity } from "@dfinity/identity";
import type {
    CanisterResult,
    PushBatch,
    PushInstallationResolution,
    PushInvalidation,
    PushRelayEnv,
} from "./types";

export interface PushCanister {
    resolve_push_installation(
        installationId: string,
        secretHash: string,
        tokenHash: string,
    ): Promise<CanisterResult<PushInstallationResolution>>;
    push_events(
        afterId: bigint,
        limit: number,
    ): Promise<CanisterResult<PushBatch>>;
    invalidate_push_installations(
        invalidations: PushInvalidation[],
    ): Promise<CanisterResult<null>>;
}

const pushEvent = IDL.Record({
    id: IDL.Nat64,
    installation_ids: IDL.Vec(IDL.Text),
    post_id: IDL.Nat64,
    author_name: IDL.Text,
    preview: IDL.Text,
    kind: IDL.Nat8,
    recipient: IDL.Nat64,
    created_at: IDL.Nat64,
    unread_count: IDL.Nat64,
    notification_id: IDL.Nat64,
    watched_post_id: IDL.Opt(IDL.Nat64),
});

const pushBatch = IDL.Record({
    latest_id: IDL.Nat64,
    events: IDL.Vec(pushEvent),
    oldest_available_id: IDL.Nat64,
});

const resolution = IDL.Record({ user_id: IDL.Nat64, enabled_kinds: IDL.Nat8 });
const invalidation = IDL.Record({
    installation_id: IDL.Text,
    token_hash: IDL.Text,
});

const idlFactory: IDL.InterfaceFactory = ({ IDL: candid }) =>
    candid.Service({
        resolve_push_installation: candid.Func(
            [candid.Text, candid.Text, candid.Text],
            [candid.Variant({ Ok: resolution, Err: candid.Text })],
            ["query"],
        ),
        push_events: candid.Func(
            [candid.Nat64, candid.Nat16],
            [candid.Variant({ Ok: pushBatch, Err: candid.Text })],
            ["query"],
        ),
        invalidate_push_installations: candid.Func(
            [candid.Vec(invalidation)],
            [candid.Variant({ Ok: candid.Null, Err: candid.Text })],
            [],
        ),
    });

export async function pushCanister(
    env: PushRelayEnv,
    canisterId: string,
): Promise<PushCanister> {
    const identity = Ed25519KeyIdentity.fromJSON(env.RELAY_IDENTITY_JSON);
    const agent = await HttpAgent.create({ host: env.IC_HOST, identity });
    return Actor.createActor<PushCanister>(idlFactory, { agent, canisterId });
}

export function unwrapCanisterResult<T>(result: CanisterResult<T>): T {
    if ("Err" in result)
        throw new Error(`canister rejected push relay request: ${result.Err}`);
    return result.Ok;
}
