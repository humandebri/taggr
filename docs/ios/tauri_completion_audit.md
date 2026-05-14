# TAGGR iOS Tauri Completion Audit

## Objective

Implement the requirements in `docs/ios/tauri_requirements.md` as a Tauri v2
iOS app that opens the existing TAGGR production URL, supports deep links and
universal links, uses the iOS share sheet, separates external links to Safari,
shows error/reload UI, includes build configuration, and covers App Store review
requirements.

## Completion Status

Not complete on this machine. The code and static configuration are implemented,
but acceptance still requires full Xcode, simulator, and physical-device
verification.

## Document Verification

-   Rechecked primary docs on 2026-05-13:
    -   Tauri iOS prerequisites still require macOS, full Xcode, Rust iOS
        targets, and CocoaPods.
    -   Tauri remote capabilities still require explicit remote URL scoping for
        web content to call native commands.
    -   Apple universal links still require an associated domain and AASA file
        served by the website.
    -   App Store UGC guidance still requires reporting, blocking, and a contact
        path for user-generated content apps.

## Static Evidence

| Requirement                   | Evidence                                                                                                                                                                                                                                                                                                                                                                                          | Status                  |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| Tauri v2 iOS base             | `src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json`, `src-tauri/gen/apple/project.yml`; launch storyboard includes native `TAGGR` loading UI with activity indicator; Tauri source is split into files under 300 lines                                                                                                                                                                            | Implemented             |
| Production URL on launch      | `src-tauri/src/config.rs` `APP_URL`; `tauri.conf.json` `devUrl` and `frontendDist`                                                                                                                                                                                                                                                                                                                | Implemented             |
| Remote capability boundary    | `src-tauri/capabilities/default.json` uses the generated capabilities schema, grants the TAGGR canonical remote origin only `allow-share-url`, and intentionally omits `core:default`                                                                                                                                                                                                             | Implemented             |
| WKWebView session persistence | Uses default Tauri/WKWebView data store; no custom ephemeral store configured                                                                                                                                                                                                                                                                                                                     | Implemented             |
| Loading UI                    | `INIT_SCRIPT` creates `taggr-ios-loading`; `on_page_load` hides it                                                                                                                                                                                                                                                                                                                                | Implemented             |
| Error UI and reload           | WebView starts from controlled `about:blank`; `INIT_SCRIPT` creates `taggr-ios-error`; bootstrap JS navigates to production URL; first-load timeout shows reload UI if the page never commits or finishes loading; Tauri `on_web_content_process_terminate` navigates to `about:blank#taggr-ios-error`, which renders the same reloadable error overlay                                           | Implemented             |
| Internal route retention      | `stays_in_app` allows TAGGR and required IC/Identity domains; generated `WKAppBoundDomains` includes the same hosts                                                                                                                                                                                                                                                                               | Implemented             |
| External link separation      | `should_open_externally` identifies unknown `http`/`https` URLs; `handle_navigation` opens them through `tauri_plugin_opener`; injected JS runs only on TAGGR/bootstrap documents and normalizes non-Identity `target=_blank` and `window.open` to normal navigation while preserving Identity popup/link behavior                                                                                | Implemented             |
| Back navigation               | iOS `WKWebView` back/forward gestures enabled in `enable_ios_back_forward_gestures`                                                                                                                                                                                                                                                                                                               | Implemented             |
| Deep links                    | Tauri deep-link plugin config and `map_deep_link`; supported public non-hash paths are normalized to TAGGR hash routes; cold-start mixed URL events keep unsupported external links for Safari                                                                                                                                                                                                    | Implemented             |
| Universal links               | Associated domains entitlement and local AASA file; production AASA check currently returns HTML until deployment                                                                                                                                                                                                                                                                                 | Partially implemented   |
| iOS plist and entitlements    | `Info.ios.plist` and generated `Info.plist` include `taggr` URL scheme and the required `WKAppBoundDomains`; generated entitlements include `applinks:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`                                                                                                                                                                                                        | Implemented             |
| iOS share sheet               | `ShareButton` builds canonical TAGGR URLs in the iOS app, converts supported public routes to AASA path URLs, uses page-matching route names, and invokes narrow Tauri command `share_url`; `share_url` accepts only canonical TAGGR HTTPS URLs without credentials/query; iOS presents `UIActivityViewController` with a popover source view; web fallback uses `navigator.share` then clipboard | Implemented             |
| Push notifications            | Requirements mark Phase 2 only; no push code added                                                                                                                                                                                                                                                                                                                                                | Implemented by omission |
| Rust iOS targets              | `npm run ios:preflight` checks `aarch64-apple-ios`, `x86_64-apple-ios`, and `aarch64-apple-ios-sim`                                                                                                                                                                                                                                                                                               | Implemented             |
| Node/npm/Tauri/CocoaPods      | `npm run ios:preflight` checks macOS, Node.js, npm, Tauri CLI, CocoaPods, rustup, and full-Xcode `xcode-select` selection before iOS build gates                                                                                                                                                                                                                                                  | Implemented             |
| XcodeGen project              | Installed by `tauri ios init`; generated Xcode project exists                                                                                                                                                                                                                                                                                                                                     | Implemented             |
| iOS plist/storyboard validity | `npm run ios:preflight` and `npm run ios:completion` lint `Info.ios.plist`, generated `Info.plist`, and generated entitlements with `plutil`; `npm run ios:preflight` validates `LaunchScreen.storyboard` XML with `xmllint`                                                                                                                                                                      | Implemented             |
| App Review UGC                | report/block already present; support/privacy links added                                                                                                                                                                                                                                                                                                                                         | Implemented             |
| Privacy policy                | `src/frontend/src/privacy.tsx`, route `#/privacy`; `docs/ios/app_privacy_answers.md`; covers canister data, iOS WebView data, Internet Identity, third-party links, token/wallet surfaces, moderation, support, and draft App Store Connect answers                                                                                                                                               | Implemented             |
| Token/crypto policy           | iOS read-only notices; hidden transfer/mint/bid/exchange controls; settings force Credits mode and ICRC wallet off; wallet and welcome credit messages do not prompt ICP transfer in iOS; weekly minting delay action is hidden in iOS; proposal creation hides and rejects ICP/token transfer types                                                                                              | Implemented             |
| AASA production asset         | `src/frontend/assets/.well-known/apple-app-site-association`; `src/backend/assets.rs` serves both AASA paths; `src/backend/http.rs` verifies HTTP query requests return AASA JSON without upgrade; local and production AASA checks enforce valid JSON, no redirect, 128 KB max size, signed app id, and supported public TAGGR routes                                                            | Implemented locally     |
| Device evidence template      | `docs/ios/device_verification.md`; `npm run ios:completion` fails until all required runtime checks are recorded as `PASS` and no verification `TODO` remains                                                                                                                                                                                                                                     | Implemented             |
| Submission runbook            | `docs/ios/submission_runbook.md` lists Xcode, App Review, `make build`, dfx version setup, `npm run ios:deploy:ready`, production `dfx --identity "$IOS_DFX_IDENTITY" deploy --network ic taggr`, AASA, device verification, and completion gates                                                                                                                                                 | Implemented             |

