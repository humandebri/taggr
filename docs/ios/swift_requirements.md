# TAGGR iOS Swift Requirements

## Decision

TAGGR iOS is a SwiftUI native app. It keeps the existing IC canister backend and
does not embed the React frontend for the main UI. WKWebView is used only for
Internet Identity authorization.

## Native Scope

- Feed, post, profile, realm, settings, reporting, blocking, sharing, and deep
  links are native SwiftUI flows.
- Internet Identity uses a dedicated WKWebView bridge.
- Token, ICP, wallet, auction, minting, transfer, and exchange actions are
  disabled for App Store submission. Read-only views may remain.
- Push notifications are out of scope for the first Swift release.

## Build And Review Gates

- `npm run ios:audit`
- `npm run ios:preflight`
- `npm run ios:test`
- `npm run ios:aasa`
- `npm run ios:review`
- Simulator and physical-device verification in `docs/ios/device_verification.md`

## App Store Requirements

- UGC report and block controls must remain reachable.
- Privacy and support routes must remain reachable without login.
- Review notes must state that crypto/token execution surfaces are read-only or
  disabled in the iOS build.
