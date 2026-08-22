export type ApnsEnvironment = "sandbox" | "production";

export interface PushEvent {
    id: bigint;
    installation_ids: string[];
    post_id: bigint;
    author_name: string;
    preview: string;
    kind: number;
    recipient: bigint;
    created_at: bigint;
    unread_count: bigint;
    notification_id: bigint;
    watched_post_id: [] | [bigint];
}

export interface PushBatch {
    latest_id: bigint;
    events: PushEvent[];
    oldest_available_id: bigint;
}

export interface PushInvalidation {
    installation_id: string;
    token_hash: string;
}

export type CanisterResult<T> = { Ok: T } | { Err: string };

export interface PushInstallationResolution {
    user_id: bigint;
    enabled_kinds: number;
}

export interface SubscriptionRow {
    canister_id: string;
    installation_id: string;
    token_hash: string;
    binding_secret_hash: string;
    device_token: string;
    apns_environment: ApnsEnvironment;
    updated_at: number;
}

export interface RelaySecrets {
    RELAY_IDENTITY_JSON: string;
    APNS_SANDBOX_KEY_ID: string;
    APNS_SANDBOX_TEAM_ID: string;
    APNS_SANDBOX_PRIVATE_KEY: string;
    APNS_PRODUCTION_KEY_ID: string;
    APNS_PRODUCTION_TEAM_ID: string;
    APNS_PRODUCTION_PRIVATE_KEY: string;
}

export type PushRelayEnv = Env & RelaySecrets;

export interface SubscriptionRequest {
    canisterId: string;
    installationId: string;
    bindingSecret: string;
    deviceToken: string;
    apnsEnvironment: ApnsEnvironment;
}
