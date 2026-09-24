# TAGGR iOS App Privacy Answers

## Purpose

Draft App Store Connect privacy answers for the SwiftUI iOS app.

Use this as a submission worksheet, not as a legal sign-off. Recheck against the
live App Store Connect form before publishing.

Checked against the Apple App Privacy and App Store Connect submission help on
2026-07-04.

## Sources

-   Apple App Privacy Details:
    https://developer.apple.com/app-store/app-privacy-details/
-   App Store Connect App Privacy reference:
    https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy/
-   App Store Connect Manage App Privacy:
    https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/

## Privacy Links

-   Privacy Policy URL:
    `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy`
-   User Privacy Choices URL:
    `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/links`

## Tracking

-   Tracking: No.
-   Reason: MVP adds no advertising SDK, analytics SDK, data broker sharing, or
    third-party advertising measurement.

## Third-Party SDKs

-   GoogleSignIn is used only when a user explicitly connects a YouTube account
    to upload a selected video to that user's channel.
-   SwiftUI native app: no third-party native SDKs added for analytics or ads.
-   Internet Identity: authentication service opened through
    `ASWebAuthenticationSession`.
-   No analytics SDK.
-   No advertising SDK.
-   No push notification SDK in MVP.

## Data Types To Review In App Store Connect

Declare data collected by the app or through TAGGR backend calls if it is stored
off-device beyond real-time request handling.

-   User Content:
    -   Posts, comments, reactions, reports, realms, profile content, uploaded
        files, user-selected photos/videos, governance text, and moderation
        records.
    -   Use: App Functionality.
    -   Linked to user: Yes when associated with TAGGR account or principal.
-   Identifiers:
    -   Internet Identity principal, TAGGR user id, canister account data, wallet
        account identifiers, and system authentication session identifiers if
        retained.
    -   Use: App Functionality.
    -   Linked to user: Yes.
-   Financial Info:
    -   Token balances, transactions, ICP-related records, and wallet-related
        public account data visible in TAGGR.
    -   Use: App Functionality.
    -   Linked to user: Yes when associated with a TAGGR account or principal.
    -   iOS policy: Account supports ICP transfers and credit minting; bidding
        and exchange links remain hidden.
-   Contact Info:
    -   Only declare if the review account, support process, or user profile
        collects email, name, or other external contact data.
-   Diagnostics:
    -   Declare only if production logging retains crash, performance, or request
        diagnostics linked to app usage. MVP adds no native diagnostics SDK.

## Data Not Added By MVP

-   No native location collection.
-   No native contacts collection.
-   No native photos library collection outside explicit user-selected uploads
    through `PhotosPicker`.
-   No native microphone, camera, HealthKit, or fitness data collection.
-   No push notification token collection in Phase 1.

## YouTube Uploads

-   Selected videos and user-entered YouTube metadata are transferred directly
    from the device to YouTube; TAGGR canisters do not receive a video copy or
    Google authorization token.
-   The Google authorization session and resumable-upload state are retained on
    the device until completion, cancellation, expiry cleanup, or explicit
    disconnection.
-   A completed video's YouTube URL becomes public only when the user submits
    the TAGGR draft containing that URL.
-   Recheck App Store Connect disclosures for User Content, Identifiers, and
    third-party data handling before submitting the build.

## Pre-Submission Checks

-   Confirm production privacy route is deployed.
-   Confirm App Store Connect answers match current backend data retention.
-   Confirm token/crypto policy matches the enabled iOS wallet actions.
-   Confirm support/contact path is public and reachable without login.
-   Update this document if any analytics, advertising, push, crash reporting, or
    native SDK is added.
