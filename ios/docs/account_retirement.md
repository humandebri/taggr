# iOS account retirement using existing suspension APIs

The Account screen offers Delete account with an explicit explanation that this uses account suspension, not erasure of all stored data. The server-configured account_activation_cost is shown and checked against freshly fetched credits before changes.

The client clears `about` using `update_user`, keeping the existing name, controllers, governance, mode, filters and Realm display preference. It removes only `links` and `pgp` through `update_user_settings`. It then generates 32 random bytes using SecRandomCopyBytes, encodes them as hex, and passes the string to the existing `crypt` update. The key is never deliberately persisted or logged; Swift/SDK memory copies are not claimed to be securely erased.

Only a non-secret stage is stored locally, scoped by backend URL, canister and authenticated principal. `preparing` can repeat the idempotent profile cleanup. `uncertain` is persisted before the stop request and prohibits resending the toggle, including after relaunch. A decoded backend Err or certified rejection permits retry. Network errors, timeouts and malformed responses do not. A later active-user query is not evidence that the original request failed: in that case the client stays pending and only offers status checks. The current SDK does not expose a resumable request handle, so an unresolved request can remain pending indefinitely.

A successful stop response is stored as `confirmed`; it still requires an account-state check. Once stopped state is observed, `cleanup` is persisted before removing device credentials and profile/post caches. If credential removal fails, the stage survives relaunch and the button retries only local cleanup without a network request or another `crypt` call. The screen derives its stage-specific explanation from persisted state, so the explanation remains available after relaunch. Stopped identities and locally pending retirements enter an asset recovery screen on login; iOS does not expose reactivation or SNS updates. Existing ICP send/reward withdrawal operations remain available. Existing local drafts are not submitted and are not part of the server cleanup.

Names and previous names, DAO proposals, images and known image URLs, financial records, and other backend data remain. Existing post encryption is reused without claiming cryptographic erasure. Web and backend APIs are unchanged; this is an iOS restriction, not a service-wide prohibition on reactivation. Apple acceptance is unconfirmed.

No production updates, TestFlight upload or review submission are part of this change. Physical-device verification and recording must use a dedicated test account with sufficient credits.

## Validation (2026-09-14)

-   `cargo check`, `make format` and `git diff --check`: passed.
-   Simulator build and 13 targeted XCTest cases: passed. Ten retirement cases cover cleanup order/preserved fields, credits, changed cost, pending requests across restart, definite rejection, partial cleanup failure, double taps/account changes, already stopped accounts, random key generation and the stopped screen. Three existing login/profile contract tests also passed.
-   Target: iPhone 17, iOS 26.5, UDID `A4C71745-1496-4F8A-AB5E-169AECC12430`, `CODE_SIGNING_ALLOWED=NO`. The native stopped screen was rendered with mock API responses and visually inspected; the screenshot is attached to the XCTest result. No Web UI changed.
-   Physical-device flow, real credit spending and the review recording were not performed: target discovery returned only the simulator. No production account was changed. The complete iOS test suite was not run in this pass.

## Finishing pass (2026-09-14)

-   Added distinct preparation, unknown stop result, received stop response, and device cleanup status text and actions. Asset recovery and sign-out remain available while awaiting confirmation.
-   Simulator: 16 targeted XCTest cases passed (13 retirement cases plus three existing authentication/profile cases), including credential deletion failure followed by local-only recovery after restart and unavailable state after a successful stop response. The final root-alert deduplication also passed a focused native screen smoke test. Rendered all four progress states with native SwiftUI and inspected the unknown-result and cleanup screens. Native UI was checked with XCTest rendering, not Playwright, which cannot operate these SwiftUI views.
-   Existing Rust `test_post_archiving` and `test_post_crypt` passed. These separate unit tests do not establish end-to-end suspension of archived posts.
-   An isolated local network was created under `/private/tmp/taggr-retirement-local`, gateway port 8001, using the existing backend compiled with `FEATURES=dev`. Production, SDK, Web and media canister source were not changed. Local-only ICP paid account/post setup costs, including the existing excessive-posting penalty.
-   The local stress script and raw measurements are `/private/tmp/taggr-retirement-local/verify.py` and `results.json`. Times include CLI/network round trips and are not instruction counts or production performance guarantees.

### Remaining coverage limits

- Device discovery again found only the iPhone 17 simulator (iOS 26.5). No physical-device deletion, real-device asset recovery, or App Review recording was performed.
- Archived-post suspension on a running canister remains unverified. The existing backend archives only above 10,000 heap posts; the 1,000-post workload does not reach that threshold. The two existing Rust tests cover archiving and encryption separately, not their combined account-stop flow. No test-only backend API or changed archive threshold was introduced.
- No SDK request handle is persisted, so an unknown stop result can still remain pending indefinitely. No TestFlight upload or App Store submission was made.

### Local account-stop results

| Own posts | Encrypted posts checked | Stop result | Stop cost | CLI round-trip |
| --- | --- | --- | --- | --- |
| 0 | 0 | `Ok(0)`, stopped | 1,000 credits | 0.177 s |
| 1 | 1, including edit history | Stopped | 1,000 credits (accounting log) | Not retained |
| 100 | 100, including edit history | `Ok(100)`, stopped | 1,000 credits | 0.360 s |
| 1,000 | 1,000, including edit history | `Ok(1000)`, stopped | 1,000 credits | 0.297 s |

The workload mixed short bodies and approximately 2 KiB bodies; the first post was edited before stopping. Every returned post was checked for its encrypted flag and absence of the original body/history marker. TAGGR balances were unchanged in the measured 0/100/1,000 cases (the test accounts held zero TAGGR). This does not validate a nonzero-asset withdrawal. The one-post stop succeeded before the harness was adjusted for the API's `[post, metadata]` response shape; its state, encrypted body/history and 1,000-credit accounting entry were then verified read-only, without resending `crypt`.

No execution-limit failure occurred in these workloads. Their success does not establish an upper bound for larger bodies or archived-post accounts. Test setup encountered the existing excessive-posting fee and was funded with additional local-only ICP; this is separate from the fixed account-stop charge. The isolated local network was stopped after verification; its temporary state and measurements remain under the directory above.