## Acceptance Audit

| Acceptance criterion                                      | Evidence                                                                                                                                                                                                                                                                                                                                                                               | Status              |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| Tauri iOS app launches on simulator                       | `npm run ios:build` cannot reach simulator because `simctl` is missing                                                                                                                                                                                                                                                                                                                 | Blocked by Xcode    |
| Tauri iOS app launches on physical device                 | `iphoneos` SDK is missing                                                                                                                                                                                                                                                                                                                                                              | Blocked by Xcode    |
| Production canonical URL loads                            | `src-tauri/src/lib.rs` `APP_URL`; static audit checks `tauri.conf.json`                                                                                                                                                                                                                                                                                                                | Statically verified |
| Internet Identity returns the same TAGGR account identity | Requires live iOS runtime sign-in against the production URL; specifically verifies that WKWebView supports the `window.open` / `window.opener.postMessage` handshake used by `@dfinity/auth-client`                                                                                                                                                                                   | Blocked by Xcode    |
| Internal TAGGR navigation stays in-app                    | `stays_in_app` unit tests cover canonical TAGGR, IC, raw IC, and Internet Identity hosts                                                                                                                                                                                                                                                                                               | Verified by tests   |
| External links open outside the main WebView              | `stays_in_app` and `should_open_externally` tests reject unknown hosts and non-HTTPS canonical URL; `handle_navigation` uses opener                                                                                                                                                                                                                                                    | Verified by tests   |
| Universal/deep links open target TAGGR route              | Deep link mapping tests cover post, user, realm, transactions, transaction, and token routes; unsupported path and hash routes are rejected; production AASA currently returns SPA HTML instead of JSON until deployment                                                                                                                                                               | Partially verified  |
| Share sheet shares current TAGGR URL                      | `share_url` only accepts canonical TAGGR HTTPS URLs without credentials/query; command permission is `allow-share-url`; iOS uses `UIActivityViewController` with popover anchoring                                                                                                                                                                                                     | Statically verified |
| Offline or failed load shows reloadable error UI          | Injected overlay handles offline state; controlled `about:blank` bootstrap keeps a reloadable document alive before the first production commit; first-load timeout covers DNS/TCP/TLS/WebKit hangs that never finish loading; Tauri content-process termination hook navigates to a controlled local error URL; real iOS network/TLS failure behavior still needs device verification | Partially verified  |
| iPhone SE report/block/contact reachability               | Support/privacy links exist; viewport reachability requires simulator/browser verification against deployed code                                                                                                                                                                                                                                                                       | Partially verified  |
| App Review package material exists                        | `docs/ios/app_store_review.md`; `docs/ios/submission_runbook.md`; privacy route; support/contact route; `npm run ios:review` detects the remaining invite-code placeholder in the App Review data doc                                                                                                                                                                                  | Partial, needs data |
| Token/crypto policy selected and implemented              | MVP option 2 selected; iOS hides transfer, minting, bidding, exchange, wallet mutation controls, weekly minting delay action, crypto settings, and ICP/token transfer proposal creation; wallet and welcome text avoid ICP transfer instructions in iOS; validation rejects bypassed iOS transfer proposals                                                                            | Statically verified |

