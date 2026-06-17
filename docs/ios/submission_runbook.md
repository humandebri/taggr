# TAGGR iOS Submission Runbook

## Purpose

Execute the remaining non-local gates for the SwiftUI iOS app in
`docs/ios/swift_requirements.md`.

Run this only after the implementation changes are reviewed and ready to deploy.

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

## 2. Fill App Review Data

Edit `docs/ios/app_store_review.md` and replace the invite-code placeholder in
the Review Access section.

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

Review `docs/ios/app_privacy_answers.md` against the live App Store Connect
privacy form before publishing privacy answers.

## 3. Deploy Production Assets

Deploy the frontend and backend asset changes to the production TAGGR canister.
The deployment must include:

-   `src/frontend/assets/.well-known/apple-app-site-association`
-   `src/backend/assets.rs`
-   iOS privacy/support/token policy frontend changes

Build the production artifact used by `dfx.json` first:

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
under `release-artifacts/`, but `dfx deploy` reads the `dfx.json` wasm path
above. Confirm the diff only contains the intended iOS changes.

Confirm the repository-pinned dfx version is available:

```sh
npm run ios:dfx
```

If dfx reports that `0.32.0` is not installed, install it before deployment:

```sh
dfxvm install 0.32.0
```

Run the deploy readiness check. It verifies the pinned dfx version, production
identity, production canister controller access, local iOS frontend bundle,
local AASA, and built wasm artifacts. The default production identity name is
`prod`; set `IOS_DFX_IDENTITY` when the local dfx identity uses another name:

```sh
export IOS_DFX_IDENTITY=prod
npm run ios:deploy:ready
```

Then deploy the `taggr` canister with the production identity:

```sh
dfx identity --identity "$IOS_DFX_IDENTITY" get-principal
dfx --identity "$IOS_DFX_IDENTITY" deploy --network ic taggr
```

The selected identity must exist and load successfully before deployment. On
this machine `prod` is currently missing; import the intended production
identity, rename it to `prod`, or set `IOS_DFX_IDENTITY` to the existing
production identity name before running the deploy command. If an existing
identity such as `production` fails with an encrypted PEM or keyring error,
restore the keychain entry or import an accessible production identity first.
The identity preflight times out after 15 seconds so non-interactive checks fail
instead of waiting indefinitely for keyring access.

After deployment run:

```sh
npm run ios:aasa:local
npm run ios:aasa
```

Both production paths must return `application/json` and include
`AKN976G7AK.network.taggr.ios`:

-   `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/.well-known/apple-app-site-association`
-   `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/apple-app-site-association`

## 4. Verify On Simulator And Device

Record evidence in `docs/ios/device_verification.md`.

Required PASS entries:

-   Simulator launch
-   Physical device launch
-   Production URL load
-   Internet Identity continuity
-   Internal navigation
-   External navigation
-   Universal link
-   Deep link
-   Share sheet
-   Offline reload UI
-   iPhone SE moderation reachability

## 5. Final Completion Gate

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
