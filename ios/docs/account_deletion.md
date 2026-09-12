# Account deletion

## Behavior

Deleting an account removes its profile and post contents. User/post IDs and reply relationships remain. Lists/search hide deleted authors immediately; direct post/thread responses contain an empty deleted marker. Other users' replies remain. SNS updates are rejected for deleting/deleted identities.

Image storage is closed, not physically erased. The personal bucket returns empty 404 responses with `Cache-Control: no-store` and rejects writes. Existing browser caches, third-party copies and a controller deliberately installing replacement code are outside this guarantee. Legacy image storage is excluded under the owner-provided assumption that referencing and serving it already ended.

Asset identities, balances, existing rewards, ledger and governance records remain. Deletion does not require credits or sufficient balance for a transfer fee. Returning users can recover assets but cannot recreate the deleted SNS account under the same identity.

## JSON APIs

The raw JSON transport follows existing update/query conventions. No argument is required for `begin_account_deletion`, `continue_account_deletion`, or `account_deletion_status`. Responses are `{Ok: progress}` or `{Err: message}`. Progress includes state (`active`, `deleting`, `deleted`), processed/total posts, registered bucket, media closure flag, and the caller's asset-recovery fields. Status is available only for the authenticated caller's account.

`begin_account_deletion` is irreversible and idempotent. `continue_account_deletion` erases bounded batches, verifies the registered bucket through its update `media_closed`, and finalizes only when content and media processing are complete. Retry failures; do not present them as successful deletion.

`recover_taggr` accepts `[recipientPrincipal, amountInBaseUnits]` and uses normal ledger fees. `withdraw_rewards`, ledger transfers and bid cancellation remain available for asset recovery.

## Storage and compatibility

Bucket Candid adds `close_media: () -> ()` and `media_closed: () -> (bool)`. Closure is authenticated. The existing stable-memory data layout is retained; the upgrade trailer is a versioned record, with backward decoding of the old free-list format. Unsupported/corrupt trailers fail rather than reopen storage.

The iOS upgrader recognizes the optimized bucket built from commit `4ee528a1`: `418202879263a81a9479620628be4e0543367c178addb92d5fd5873ba23bde10`. This hash was reproduced from that commit with the repository release/shrink/Oz pipeline. Unknown code is not automatically overwritten. Missing upgrade authority or unsupported closure keeps deletion pending with an error.

`stable_mem_read` now requires a controller of the TAGGR canister. Public raw backup consumers must migrate to an authorized operational workflow; they cannot keep anonymously downloading historical account contents.

## Release

Build the new bucket Wasm before building TAGGR so the distributed bucket payload includes closure. Release the backend/bucket payload first, then clients. No production deployment is performed by the implementation task. Existing personal buckets are upgraded when closure is requested and their hash/authority is recognized.

Before submission, verify a dedicated test account on a physical device, including a known image URL, interrupted/resumed deletion, final confirmation and asset-only re-login. Record the entire flow. App Review notes must distinguish removal of profile/post contents from closure of image serving; approval of this approach has not been confirmed.

## Validation and remaining checks

Local Rust workspace tests, `cargo check`, `make format`, TypeScript checking, the frontend build and simulator iOS build passed. The deletion tests cover free/resumable batches, archived posts, retained replies/assets/rewards, legacy user decoding and rejection of SNS updates/re-registration. Bucket tests cover empty 404/no-store responses, legacy trailer migration, restoration of closed state and rejection of invalid serialized state. These storage tests exercise serialization/restoration; they do not replace a deployed canister upgrade test.

Six targeted iOS tests passed on the dedicated iPhone 17 simulator, covering progress decoding, exact token amounts, deleted-account reload, deleted-account seed-phrase login, unknown-user rejection and ordinary seed-phrase login. Playwright exercised the actual Web recovery component with mocked API responses: pending progress, visible failure, retry and completion. No asset transfer was sent by browser testing.

The full iOS suite is not green in this environment (`CODE_SIGNING_ALLOWED=NO`); all 15 test names in the final failure summary (including asynchronous assertions) also appeared in the full suite on a pristine copy of starting commit `4ee528a1`, with no difference in the failure set. Comparison logs are `/private/var/folders/c0/wmdw9g8d70xdy1xmlw3qmdfm0000gn/T/qrun/run.IkL3ak` (modified) and `run.FvPYJv` (baseline). Do not treat the targeted passes as a full-suite pass.

Still required before production approval: physical-device account deletion and recording, real backend-to-bucket closure verification, unauthorized closure attempts, network interruption/retry and actual canister upgrades with known image URLs. The unit tests and mocked browser checks do not establish these end-to-end guarantees. No physical device was connected and no production state was changed.

## Web resumption and principal migration

Continue deletion on the canonical domain using the original account identity. Custom domains link to canonical sign-in. The Web client closes registered image storage before continuing post batches, upgrading only the same known legacy hash recognized by iOS. Unknown code is never overwritten; closure is attempted through its existing API. Missing management authority or failed closure leaves deletion pending and displays an error for retry. Reopening the page resumes from backend progress; sign-out or navigation stops further requests, but does not cancel an already submitted update.

Deletion clears pending principal migrations, including on repeated begin requests. Migration confirmation also rejects deleting/deleted source accounts before changing identity mappings or balances. This prevents stale reservations from releasing the original principal for registration.

The isolated Web regression suite runs with `node e2e/account-deletion.cjs`; it bundles the recovery component with mocked APIs and never calls a canister. Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE` to an installed Playwright Chromium executable when the repository version's default browser is unavailable. Use `--serve` to inspect the same fixture with Playwright CLI.