## Verified Commands

-   `cargo check --manifest-path src-tauri/Cargo.toml`
-   `cargo check -p taggr`
-   `./node_modules/.bin/tsc --noEmit`
-   `NODE_ENV=production npm run build`
-   `npm run ios:lines`
-   `npm run ios:dfx`
-   `npm run ios:identity`
-   `npm run ios:deploy:ready`
-   `make build`
-   `npm run ios:aasa:local`
-   `git diff --check`
-   `npm run tauri -- info`
-   `npm run ios:audit`
-   `cargo test --manifest-path src-tauri/Cargo.toml`
-   `cargo check --manifest-path src-tauri/Cargo.toml`
-   `xcode-select -p`
-   `xcodebuild -version`
-   `xcrun simctl list runtimes --json`
-   `xcrun --show-sdk-path --sdk iphoneos`
-   `cargo check --manifest-path src-tauri/Cargo.toml --target aarch64-apple-ios --lib`
-   `npm run ios:preflight`
-   `npm run ios:review`
-   `npm run ios:aasa`
-   `cargo test -p taggr assets::tests::serves_aasa_from_well_known_and_root_paths`
-   `cargo test -p taggr http::test::should_serve_aasa_without_upgrade`
-   `cargo test -p taggr -- --test-threads=1`
-   `plutil -lint src-tauri/Info.ios.plist src-tauri/gen/apple/taggr-ios_iOS/Info.plist src-tauri/gen/apple/taggr-ios_iOS/taggr-ios_iOS.entitlements`
-   `xmllint --noout src-tauri/gen/apple/LaunchScreen.storyboard`
-   `npm run ios:completion`
-   `npm run ios:frontend:local`
-   `cargo fmt --check --manifest-path src-tauri/Cargo.toml`
-   `cargo fmt --check`
-   `npx prettier --check docs/ios/tauri_requirements.md docs/ios/app_store_review.md docs/ios/submission_runbook.md docs/ios/tauri_completion_audit.md docs/ios/device_verification.md docs/ios/app_privacy_answers.md scripts/ios/aasa-check.js scripts/ios/completion-audit.js scripts/ios/local-aasa-check.js scripts/ios/local-frontend-check.js scripts/ios/review-preflight.js scripts/ios/tauri-audit.js scripts/ios/tauri-preflight.js src/frontend/src/privacy.tsx`

## Current Blockers

-   Rechecked on 2026-05-13: Xcode, App Review invite code, production dfx
    identity, and production AASA blockers remain.
-   Latest `npm run ios:completion` recheck: all static, Rust, TypeScript,
    production frontend build, hand-authored iOS file line count, dfx version,
    production canister wasm build, local AASA, plist, and whitespace gates pass.
    Deploy readiness, signed iOS build preflight, App Review invite code
    in `docs/ios/app_store_review.md`, production dfx identity, production AASA,
    and real device-verification gates fail.
-   `dfx --version` now reports `dfx 0.32.0`. The submission runbook still keeps
    the `dfxvm install 0.32.0` fallback for other machines.
-   `npm run ios:identity` uses `IOS_DFX_IDENTITY` when set and defaults to
    `prod`. `dfx identity --identity prod get-principal` currently fails
    because the `prod` identity is missing on this machine. Import the intended
    production identity, rename it to `prod`, or set `IOS_DFX_IDENTITY` before
    deployment.
-   `IOS_DFX_IDENTITY=production npm run ios:identity` also fails on this
    machine because dfx cannot load the encrypted PEM from keyring. Restore the
    keychain entry or import an accessible production identity before deployment.
