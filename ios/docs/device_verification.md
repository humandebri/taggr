# TAGGR iOS Device Verification

## Purpose

Capture real simulator and physical-device evidence for the acceptance criteria
in `ios/docs/swift_requirements.md`.

`npm run ios:completion` intentionally fails until each status below is changed
from `PENDING_FINAL_VERIFICATION` to `PASS` after verification on an actual iOS
runtime. For the prep-only pass, keep production-dependent items pending until
the production follow-up deploy is complete.

## Environment

-   Xcode version: PENDING_FINAL_VERIFICATION
-   Simulator device and iOS version: PENDING_FINAL_VERIFICATION
-   Physical device and iOS version: PENDING_FINAL_VERIFICATION
-   Build command: `npm run ios:preflight`
-   App version/build: PENDING_FINAL_VERIFICATION
-   Git revision or diff ID: PENDING_FINAL_VERIFICATION
-   Production canister deployment: PENDING_FOLLOW_UP
-   Tester: PENDING_FINAL_VERIFICATION
-   Date: PENDING_FINAL_VERIFICATION

## Results

-   Simulator launch: PENDING_FINAL_VERIFICATION
-   Physical device launch: PENDING_FINAL_VERIFICATION
-   Production URL load: PENDING_FOLLOW_UP
-   Internet Identity continuity: PENDING_FINAL_VERIFICATION
-   Internal navigation: PENDING_FINAL_VERIFICATION
-   External navigation: PENDING_FINAL_VERIFICATION
-   Universal link: PENDING_FOLLOW_UP
-   Share sheet: PENDING_FINAL_VERIFICATION
-   Offline reload UI: PENDING_FINAL_VERIFICATION
-   iPhone SE moderation reachability: PENDING_FINAL_VERIFICATION

## Required Test Cases

Record the exact route, device, and observed result for each case before
changing the corresponding `Results` entry to `PASS`.

### Simulator Launch

-   Device: PENDING_FINAL_VERIFICATION
-   Command: `npm run ios:open`
-   Expected: TAGGR launches without native crash.
-   Evidence: PENDING_FINAL_VERIFICATION

### Physical Device Launch

-   Device: PENDING_FINAL_VERIFICATION
-   Command: Xcode run or `npm run ios:build` archive/install path.
-   Expected: TAGGR launches without native crash.
-   Evidence: PENDING_FINAL_VERIFICATION

### Production URL Load

-   Route: `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`
-   Expected: app displays production TAGGR frontend, not a blank terminal page.
-   Evidence: PENDING_FOLLOW_UP

### Internet Identity Continuity

-   Web account identifier: PENDING_FINAL_VERIFICATION
-   iOS account identifier: PENDING_FINAL_VERIFICATION
-   Expected: same TAGGR account identity after Internet Identity sign-in.
-   Communication path: Internet Identity must open its ICRC-167 authorization
    URL from `ASWebAuthenticationSession`, then return its JSON-RPC response in
    the fragment of `/ios-auth-callback`.
-   Evidence: PENDING_FINAL_VERIFICATION

### Local Canister Device Auth

-   Command: `node ios/scripts/icp-local-device-ngrok.js`
-   Expected: script deploys local TAGGR, exposes TAGGR and Internet Identity
    through HTTPS `cloudflared` hosts, and Internet Identity returns to the app
    through `https://<TAGGR cloudflared host>/ios-auth-callback`. LAN HTTP
    origins are not valid for device passkey auth.
-   Evidence: PENDING_OPTIONAL_LOCAL_CHECK

### Staging Canister Device Auth

-   AASA check:
    `IOS_AASA_HOST=e4i5g-biaaa-aaaao-ai7ja-cai.icp0.io node ios/scripts/aasa-check.js`
-   Device build:
    `IOS_STAGING_NETWORK=staging node ios/scripts/staging-device-build.js`
-   Expected: app signs in through
    `https://id.ai/authorize`, returns through
    `https://e4i5g-biaaa-aaaao-ai7ja-cai.icp0.io/ios-auth-callback`, and uses
    canister `e4i5g-biaaa-aaaao-ai7ja-cai` for API calls.
-   Evidence: PENDING_OPTIONAL_STAGING_CHECK

### Internal Navigation

-   Route tested: PENDING_FINAL_VERIFICATION
-   Expected: TAGGR route stays inside the native SwiftUI app.
-   Evidence: PENDING_FINAL_VERIFICATION

### External Navigation

-   URL tested: PENDING_FINAL_VERIFICATION
-   Expected: unknown external URL opens outside the native SwiftUI app.
-   Evidence: PENDING_FINAL_VERIFICATION

### Universal Link

-   URL tested: PENDING_FOLLOW_UP
-   Expected: iOS opens TAGGR app and lands on the matching TAGGR route.
-   Evidence: PENDING_FOLLOW_UP

### Share Sheet

-   Route tested: PENDING_FINAL_VERIFICATION
-   Expected: native iOS share sheet opens with the current canonical TAGGR URL.
-   Evidence: PENDING_FINAL_VERIFICATION

### Offline Reload UI

-   Failure type: PENDING_FINAL_VERIFICATION
-   Expected: reloadable error UI appears; reload succeeds after connectivity
    returns.
-   Evidence: PENDING_FINAL_VERIFICATION

### iPhone SE Moderation Reachability

-   Viewport/device: iPhone SE-size simulator
-   Expected: report, block, support, and privacy routes are reachable without
    layout blockage.
-   Evidence: PENDING_FINAL_VERIFICATION

## Local Browser Precheck

This section is not a replacement for simulator or physical-device PASS
evidence. It records early responsive checks before full Xcode is available.

-   iPhone SE links/privacy precheck: PASS
-   Viewport: 375 x 667
-   Browser session: `playwright-cli -s=taggr-ios`
-   URL: `http://127.0.0.1:4173/#/links` and
    `http://127.0.0.1:4173/#/privacy`
-   iOS condition: Swift native App Store policy with crypto execution disabled
-   Evidence:
    -   Links page hides price listings, exchange links, and trading links in
        iOS mode.
    -   Links page exposes Privacy policy, HELP Realm, and OpenChat Community.
    -   Links page share URL uses
        `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/links`.
    -   Privacy page opens from Links and exposes moderation/support, Internet
        Identity, iOS app data, and token/wallet disclosure text.
    -   Privacy page share URL uses
        `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy`.

## Required Notes

-   On a physical device, verify the first-login explanation, permission grant
    and denial paths, sandbox token registration, a locked-screen notification,
    foreground suppression, badge count, and notification-tap navigation to the
    post. Repeat disable and logout flows and confirm the relay subscription is
    removed.

-   Internet Identity continuity must compare the iOS app account with the
    existing web account for the same user and must record whether the Identity
    window returned through the direct ICRC-167 HTTPS callback.
-   External navigation must use a non-TAGGR domain and confirm it leaves the
    native SwiftUI app.
-   Share sheet must confirm the shared URL is the current canonical TAGGR URL.
-   Offline reload UI must test a network failure and a successful reload after
    connectivity is restored.
-   iPhone SE moderation reachability must confirm report, block, support, and
    privacy routes are reachable without layout blockage.
