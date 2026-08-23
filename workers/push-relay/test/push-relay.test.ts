import { applyD1Migrations, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { apnsPayload } from "../src/apns";
import { relayCursor } from "../src/database";
import {
    handleRequest,
    processCanister,
    type RelayDependencies,
} from "../src/relay";
import type {
    PushBatch,
    PushEvent,
    PushInvalidation,
    PushRelayEnv,
} from "../src/types";
import {
    readBoundedJSON,
    RequestError,
    validateSubscriptionRequest,
} from "../src/validation";

interface TestEnv extends PushRelayEnv {
    TEST_MIGRATIONS: D1Migration[];
}

const testEnv = env as TestEnv;

const canisters = {
    MAINNET_CANISTER_ID: "6qfxa-ryaaa-aaaai-qbhsq-cai",
    STAGING_CANISTER_ID: "e4i5g-biaaa-aaaao-ai7ja-cai",
} as const;

const event: PushEvent = {
    id: 9n,
    installation_ids: ["01234567-89ab-cdef-0123-456789abcdef"],
    post_id: 42n,
    author_name: "alice",
    preview: "hello",
    kind: 2,
    recipient: 7n,
    created_at: 1n,
    unread_count: 3n,
    notification_id: 11n,
    watched_post_id: [],
};

function dependencies(
    batch: PushBatch,
    outcomes: Array<
        | { outcome: "success" }
        | { outcome: "permanent"; reason: string }
        | { outcome: "transient"; reason: string }
    > = [{ outcome: "success" }],
    invalidations: PushInvalidation[] = [],
): RelayDependencies {
    let sendIndex = 0;
    return {
        canister: async () => ({
            resolve_push_installation: async () => ({
                Ok: { user_id: 1n, enabled_kinds: 15 },
            }),
            push_events: async () => ({ Ok: batch }),
            invalidate_push_installations: async (values) => {
                invalidations.push(...values);
                return { Ok: null };
            },
        }),
        send: async () => outcomes[Math.min(sendIndex++, outcomes.length - 1)]!,
    };
}

async function addSubscription(
    installationId = event.installation_ids[0]!,
): Promise<void> {
    await testEnv.DB.prepare(
        `INSERT INTO subscriptions
         (canister_id, installation_id, token_hash, binding_secret_hash, device_token, apns_environment, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
        .bind(
            canisters.MAINNET_CANISTER_ID,
            installationId,
            "11".repeat(32),
            "22".repeat(32),
            "33".repeat(32),
            "production",
            Date.now(),
        )
        .run();
}

beforeEach(async () => {
    await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
    await testEnv.DB.batch([
        testEnv.DB.prepare("DELETE FROM subscriptions"),
        testEnv.DB.prepare("DELETE FROM relay_cursors"),
        testEnv.DB.prepare("DELETE FROM apns_provider_tokens"),
    ]);
});

describe("push relay", () => {
    it("builds the alert payload with navigation identifiers", () => {
        expect(apnsPayload(event, canisters.MAINNET_CANISTER_ID)).toEqual({
            aps: {
                alert: { title: "@alice mentioned you", body: "hello" },
                sound: "default",
                badge: 3,
            },
            eventId: "9",
            notificationId: "11",
            postId: "42",
            kind: 2,
            canisterId: canisters.MAINNET_CANISTER_ID,
        });
    });

    it("binds mainnet registrations to production APNs", () => {
        const request = validateSubscriptionRequest(
            {
                canisterId: canisters.MAINNET_CANISTER_ID,
                installationId: "01234567-89ab-cdef-0123-456789abcdef",
                bindingSecret: "ab".repeat(32),
                deviceToken: "cd".repeat(32),
                apnsEnvironment: "production",
            },
            canisters,
        );
        expect(request.apnsEnvironment).toBe("production");
    });

    it("accepts sandbox APNs for a debug build using the mainnet canister", () => {
        const request = validateSubscriptionRequest(
            {
                canisterId: canisters.MAINNET_CANISTER_ID,
                installationId: "01234567-89ab-cdef-0123-456789abcdef",
                bindingSecret: "ab".repeat(32),
                deviceToken: "cd".repeat(32),
                apnsEnvironment: "sandbox",
            },
            canisters,
        );
        expect(request.apnsEnvironment).toBe("sandbox");
    });

    it("accepts variable-length even hexadecimal APNs tokens", () => {
        for (const deviceToken of ["ab", "cd".repeat(48), "ef".repeat(256)]) {
            expect(
                validateSubscriptionRequest(
                    {
                        canisterId: canisters.MAINNET_CANISTER_ID,
                        installationId: "01234567-89ab-cdef-0123-456789abcdef",
                        bindingSecret: "ab".repeat(32),
                        deviceToken,
                        apnsEnvironment: "production",
                    },
                    canisters,
                ).deviceToken,
            ).toBe(deviceToken);
        }
        for (const deviceToken of ["a", "zz", "ab".repeat(257)]) {
            expect(() =>
                validateSubscriptionRequest(
                    {
                        canisterId: canisters.MAINNET_CANISTER_ID,
                        installationId: "01234567-89ab-cdef-0123-456789abcdef",
                        bindingSecret: "ab".repeat(32),
                        deviceToken,
                        apnsEnvironment: "production",
                    },
                    canisters,
                ),
            ).toThrow(RequestError);
        }
    });

    it("stops an unlabelled request stream after the 4KB limit", async () => {
        const request = new Request(
            "https://push.taggr.test/v1/subscriptions",
            {
                method: "POST",
                body: new ReadableStream({
                    start(controller) {
                        controller.enqueue(new Uint8Array(4096));
                        controller.enqueue(new Uint8Array(1));
                        controller.close();
                    },
                }),
            },
        );
        await expect(readBoundedJSON(request)).rejects.toMatchObject({
            status: 413,
        });
    });

    it("rejects an unknown APNs environment", () => {
        expect(() =>
            validateSubscriptionRequest(
                {
                    canisterId: canisters.MAINNET_CANISTER_ID,
                    installationId: "01234567-89ab-cdef-0123-456789abcdef",
                    bindingSecret: "ab".repeat(32),
                    deviceToken: "cd".repeat(32),
                    apnsEnvironment: "invalid",
                },
                canisters,
            ),
        ).toThrow(RequestError);
    });

    it("moves the same APNs token between networks atomically", async () => {
        const relayDependencies = dependencies({
            oldest_available_id: 1n,
            latest_id: 0n,
            events: [],
        });
        const register = async (canisterId: string, installationId: string) =>
            handleRequest(
                new Request("https://push.taggr.test/v1/subscriptions", {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({
                        canisterId,
                        installationId,
                        bindingSecret: "ab".repeat(32),
                        deviceToken: "cd".repeat(48),
                        apnsEnvironment: "production",
                    }),
                }),
                testEnv,
                relayDependencies,
            );

        expect(
            (
                await register(
                    canisters.MAINNET_CANISTER_ID,
                    "01234567-89ab-cdef-0123-456789abcdef",
                )
            ).status,
        ).toBe(201);
        expect(
            (
                await register(
                    canisters.STAGING_CANISTER_ID,
                    "11234567-89ab-cdef-0123-456789abcdef",
                )
            ).status,
        ).toBe(201);
        const rows = await testEnv.DB.prepare(
            "SELECT canister_id, installation_id FROM subscriptions",
        ).all<{ canister_id: string; installation_id: string }>();
        expect(rows.results).toEqual([
            {
                canister_id: canisters.STAGING_CANISTER_ID,
                installation_id: "11234567-89ab-cdef-0123-456789abcdef",
            },
        ]);
    });

    it("retries transient failures without advancing the cursor", async () => {
        await addSubscription();
        await processCanister(
            testEnv,
            canisters.MAINNET_CANISTER_ID,
            { used: 0 },
            dependencies(
                { oldest_available_id: 1n, latest_id: 9n, events: [event] },
                [{ outcome: "transient", reason: "timeout" }],
            ),
        );
        expect(await relayCursor(testEnv, canisters.MAINNET_CANISTER_ID)).toBe(
            0n,
        );
    });

    it("invalidates permanent APNs failures and advances the cursor", async () => {
        await addSubscription();
        const invalidations: PushInvalidation[] = [];
        await processCanister(
            testEnv,
            canisters.MAINNET_CANISTER_ID,
            { used: 0 },
            dependencies(
                { oldest_available_id: 1n, latest_id: 9n, events: [event] },
                [{ outcome: "permanent", reason: "BadDeviceToken" }],
                invalidations,
            ),
        );
        expect(invalidations).toEqual([
            {
                installation_id: event.installation_ids[0],
                token_hash: "11".repeat(32),
            },
        ]);
        expect(
            await testEnv.DB.prepare(
                "SELECT COUNT(*) AS count FROM subscriptions",
            ).first<number>("count"),
        ).toBe(0);
        expect(await relayCursor(testEnv, canisters.MAINNET_CANISTER_ID)).toBe(
            event.id,
        );
    });

    it("recovers a stale cursor and enforces the 30-send budget", async () => {
        await addSubscription();
        const events = Array.from({ length: 31 }, (_, index) => ({
            ...event,
            id: BigInt(index + 10),
        }));
        const budget = { used: 0 };
        await processCanister(
            testEnv,
            canisters.MAINNET_CANISTER_ID,
            budget,
            dependencies({
                oldest_available_id: 10n,
                latest_id: 40n,
                events,
            }),
        );
        expect(budget.used).toBe(30);
        expect(await relayCursor(testEnv, canisters.MAINNET_CANISTER_ID)).toBe(
            39n,
        );
    });
});