-   `scripts/ios/prod-identity-check.js` has a 15 second timeout so non-
    interactive App Review/deploy audits fail instead of hanging on a keyring
    prompt.
-   `npm run ios:blockers` is a lightweight external-gate recheck for full
    Xcode, simulator runtime, `iphoneos` SDK, production identity, production
    canister controller access, production AASA, App Review access data, and
    device evidence.
-   `npm run ios:deploy:ready` currently fails for the same missing default
    production identity and cannot verify production canister controller access.
    It passes dfx, local iOS frontend bundle, local AASA, and artifact checks.
-   Full Xcode is not installed. `npm run tauri -- info` reports `Xcode: not
installed`.
-   `/Applications/Xcode.app` is absent and `xcode-select -p` points to
    `/Library/Developer/CommandLineTools`.
-   `npm run ios:build` fails before compilation because `simctl` and the
    `iphoneos` SDK are unavailable.
-   `cargo check --target aarch64-apple-ios --lib` fails in
    `objc2-exception-helper` before TAGGR iOS code compilation because
    `xcrun --show-sdk-path --sdk iphoneos` fails.
-   `npm run ios:preflight` intentionally fails until full Xcode, simulator
    runtime, and `iphoneos` SDK are available. Node.js, npm, Tauri CLI,
    CocoaPods, rustup, and all required Rust iOS targets pass locally. Run
    `npm run ios:preflight -- --build` after Xcode install to include
    `tauri ios build`.
-   Latest `npm run ios:preflight -- --build` recheck still passes macOS,
    Node.js, npm, Tauri CLI, CocoaPods, rustup, plist lint, Rust iOS targets,
    static audit, and Tauri host Rust tests; it fails only at full Xcode,
    simulator runtime, and `iphoneos` SDK availability.
-   `npm run ios:completion` intentionally fails until
    `ios:preflight -- --build`, `ios:review`, `ios:aasa`, and all required
    device-verification entries in `docs/ios/device_verification.md` pass with
    filled evidence fields.
-   App Review submission still needs a real production invite code with enough
    credits for reviewer account creation and report/block testing.
-   App Store Connect privacy answers must be reviewed against
    `docs/ios/app_privacy_answers.md` and the live backend retention policy
    before publishing.
-   `npm run ios:review` intentionally fails until the App Review invite code
    placeholder is filled in `docs/ios/app_store_review.md`.
-   Local frontend/backend changes must be deployed to the production canister
    before the production-URL shell can expose the iOS privacy/support/token
    behavior to reviewers.
-   `npm run ios:aasa` must pass after deployment to prove the production
    canonical domain serves the AASA file over HTTPS with no redirect and with
    `AKN976G7AK.network.taggr.ios`.
-   Current `npm run ios:aasa` result: both
    `/.well-known/apple-app-site-association` and `/apple-app-site-association`
    return HTTP 200 without redirect and are under 128 KB, but `content-type`
    is `text/html; charset=UTF-8` and the body is SPA HTML, not AASA JSON.
    Deploy `src/frontend/assets/.well-known/apple-app-site-association` and
    `src/backend/assets.rs` before App Store review.
-   The controlled `about:blank` bootstrap keeps a reloadable document alive
    before the first production page commit, the first-load timeout covers
    DNS/TCP/TLS/WebKit hangs that never finish loading, and Tauri's
    content-process termination hook navigates to a controlled local error URL.
    Exact iOS network/TLS failure behavior still needs runtime validation after
    full Xcode is available.
-   Internet Identity is not proven on iOS until a real WKWebView run confirms
    that the `@dfinity/auth-client` popup can open and return through
    `postMessage`. Static checks only prove that TAGGR does not rewrite Identity
    `window.open` calls.
-   Backend full tests pass with `--test-threads=1`. The existing `env::*`
    tests abort under default parallel execution because shared process-global
    state is not isolated across those tests.

## Required Device Verification

Run after full Xcode is installed and selected:

1. `npm run ios:build`
2. Launch on simulator.
3. Launch on physical device.
4. Sign in with Internet Identity and confirm the same TAGGR account identity as
   the web app.
5. Open `taggr://post/<id>` and a universal link to a public TAGGR route.
6. Tap a TAGGR route and confirm it stays in-app.
7. Tap an unknown external URL and confirm it opens outside the main WebView.
8. Tap a share button and confirm iOS share sheet opens with the current route.
9. Disable network and confirm reloadable error UI appears.
10. Confirm profile report/block/support/privacy routes are reachable on an
    iPhone SE-size simulator.
