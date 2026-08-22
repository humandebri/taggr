import { base64Url } from "./crypto";
import type {
    ApnsEnvironment,
    PushEvent,
    PushRelayEnv,
    SubscriptionRow,
} from "./types";

interface ApnsCredentials {
    keyId: string;
    teamId: string;
    privateKey: string;
}

export type ApnsSendResult =
    | { outcome: "success" }
    | { outcome: "permanent"; reason: string }
    | { outcome: "transient"; reason: string };

const providerTokenLifetimeSeconds = 45 * 60;

function credentials(
    env: PushRelayEnv,
    environment: ApnsEnvironment,
): ApnsCredentials {
    if (environment === "sandbox") {
        return {
            keyId: env.APNS_SANDBOX_KEY_ID,
            teamId: env.APNS_SANDBOX_TEAM_ID,
            privateKey: env.APNS_SANDBOX_PRIVATE_KEY,
        };
    }
    return {
        keyId: env.APNS_PRODUCTION_KEY_ID,
        teamId: env.APNS_PRODUCTION_TEAM_ID,
        privateKey: env.APNS_PRODUCTION_PRIVATE_KEY,
    };
}

function pemBytes(pem: string): Uint8Array {
    const base64 = pem
        .replaceAll("\\n", "\n")
        .replace(
            /-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
            "",
        );
    const binary = atob(base64);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function createProviderToken(
    credentials: ApnsCredentials,
    issuedAt: number,
): Promise<string> {
    const key = await crypto.subtle.importKey(
        "pkcs8",
        pemBytes(credentials.privateKey),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
    );
    const header = base64Url(
        JSON.stringify({ alg: "ES256", kid: credentials.keyId }),
    );
    const claims = base64Url(
        JSON.stringify({ iss: credentials.teamId, iat: issuedAt }),
    );
    const signingInput = `${header}.${claims}`;
    const signature = new Uint8Array(
        await crypto.subtle.sign(
            { name: "ECDSA", hash: "SHA-256" },
            key,
            new TextEncoder().encode(signingInput),
        ),
    );
    return `${signingInput}.${base64Url(signature)}`;
}

async function providerToken(
    env: PushRelayEnv,
    environment: ApnsEnvironment,
): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    const cached = await env.DB.prepare(
        "SELECT token, issued_at FROM apns_provider_tokens WHERE apns_environment = ?",
    )
        .bind(environment)
        .first<{ token: string; issued_at: number }>();
    if (cached && cached.issued_at + providerTokenLifetimeSeconds > now)
        return cached.token;

    const token = await createProviderToken(credentials(env, environment), now);
    await env.DB.prepare(
        `INSERT INTO apns_provider_tokens (apns_environment, token, issued_at) VALUES (?, ?, ?)
     ON CONFLICT(apns_environment) DO UPDATE SET token = excluded.token, issued_at = excluded.issued_at`,
    )
        .bind(environment, token, now)
        .run();
    return token;
}

function title(event: PushEvent): string {
    const author = event.author_name ? `@${event.author_name}` : "TAGGR";
    switch (event.kind) {
        case 1:
            return `${author} replied to your post`;
        case 2:
            return `${author} mentioned you`;
        case 4:
            return `${author} reposted your post`;
        case 8:
            return "A watched thread was updated";
        default:
            return "New TAGGR notification";
    }
}

export function apnsPayload(
    event: PushEvent,
    canisterId: string,
): Record<string, unknown> {
    return {
        aps: {
            alert: { title: title(event), body: event.preview },
            sound: "default",
            badge: Number(event.unread_count),
        },
        eventId: event.id.toString(),
        notificationId: event.notification_id.toString(),
        postId: event.post_id.toString(),
        kind: event.kind,
        canisterId,
    };
}

function permanentReason(status: number, reason: string): boolean {
    return (
        status === 410 ||
        reason === "BadDeviceToken" ||
        reason === "DeviceTokenNotForTopic" ||
        reason === "Unregistered"
    );
}

export async function sendPush(
    env: PushRelayEnv,
    canisterId: string,
    event: PushEvent,
    subscription: SubscriptionRow,
): Promise<ApnsSendResult> {
    const token = await providerToken(env, subscription.apns_environment);
    const host =
        subscription.apns_environment === "sandbox"
            ? "https://api.sandbox.push.apple.com"
            : "https://api.push.apple.com";
    let response: Response;
    try {
        response = await fetch(
            `${host}/3/device/${subscription.device_token}`,
            {
                method: "POST",
                headers: {
                    authorization: `bearer ${token}`,
                    "apns-topic": env.APNS_TOPIC,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                    "apns-expiration": String(
                        Math.floor(Date.now() / 1000) + 3600,
                    ),
                    "apns-collapse-id": `taggr:${canisterId}:${event.id.toString()}`,
                    "content-type": "application/json",
                },
                body: JSON.stringify(apnsPayload(event, canisterId)),
                signal: AbortSignal.timeout(10_000),
            },
        );
    } catch (error) {
        return {
            outcome: "transient",
            reason: error instanceof Error ? error.message : "network error",
        };
    }
    if (response.ok) return { outcome: "success" };

    const body: { reason?: string } = await response
        .json<{ reason?: string }>()
        .catch(() => ({}));
    const reason = body.reason ?? `HTTP ${response.status}`;
    if (permanentReason(response.status, reason))
        return { outcome: "permanent", reason };
    return { outcome: "transient", reason };
}
