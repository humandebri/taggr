# TAGGR iOS Tauri Requirements

## Status

-   Version: 0.1
-   Date: 2026-05-12
-   Scope: Tauri v2 iOS MVP implemented in `src-tauri`.
-   Local verification: Rust, TypeScript, and production frontend builds compile.
    Full iOS build requires full Xcode; current machine only has Command Line
    Tools.

## Decision

Build the first iOS app as a Tauri v2 shell that opens the existing TAGGR
production frontend URL:

`https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`

This keeps the Internet Identity origin stable and avoids changing the current
web authentication model. Bundling the React frontend into the app is deferred
until Internet Identity `derivationOrigin` and alternative origins are verified
for the app origin.

## Sources

-   Tauri v2 supports iOS and Android targets and can use an existing web stack:
    https://v2.tauri.app/
-   Tauri `frontendDist` may be a remote URL. When a URL is used, app assets are
    not bundled and the URL loads by default:
    https://v2.tauri.app/reference/config/
-   Tauri mobile iOS requires macOS, Xcode, Rust iOS targets, and CocoaPods:
    https://v2.tauri.app/start/prerequisites/
-   Tauri capabilities must restrict native API exposure, including remote URL
    access:
    https://v2.tauri.app/security/capabilities/
-   Rechecked 2026-05-13: Tauri v2 docs still require full Xcode for iOS,
    `aarch64-apple-ios`, `x86_64-apple-ios`, and `aarch64-apple-ios-sim` Rust
    targets, CocoaPods, explicit remote capability access, and support remote
    URL `frontendDist`.
-   iOS/macOS Tauri uses the platform WebKit/WKWebView:
    https://v2.tauri.app/reference/webview-versions/
-   Internet Identity principals depend on frontend origin; alternative origins
    require explicit certified configuration:
    https://docs.internetcomputer.org/building-apps/authentication/alternative-origins
-   App Store apps with user-generated content need moderation controls, and
    WebView-only apps have minimum-functionality review risk:
    https://developer.apple.com/app-store/review/guidelines/
-   Rechecked 2026-05-13: App Review Guidelines still require UGC report/block
    and contact paths, complete review access with live backend services, no
    placeholder metadata, and enough native app value beyond a basic web wrapper.
-   App Review information must include valid review access and complete contact
    details for account-gated features:
    https://developer.apple.com/app-store/review/
-   Universal Links require the AASA file to be served from the associated
    domain without HTTP redirects:
    https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links/

## Goals

-   Provide an official TAGGR iOS client with minimal change to existing web code.
-   Preserve current TAGGR account identity and session behavior.
-   Add enough native iOS value to reduce App Store WebView-wrapper risk.
-   Keep the first implementation small, reviewable, and reversible.

## Non-Goals

-   Do not rewrite TAGGR UI in Swift.
-   Do not bundle the frontend in MVP.
-   Do not add push notifications in MVP.
-   Do not change Internet Identity principal derivation in MVP.
-   Do not add new monetization, token sale, exchange, or wallet behavior for iOS.

## Architecture

-   App shell: Tauri v2.
-   Web renderer: iOS system WKWebView through Tauri.
-   Frontend source: `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`.
-   Native boundary: Tauri commands/plugins only where required by MVP features.
-   Remote API exposure: allow only the TAGGR canonical origin in Tauri
    capabilities. No wildcard remote permissions. The remote origin may invoke
    only the narrow `share_url` command; do not grant `core:default`.
-   External web content: open outside the main WebView in Safari or
    `SFSafariViewController`.

## Functional Requirements

### WebView

-   Load `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io` on launch.
-   Persist session state with WKWebView's normal data store.
-   Show a native loading state until first meaningful page load.
-   Show a native error screen on network, TLS, DNS, or load failure.
-   Provide a reload action on the error screen.
-   Do not show a blank white screen as a terminal state.

### Navigation

-   Internal TAGGR routes stay inside the main WebView.
-   External links open outside the main WebView.
-   Back navigation maps to WebView history before exiting the app view.
-   App must handle direct launch into supported TAGGR paths.

### Deep Link And Universal Link

-   Support links for posts, users, realms, transactions, and token pages if those
    paths are public web routes.
-   Map inbound links to the equivalent TAGGR URL and load it in the WebView.
-   Universal link domains must match the production canonical domain decision.
-   App Store metadata and associated domains must be configured before review.
-   `npm run ios:aasa` must pass after production deployment; Apple requires the
    AASA file to be served over HTTPS without redirects.

### Share Sheet

-   Provide iOS share sheet for the current TAGGR page URL.
-   If web-to-native share is implemented, expose one narrow Tauri command to the
    TAGGR canonical origin only.
-   Fallback acceptable for MVP: native toolbar/menu share action using the current
    WebView URL.

### External Link Separation

-   TAGGR canonical domain and required IC domains remain in the app WebView.
-   Unknown domains open externally.
-   Internet Identity authentication windows must keep existing behavior unless
    testing proves a native intercept is required; the shell must not rewrite
    Identity `window.open` calls while separating ordinary external links.

### Push Notifications

-   Phase 2 only.
-   Phase 2 requires a separate design for permission timing, backend event source,
    device token storage, unsubscribe, and privacy disclosure.

## Build Requirements

