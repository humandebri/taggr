# TAGGR iOS Swift Requirements

## Decision

TAGGR iOS is a SwiftUI native app. It keeps the existing IC canister backend and
does not embed the React frontend for the main UI. Internet Identity opens its
ICRC-167 authorization URL directly in `ASWebAuthenticationSession`.

## Native Scope

-   Feed, post, profile, realm, settings, in-app notifications, reporting,
    blocking, sharing, and Universal Links are native SwiftUI flows.
-   Internet Identity uses the system authentication session. Production and
    local device builds return through the TAGGR Universal Link callback.
-   Account supports TAGGR balances, ICP balances, ICP transfers, reward
    withdrawals, and ICP credit minting. Auction bidding and external
    exchange/trading links remain hidden.
-   Replies, mentions, reposts, and watched-post updates use native APNs push
    notifications through the TAGGR push relay. The in-app inbox remains the
    authoritative notification record.

## Build And Review Gates

-   `npm run ios:audit`
-   `npm run ios:preflight`
-   `npm run ios:test`
-   `npm run ios:aasa`
-   `npm run ios:review`
-   Simulator and physical-device verification in `ios/docs/device_verification.md`

## App Store Requirements

-   UGC report and block controls must remain reachable.
-   Privacy and support routes must remain reachable without login.
-   Review notes must state which wallet actions are enabled and that auction
    bidding plus external exchange/trading links are hidden in the iOS build.
