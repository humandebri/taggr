import type { ApnsSendResult } from "./apns";
import { secretMatches, sha256Hex } from "./crypto";
import {
    deleteSubscription,
    deleteSubscriptionByToken,
    relayCursor,
    setRelayCursor,
    subscription,
    subscriptionsForEvent,
    upsertSubscription,
} from "./database";
import type { PushCanister } from "./ic";
import type {
    CanisterResult,
    PushEvent,
    PushInvalidation,
    PushRelayEnv,
    SubscriptionRow,
} from "./types";
import {
    readBoundedJSON,
    RequestError,
    validateDeletionRequest,
    validateSubscriptionRequest,
} from "./validation";

const maxApnsSendsPerRun = 30;

function unwrapCanisterResult<T>(result: CanisterResult<T>): T {
    if ("Err" in result)
        throw new Error(`canister rejected push relay request: ${result.Err}`);
    return result.Ok;
}

export interface RelayDependencies {
    canister(env: PushRelayEnv, canisterId: string): Promise<PushCanister>;
    send(
        env: PushRelayEnv,
        canisterId: string,
        event: PushEvent,
        subscription: SubscriptionRow,
    ): Promise<ApnsSendResult>;
}

function json(value: unknown, status = 200): Response {
    return Response.json(value, {
        status,
        headers: { "cache-control": "no-store" },
    });
}

async function register(
    request: Request,
    env: PushRelayEnv,
    dependencies: RelayDependencies,
): Promise<Response> {
    const input = validateSubscriptionRequest(
        await readBoundedJSON(request),
        env,
    );
    const [secretHash, tokenHash] = await Promise.all([
        sha256Hex(input.bindingSecret),
        sha256Hex(input.deviceToken.toLowerCase()),
    ]);
    const actor = await dependencies.canister(env, input.canisterId);
    unwrapCanisterResult(
        await actor.resolve_push_installation(
            input.installationId,
            secretHash,
            tokenHash,
        ),
    );
    await upsertSubscription(env, input, tokenHash, secretHash);
    return json({ status: "registered" }, 201);
}

async function unregister(
    request: Request,
    env: PushRelayEnv,
    dependencies: RelayDependencies,
): Promise<Response> {
    const input = validateDeletionRequest(await readBoundedJSON(request), env);
    const existing = await subscription(
        env,
        input.canisterId,
        input.installationId,
    );
    if (!existing) return json({ status: "removed" });
    if (
        !(await secretMatches(
            input.bindingSecret,
            existing.binding_secret_hash,
        ))
    ) {
        throw new RequestError(403, "installation proof rejected");
    }
    const actor = await dependencies.canister(env, input.canisterId);
    unwrapCanisterResult(
        await actor.invalidate_push_installations([
            {
                installation_id: input.installationId,
                token_hash: existing.token_hash,
            },
        ]),
    );
    await deleteSubscription(env, input.canisterId, input.installationId);
    return json({ status: "removed" });
}

export async function handleRequest(
    request: Request,
    env: PushRelayEnv,
    dependencies: RelayDependencies,
): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health")
        return json({ status: "ok" });
    if (url.pathname === "/__scheduled")
        return json({ error: "not found" }, 404);
    if (request.method === "POST" && url.pathname === "/v1/subscriptions")
        return register(request, env, dependencies);
    if (request.method === "DELETE" && url.pathname === "/v1/subscriptions")
        return unregister(request, env, dependencies);
    return json({ error: "not found" }, 404);
}

async function flushInvalidations(
    actor: PushCanister,
    invalidations: PushInvalidation[],
): Promise<void> {
    if (invalidations.length === 0) return;
    unwrapCanisterResult(
        await actor.invalidate_push_installations(invalidations),
    );
}

export async function processCanister(
    env: PushRelayEnv,
    canisterId: string,
    sendBudget: { used: number },
    dependencies: RelayDependencies,
): Promise<void> {
    const actor = await dependencies.canister(env, canisterId);
    let cursor = await relayCursor(env, canisterId);
    const batch = unwrapCanisterResult(await actor.push_events(cursor, 50));
    const earliestCursor =
        batch.oldest_available_id > 0n ? batch.oldest_available_id - 1n : 0n;
    if (cursor < earliestCursor) {
        cursor = earliestCursor;
        await setRelayCursor(env, canisterId, cursor);
    }
    const invalidations: PushInvalidation[] = [];
    const permanentlyRejected: Array<{
        environment: "sandbox" | "production";
        tokenHash: string;
    }> = [];
    const rejectedTokens = new Set<string>();
    let completedCursor = cursor;

    for (const event of batch.events) {
        if (event.id <= cursor) continue;
        const subscriptions = await subscriptionsForEvent(
            env,
            canisterId,
            event.installation_ids,
        );
        let complete = true;
        for (const current of subscriptions) {
            const rejectedKey = `${current.apns_environment}:${current.token_hash}`;
            if (rejectedTokens.has(rejectedKey)) continue;
            if (sendBudget.used >= maxApnsSendsPerRun) {
                complete = false;
                break;
            }
            sendBudget.used += 1;
            const result = await dependencies.send(
                env,
                canisterId,
                event,
                current,
            );
            if (result.outcome === "transient") {
                console.warn(
                    JSON.stringify({
                        message: "APNs delivery deferred",
                        canisterId,
                        eventId: event.id.toString(),
                        reason: result.reason,
                    }),
                );
                complete = false;
                break;
            }
            if (result.outcome === "permanent") {
                invalidations.push({
                    installation_id: current.installation_id,
                    token_hash: current.token_hash,
                });
                permanentlyRejected.push({
                    environment: current.apns_environment,
                    tokenHash: current.token_hash,
                });
                rejectedTokens.add(rejectedKey);
            }
        }
        if (!complete) break;
        completedCursor = event.id;
    }
    await flushInvalidations(actor, invalidations);
    for (const rejected of permanentlyRejected) {
        await deleteSubscriptionByToken(
            env,
            rejected.environment,
            rejected.tokenHash,
        );
    }
    if (completedCursor > cursor)
        await setRelayCursor(env, canisterId, completedCursor);
}

export async function deliverScheduled(
    controller: ScheduledController,
    env: PushRelayEnv,
    dependencies: RelayDependencies,
): Promise<void> {
    const canisters = [env.MAINNET_CANISTER_ID, env.STAGING_CANISTER_ID];
    if (Math.floor(controller.scheduledTime / 60_000) % 2 === 1)
        canisters.reverse();
    const sendBudget = { used: 0 };
    for (const canisterId of canisters)
        await processCanister(env, canisterId, sendBudget, dependencies);
    console.log(
        JSON.stringify({
            message: "push relay run complete",
            apnsSends: sendBudget.used,
        }),
    );
}