-   macOS with full Xcode installed, not only command line tools.
-   Rust targets:
    -   `aarch64-apple-ios`
    -   `x86_64-apple-ios`
    -   `aarch64-apple-ios-sim`
-   CocoaPods installed.
-   Existing Node/npm environment remains the frontend tooling source.
-   Tauri CLI added only when implementation begins.
-   Preflight must check macOS, Node.js, npm, Tauri CLI, CocoaPods, rustup,
    required Rust iOS targets, `xcode-select` full-Xcode selection, simulator
    runtime, `iphoneos` SDK, generated iOS plist/entitlements syntax, and
    launch storyboard XML syntax.
-   Completion audit must also check authored iOS file line counts, the pinned
    dfx version with `npm run ios:dfx`, production identity availability with
    `npm run ios:identity`, production canister controller access in
    `npm run ios:deploy:ready`, and production canister wasm generation with
    `make build`.
-   Production deployment must run `npm run ios:deploy:ready` before
    `dfx --identity "$IOS_DFX_IDENTITY" deploy --network ic taggr`; the default
    identity name for local checks is `prod`.
-   `npm run ios:preflight` must pass before App Store submission. Use
    `npm run ios:preflight -- --build` to include the signed iOS build gate.
-   `npm run ios:completion` must pass before this implementation is considered
    complete. It maps the requirements in this document to concrete artifacts
    and command gates.
-   Device verification evidence must be recorded in
    `docs/ios/device_verification.md` before completion.
-   Submission execution steps are tracked in
    `docs/ios/submission_runbook.md`.

## App Store Review Requirements

### UGC Safety

Evidence currently found in the web app:

-   User/post reporting exists through `FlagButton` and backend `report` call in
    `src/frontend/src/common.tsx`.
-   Report review banner exists through `ReportBanner` in
    `src/frontend/src/common.tsx`.
-   Blocked-user state appears in profile/post UI.

Before submission:

-   Confirm report entry points are reachable on iPhone viewport.
-   Confirm user block controls are reachable on iPhone viewport.
-   Add or confirm a support/contact URL reachable without login.
-   Include moderation notes in App Review notes.

### Privacy

-   Publish a privacy policy URL before App Store submission.
-   App Store privacy answers must describe web app data collection, third-party
    services, Internet Identity, and any token/wallet-related data handling.
-   App Store Connect privacy worksheet is tracked in
    `docs/ios/app_privacy_answers.md`.
-   No analytics or advertising SDK is allowed in MVP unless separately approved.

### Review Access

-   Provide an active demo account, invite code, or fully functional demo path.
-   Backend services must be live during review.
-   `npm run ios:review` must pass before upload; it fails while demo access
    placeholders remain.
-   Review notes must explain:
    -   TAGGR is a social network with UGC moderation.
    -   The app is a Tauri iOS client for the existing service.
    -   Token/crypto surfaces are handled according to the submitted policy.

### Token And Crypto Policy

TAGGR contains token, ICP, wallet, transfer, and transaction routes in the web
frontend. Before submission choose exactly one policy:

1. Hide token/crypto routes in the iOS app until legal and App Review position is
   clear.
2. Keep read-only token/transaction views, but disable transfers, bidding,
   minting, and external exchange links in iOS.
3. Submit with full token/crypto features only after legal review confirms the
   required developer entity, countries, licenses, and App Store rules.

MVP default: option 2 if technically simple; otherwise option 1.

## Acceptance Criteria

-   Tauri iOS app launches on simulator and physical device.
-   App loads the TAGGR production canonical URL.
-   Existing sign-in flow works and returns the same TAGGR account identity as the
    web app.
-   Internal TAGGR navigation stays inside the app.
-   External links open outside the main WebView.
-   Universal/deep links open the target TAGGR route.
-   Share sheet shares the current TAGGR URL.
-   Offline or failed load shows native error UI with reload.
-   iPhone SE-size viewport has no blocked report/block/contact routes.
-   App Review package includes privacy policy, support/contact URL, review access,
    and moderation explanation.
-   Token/crypto submission policy is selected and implemented before App Store
    review.
-   `docs/ios/device_verification.md` records `PASS` for simulator launch,
    physical-device launch, production URL load, Internet Identity continuity,
    internal/external navigation, universal/deep links, share sheet, offline
    reload UI, and iPhone SE moderation reachability.

## Open Decisions

-   Whether public aliases such as `taggr.network` or `taggr.link` should also be
    associated domains.
-   App name and bundle identifier are currently `TAGGR` and `network.taggr.ios`.
-   Apple Developer Team ID is currently `AKN976G7AK`.
-   Exact associated domains list beyond
    `6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`.
-   Apple Developer account entity for App Store Connect metadata.
-   Share uses the narrow `share_url` Tauri command, limited to the canonical
    TAGGR HTTPS origin, and falls back to Web Share/clipboard outside the iOS
    shell.
-   iOS token/crypto policy option is currently MVP option 2: read-only
    token/transaction views with transfers, bidding, minting, and exchange links
    hidden in the iOS app.
-   Exact iOS network/TLS failure behavior still needs full Xcode/iOS runtime
    verification. The current MVP starts from a controlled `about:blank`
    bootstrap document, navigates to the production URL from injected JS, shows a
    reloadable timeout/offline error view if the first production page does not
    finish loading, and navigates to a controlled local error URL when Tauri
    reports WebKit content-process termination.
