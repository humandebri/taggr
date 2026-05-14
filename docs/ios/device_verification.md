# TAGGR iOS Device Verification

## Purpose

Capture real simulator and physical-device evidence for the acceptance criteria
in `docs/ios/tauri_requirements.md`.

`npm run ios:completion` intentionally fails until each status below is changed
from `TODO` to `PASS` after verification on an actual iOS runtime.

## Environment

-   Xcode version: TODO
-   Simulator device and iOS version: TODO
-   Physical device and iOS version: TODO
-   Build command: `npm run ios:preflight -- --build`
-   App version/build: TODO
-   Git revision or diff ID: TODO
-   Production canister deployment: TODO
-   Tester: TODO
-   Date: TODO

## Results

-   Simulator launch: TODO
-   Physical device launch: TODO
-   Production URL load: TODO
-   Internet Identity continuity: TODO
-   Internal navigation: TODO
-   External navigation: TODO
-   Universal link: TODO
-   Deep link: TODO
-   Share sheet: TODO
-   Offline reload UI: TODO
-   iPhone SE moderation reachability: TODO

## Required Test Cases

Record the exact route, device, and observed result for each case before
changing the corresponding `Results` entry to `PASS`.

### Simulator Launch

-   Device: TODO
-   Command: `npm run ios:open`
-   Expected: TAGGR launches without native crash.
-   Evidence: TODO

### Physical Device Launch

-   Device: TODO
-   Command: Xcode run or `npm run ios:build` archive/install path.
-   Expected: TAGGR launches without native crash.
-   Evidence: TODO

### Production URL Load

-   Route: `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`
-   Expected: app displays production TAGGR frontend, not a blank terminal page.
-   Evidence: TODO

### Internet Identity Continuity

-   Web account identifier: TODO
-   iOS account identifier: TODO
-   Expected: same TAGGR account identity after Internet Identity sign-in.
-   Communication path: Internet Identity must open from WKWebView and complete
    the `window.open` / `window.opener.postMessage` / `message` listener
    handshake used by `@dfinity/auth-client`.
-   Evidence: TODO

### Internal Navigation

-   Route tested: TODO
-   Expected: TAGGR route stays inside the main WebView.
-   Evidence: TODO

### External Navigation

-   URL tested: TODO
-   Expected: unknown external URL opens outside the main WebView.
-   Evidence: TODO

### Universal Link

-   URL tested: TODO
-   Expected: iOS opens TAGGR app and lands on the matching TAGGR route.
-   Evidence: TODO

### Deep Link

-   URL tested: `taggr://post/<id>`
-   Expected: TAGGR app opens and lands on `#/post/<id>`.
-   Evidence: TODO

### Share Sheet

-   Route tested: TODO
-   Expected: native iOS share sheet opens with the current canonical TAGGR URL.
-   Evidence: TODO

### Offline Reload UI

-   Failure type: TODO
-   Expected: reloadable error UI appears; reload succeeds after connectivity
    returns.
-   Evidence: TODO

### iPhone SE Moderation Reachability

-   Viewport/device: iPhone SE-size simulator
-   Expected: report, block, support, and privacy routes are reachable without
    layout blockage.
-   Evidence: TODO

## Local Browser Precheck

This section is not a replacement for simulator or physical-device PASS
evidence. It records early responsive checks before full Xcode is available.

-   iPhone SE links/privacy precheck: PASS
-   Viewport: 375 x 667
-   Browser session: `playwright-cli -s=taggr-ios`
-   URL: `http://127.0.0.1:4173/#/links` and
    `http://127.0.0.1:4173/#/privacy`
-   iOS condition: `window.__TAGGR_IOS_APP__ = true` init script
-   Evidence:
    -   Links page hides price listings, exchange links, and trading links in
        iOS mode.
    -   Links page exposes Privacy policy, HELP Realm, and OpenChat Community.
    -   Links page share URL uses
        `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/links`.
    -   Privacy page opens from Links and exposes moderation/support, Internet
        Identity, iOS WebView data, and token/wallet disclosure text.
    -   Privacy page share URL uses
        `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy`.

## Required Notes

-   Internet Identity continuity must compare the iOS app account with the
    existing web account for the same user and must record whether the Identity
    window returned through the `postMessage` handshake.
-   External navigation must use a non-TAGGR domain and confirm it leaves the
    main app WebView.
-   Share sheet must confirm the shared URL is the current canonical TAGGR URL.
-   Offline reload UI must test a network failure and a successful reload after
    connectivity is restored.
-   iPhone SE moderation reachability must confirm report, block, support, and
    privacy routes are reachable without layout blockage.
