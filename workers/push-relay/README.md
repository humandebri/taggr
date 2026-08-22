# TAGGR push relay

The relay polls the production and staging canisters once per minute, then sends
at most 30 APNs requests per invocation. D1 stores device subscriptions, APNs
provider-token cache entries, and one cursor per canister.

## Configuration

1. Create a D1 database and replace the placeholder `database_id` in
   `wrangler.jsonc`.
2. Set the production/staging canister IDs and IC host in `wrangler.jsonc`.
3. Apply `migrations/0001_initial.sql` to the remote D1 database.
4. Configure these Worker secrets separately for the target Cloudflare account:
   `APNS_PRODUCTION_KEY_ID`, `APNS_PRODUCTION_TEAM_ID`,
   `APNS_PRODUCTION_PRIVATE_KEY`, `APNS_SANDBOX_KEY_ID`,
   `APNS_SANDBOX_TEAM_ID`, `APNS_SANDBOX_PRIVATE_KEY`, and
   `RELAY_IDENTITY_JSON` (the JSON serialization accepted by
   `Ed25519KeyIdentity.fromJSON`).
5. Compile the relay's Ed25519 principal into each canister with
   `TAGGR_PUSH_RELAY_PRINCIPAL`, deploy the canisters, deploy the Worker, and set
   the app build setting `TAGGR_PUSH_RELAY_URL` to the Worker origin.

Never put secrets in `.dev.vars.example`, Wrangler vars, source control, or
logs. Verify staging with APNs sandbox and a physical device before enabling the
production Cron.

## Local verification

```sh
npm run push:types
npm run push:check
npm run push:test
npx wrangler deploy --dry-run --config workers/push-relay/wrangler.jsonc
```
