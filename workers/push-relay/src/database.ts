import type {
    ApnsEnvironment,
    PushRelayEnv,
    SubscriptionRequest,
    SubscriptionRow,
} from "./types";

export async function upsertSubscription(
    env: PushRelayEnv,
    request: SubscriptionRequest,
    tokenHash: string,
    secretHash: string,
): Promise<void> {
    const now = Date.now();
    await env.DB.batch([
        env.DB.prepare(
            `DELETE FROM subscriptions
       WHERE installation_id = ? OR (apns_environment = ? AND token_hash = ?)`,
        ).bind(request.installationId, request.apnsEnvironment, tokenHash),
        env.DB.prepare(
            `INSERT INTO subscriptions
       (canister_id, installation_id, token_hash, binding_secret_hash, device_token, apns_environment, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(canister_id, installation_id) DO UPDATE SET
         token_hash = excluded.token_hash,
         binding_secret_hash = excluded.binding_secret_hash,
         device_token = excluded.device_token,
         apns_environment = excluded.apns_environment,
         updated_at = excluded.updated_at`,
        ).bind(
            request.canisterId,
            request.installationId,
            tokenHash,
            secretHash,
            request.deviceToken.toLowerCase(),
            request.apnsEnvironment,
            now,
        ),
    ]);
}

export async function subscription(
    env: PushRelayEnv,
    canisterId: string,
    installationId: string,
): Promise<SubscriptionRow | null> {
    return env.DB.prepare(
        "SELECT * FROM subscriptions WHERE canister_id = ? AND installation_id = ?",
    )
        .bind(canisterId, installationId)
        .first<SubscriptionRow>();
}

export async function subscriptionsForEvent(
    env: PushRelayEnv,
    canisterId: string,
    installationIds: string[],
): Promise<SubscriptionRow[]> {
    if (installationIds.length === 0) return [];
    const placeholders = installationIds.map(() => "?").join(",");
    const result = await env.DB.prepare(
        `SELECT * FROM subscriptions WHERE canister_id = ? AND installation_id IN (${placeholders})`,
    )
        .bind(canisterId, ...installationIds)
        .all<SubscriptionRow>();
    return result.results;
}

export async function deleteSubscription(
    env: PushRelayEnv,
    canisterId: string,
    installationId: string,
): Promise<void> {
    await env.DB.prepare(
        "DELETE FROM subscriptions WHERE canister_id = ? AND installation_id = ?",
    )
        .bind(canisterId, installationId)
        .run();
}

export async function deleteSubscriptionByToken(
    env: PushRelayEnv,
    environment: ApnsEnvironment,
    tokenHash: string,
): Promise<void> {
    await env.DB.prepare(
        "DELETE FROM subscriptions WHERE apns_environment = ? AND token_hash = ?",
    )
        .bind(environment, tokenHash)
        .run();
}

export async function relayCursor(
    env: PushRelayEnv,
    canisterId: string,
): Promise<bigint> {
    const value = await env.DB.prepare(
        "SELECT last_event_id FROM relay_cursors WHERE canister_id = ?",
    )
        .bind(canisterId)
        .first<number>("last_event_id");
    return BigInt(value ?? 0);
}

export async function setRelayCursor(
    env: PushRelayEnv,
    canisterId: string,
    eventId: bigint,
): Promise<void> {
    await env.DB.prepare(
        `INSERT INTO relay_cursors (canister_id, last_event_id, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(canister_id) DO UPDATE SET
       last_event_id = excluded.last_event_id,
       updated_at = excluded.updated_at`,
    )
        .bind(canisterId, eventId.toString(), Date.now())
        .run();
}
