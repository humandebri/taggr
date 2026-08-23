import type {
    ApnsEnvironment,
    PushRelayEnv,
    SubscriptionRequest,
} from "./types";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const hex64 = /^[0-9a-f]{64}$/i;
const evenHex = /^(?:[0-9a-f]{2})+$/i;
const maxRequestBytes = 4096;
const maxDeviceTokenBytes = 256;

export class RequestError extends Error {
    constructor(
        readonly status: number,
        message: string,
    ) {
        super(message);
    }
}

function stringField(object: Record<string, unknown>, key: string): string {
    const value = object[key];
    if (typeof value !== "string")
        throw new RequestError(400, `${key} must be a string`);
    return value;
}

export function validateSubscriptionRequest(
    value: unknown,
    env: Pick<PushRelayEnv, "MAINNET_CANISTER_ID" | "STAGING_CANISTER_ID">,
): SubscriptionRequest {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new RequestError(400, "request body must be an object");
    }
    const object = value as Record<string, unknown>;
    const canisterId = stringField(object, "canisterId");
    const installationId = stringField(object, "installationId");
    const bindingSecret = stringField(object, "bindingSecret");
    const deviceToken = stringField(object, "deviceToken");
    const apnsEnvironment = stringField(
        object,
        "apnsEnvironment",
    ) as ApnsEnvironment;
    if (!uuid.test(installationId))
        throw new RequestError(400, "installationId must be a UUID");
    if (!hex64.test(bindingSecret))
        throw new RequestError(
            400,
            "bindingSecret must be 64 hexadecimal characters",
        );
    if (
        !evenHex.test(deviceToken) ||
        deviceToken.length > maxDeviceTokenBytes * 2
    )
        throw new RequestError(
            400,
            "deviceToken must be 1 to 256 bytes of hexadecimal data",
        );
    if (
        canisterId !== env.MAINNET_CANISTER_ID &&
        canisterId !== env.STAGING_CANISTER_ID
    ) {
        throw new RequestError(400, "canisterId is not allowed");
    }
    if (apnsEnvironment !== "sandbox" && apnsEnvironment !== "production") {
        throw new RequestError(
            400,
            "apnsEnvironment must be sandbox or production",
        );
    }
    return {
        canisterId,
        installationId,
        bindingSecret,
        deviceToken,
        apnsEnvironment,
    };
}

export function validateDeletionRequest(
    value: unknown,
    env: Pick<PushRelayEnv, "MAINNET_CANISTER_ID" | "STAGING_CANISTER_ID">,
): Pick<
    SubscriptionRequest,
    "canisterId" | "installationId" | "bindingSecret"
> {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new RequestError(400, "request body must be an object");
    }
    const object = value as Record<string, unknown>;
    const canisterId = stringField(object, "canisterId");
    const installationId = stringField(object, "installationId");
    const bindingSecret = stringField(object, "bindingSecret");
    if (
        canisterId !== env.MAINNET_CANISTER_ID &&
        canisterId !== env.STAGING_CANISTER_ID
    ) {
        throw new RequestError(400, "canisterId is not allowed");
    }
    if (!uuid.test(installationId))
        throw new RequestError(400, "installationId must be a UUID");
    if (!hex64.test(bindingSecret))
        throw new RequestError(
            400,
            "bindingSecret must be 64 hexadecimal characters",
        );
    return { canisterId, installationId, bindingSecret };
}

export async function readBoundedJSON(request: Request): Promise<unknown> {
    const contentLength = request.headers.get("content-length");
    if (contentLength !== null) {
        const length = Number(contentLength);
        if (!Number.isSafeInteger(length) || length < 0) {
            throw new RequestError(400, "content-length must be valid");
        }
        if (length > maxRequestBytes) {
            throw new RequestError(413, "request body is too large");
        }
    }
    const reader = request.body?.getReader();
    if (!reader) throw new RequestError(400, "request body must be valid JSON");
    const chunks: Uint8Array[] = [];
    let total = 0;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            total += value.byteLength;
            if (total > maxRequestBytes) {
                await reader.cancel();
                throw new RequestError(413, "request body is too large");
            }
            chunks.push(value);
        }
    } finally {
        reader.releaseLock();
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
    }
    try {
        return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
    } catch {
        throw new RequestError(400, "request body must be valid JSON");
    }
}
