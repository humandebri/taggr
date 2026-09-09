# TAGGR iOS Submission Runbook

## Purpose

Execute the remaining non-local gates for the SwiftUI iOS app in
`ios/docs/swift_requirements.md`.

Run local submission prep first. Production canister deployment and AASA
verification are follow-up gates and are not required for the prep-only pass.

## 1. Install And Select Full Xcode

Required state:

-   `/Applications/Xcode.app` exists.
-   `xcode-select -p` points to an `.app/Contents/Developer` path, for example
    `/Applications/Xcode.app/Contents/Developer`.
-   `xcrun simctl list runtimes --json` succeeds.
-   `xcrun --show-sdk-path --sdk iphoneos` succeeds.

If needed, select full Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then run:

```sh
npm run ios:preflight
```

### ICNativeClient build tool plugin

The first build opened from Xcode may ask to trust
`ICNativeClientBindgenPlugin`. Confirm that the package resolves to the
revision pinned in
`ios/TAGGR/TAGGR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
then approve it. The plugin generates Swift Candid bindings from
`ios/TAGGR/Candid/bindings.toml`.

The non-interactive build, test, and device-build scripts pass
`-skipPackagePluginValidation`; this avoids an interactive approval prompt
while retaining the pinned package revision.

## 2. Fill App Review Data

Use `ios/docs/app_store_review.md` as the App Store Connect Review Notes source.
The TestFlight upload is complete, but final review submission still needs one
production invite code after the production follow-up deploy.
Use `ios/docs/app_store_listing.md` for product-page copy, URLs, keywords, and
the screenshot capture plan.

Use either a reviewer-only Internet Identity sign-in procedure with the expected
TAGGR username, or keep the existing instruction that App Review should use the
invite code flow. The invite code must be a production code with enough credits
to create a reviewer account and test report/block flows.

Support/contact is already documented as `Links > HELP Realm` and
`Links > OpenChat Community`.

Then run:

```sh
npm run ios:review
```

Review `ios/docs/app_privacy_answers.md` against the live App Store Connect
privacy form before publishing privacy answers.

### YouTube upload release gate

Before building a release that exposes YouTube upload:

-   Enable YouTube Data API v3 in the Google Cloud project and create an iOS
    OAuth client for bundle ID `network.taggr.ios`.
-   Set `TAGGR_GOOGLE_CLIENT_ID` and `TAGGR_GOOGLE_REVERSED_CLIENT_ID` in the
    app target's Debug/Release build settings. The upload UI remains hidden when
    either value is empty.
-   Complete Google's OAuth verification for `youtube.upload` and
    `youtube.readonly`, plus the YouTube API Services audit required for public
    production uploads. Uploads from an unverified API project may be forced to
    private visibility.
-   Verify connect, revoke, resumable upload, background continuation, all three
    visibility choices, and draft-link insertion with a review YouTube channel.

## 3. Local Submission Prep

Run the local checks that do not require production canister access:

```sh
npm run ios:preflight
npm run ios:review
npm run ios:testflight:dry-run
```

Then verify the current TestFlight build on simulator and device and record the
result in `ios/docs/device_verification.md`. Do not mark production-dependent
items as PASS until the production follow-up deploy is complete.

## 4. Deferred Production Follow-Up

Deploy the frontend and backend asset changes to the production TAGGR canister
before final App Store review submission. The deployment must include:

-   `src/frontend/assets/.well-known/apple-app-site-association`
-   `src/backend/assets.rs`
-   iOS privacy/support/token policy frontend changes

Build the production artifact first:

```sh
make build
```

Record the git revision and `target/wasm32-unknown-unknown/release/taggr.wasm.gz`
SHA-256 hash in the release notes:

```sh
git rev-parse HEAD
shasum -a 256 target/wasm32-unknown-unknown/release/taggr.wasm.gz
```

`make release` may also be run to produce container-built release artifacts
under `release-artifacts/`. Confirm the diff only contains the intended iOS
changes.

Confirm `icp` can read the intended production identity, then deploy through the
mainnet environment:

```sh
icp identity principal
icp deploy -e ic taggr
```

The selected identity must be a production controller for
`6qfxa-ryaaa-aaaai-qbhsq-cai`. If the local default identity is not production,
switch it with `icp identity default <name>` before deployment.

After deployment run:

```sh
npm run ios:aasa:local
npm run ios:aasa
```

The production AASA path must return `application/json`, publish
`paths: ["/*"]`, and include
`AKN976G7AK.network.taggr.ios` in `webcredentials.apps`:

-   `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/.well-known/apple-app-site-association`

## 5. Verify On Simulator And Device

Record evidence in `ios/docs/device_verification.md`.

Required PASS entries:

-   Simulator launch
-   Physical device launch
-   Production URL load
-   Internet Identity continuity
-   Internal navigation
-   External navigation
-   Universal link
-   Share sheet
-   Offline reload UI
-   iPhone SE moderation reachability

## 6. TestFlight Build

TestFlight upload is already complete for this submission prep pass.

New TestFlight builds use the iOS marketing version from the Xcode project and a
Japan-time build number in `YYYYMMDDHHmm` format. App Store Connect displays
that value as a label such as `ビルド202606291432`.

The default upload uses the current Japan time:

```sh
npm run ios:testflight:dry-run
npm run ios:testflight:upload
```

If an upload is retried in the same minute, override the build number with the
next minute or the intended timestamp:

```sh
TAGGR_BUILD_NUMBER=202606291433 npm run ios:testflight:upload
```

The uploaded app starts on the production TAGGR canister by default:

-   `6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`

The uploaded TestFlight app is fixed to the production canister. For optional
staging-device verification, use the dedicated build documented in
`ios/docs/device_verification.md` instead of the distribution build.

After `Upload succeeded`, wait for App Store Connect processing to complete
before adding the build to internal or external TestFlight testing.

## 7. Final Completion Gate

Run this only after the deferred production follow-up deploy, production invite
code, and device verification are complete.

Use the lightweight blocker check when only external submission gates need a
quick recheck:

```sh
npm run ios:blockers
```

Run:

```sh
npm run ios:completion
```

The implementation is not complete until this command passes.
