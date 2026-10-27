---
name: taggr-testflight
description: Archive, upload, and publish TAGGR's iOS app to TestFlight when a TAGGR beta build needs distribution. Do not use for generic iOS releases or App Store production releases.
metadata:
    short-description: Publish TAGGR iOS beta builds to TestFlight
---

# TAGGR TestFlight

Use this skill only for TAGGR iOS TestFlight work. It distributes an already
committed source state; Git commits, App Store production submission, and
certificate or provisioning-profile creation are outside its scope.

## Resolve before mutation

-   Inspect the worktree. If tracked changes are present, do not include them in
    the build; ask the user to commit or explicitly choose a committed revision.
-   Resolve the Xcode project and scheme from the repository, then verify the
    Bundle ID, marketing version, build number, and production canister target.
-   Use only the named `TAGGR` App Store Connect profile after confirming it with
    `asc auth status --verbose`. Never print or persist secrets.
-   Read the current App Store Connect build state. Use the repository's Tokyo
    timestamp convention unless the user supplied `TAGGR_BUILD_NUMBER`, and do
    not reuse an uploaded build number.
-   Confirm the local distribution identity and existing TAGGR App Store
    provisioning profile. Do not create, replace, or revoke signing assets.

## Verify and archive

-   Run proportionate checks, including `cargo check` and the focused iOS build.
    Treat unavailable simulator infrastructure separately from build or test
    failures; never report skipped tests as passing.
-   The Candid build-tool plugin requires `-skipPackagePluginValidation` for
    non-interactive builds. Confirm the revision in `Package.resolved` before
    using that flag.
-   Archive under the repository's ignored `.build/` directory. Verify the
    archive's Bundle ID, marketing version, and build number before export.

## Export and upload

-   Prefer a local IPA export followed by `asc --profile TAGGR builds upload`.
    This path works without an Xcode App Store Connect account.
-   If direct Xcode upload fails with `Failed to Use Accounts`, keep the valid
    archive and switch to manual export using the verified existing distribution
    identity and provisioning-profile mapping. Do not rebuild or create signing
    assets solely to recover the upload.
-   Verify the IPA metadata before upload. Wait until the exact uploaded build is
    discoverable and its processing state is `VALID`.

## TestFlight publication

-   Draft a concise English `What to Test` note from the actual user-visible
    changes. Show it with the resolved build and audience before external
    publication.
-   Reuse `usesNonExemptEncryption=false` only when the current diff has not
    changed cryptographic scope and a prior valid TAGGR build establishes that
    declaration. Otherwise request the user's compliance answer.
-   Resolve the external group named `TAGGRiOS out` at runtime; do not store its
    ID. Add the build and submit it for Beta App Review only after the user has
    explicitly authorized external TestFlight publication in the current turn.
-   Report `IN_BETA_TESTING`, `WAITING_FOR_BETA_REVIEW`, and processing failures
    as distinct outcomes. A successful upload alone is not external availability.

## Safety boundaries

-   Confirm immediately before upload, external-group assignment, or Beta Review
    submission unless the user's current request explicitly authorizes that exact
    action.
-   Do not perform App Store submission, release, Git history changes, profile or
    certificate mutations, or tester/group management beyond assigning the
    resolved build to `TAGGRiOS out`.
