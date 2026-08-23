CREATE TABLE subscriptions (
  canister_id TEXT NOT NULL,
  installation_id TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  binding_secret_hash TEXT NOT NULL,
  device_token TEXT NOT NULL,
  apns_environment TEXT NOT NULL CHECK (apns_environment IN ('sandbox', 'production')),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (canister_id, installation_id),
  UNIQUE (apns_environment, token_hash)
);

CREATE INDEX subscriptions_delivery
  ON subscriptions (canister_id, installation_id);

CREATE TABLE relay_cursors (
  canister_id TEXT PRIMARY KEY,
  last_event_id INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE apns_provider_tokens (
  apns_environment TEXT PRIMARY KEY CHECK (apns_environment IN ('sandbox', 'production')),
  token TEXT NOT NULL,
  issued_at INTEGER NOT NULL
);
