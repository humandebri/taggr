# TAGGR iOS App Store Review

## Review Access

-   Production URL: `https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`
-   Bundle identifier: `network.taggr.ios`
-   Apple Team ID: `AKN976G7AK`
-   Public demo path without login:
    -   Open the app.
    -   Browse public feed, public posts, public realms, user profiles, token
        pages, and transaction pages.
    -   Open `Links > Privacy policy`.
    -   Open `Links > HELP Realm`.
-   Account-required review path:
    -   Open **Account > Sign in > Password**.
    -   Enter the review account's seed phrase provided privately in App Store
        Connect. Preserve spaces and capitalization exactly.
    -   Use the signed-in account to verify reporting and blocking from profile
        and post menus. A new invite is not required for each review.
-   Preparation before submission:
    -   Create a dedicated production account once through the website's
        **Seed Phrase** registration flow, and give it enough credits for review.
    -   Verify the same phrase signs into that account in the submitted iOS build.
    -   Put the expected username and phrase only in App Store Connect's private
        review access details. Never commit the phrase or a private key.
    -   Internet Identity accounts cannot use this phrase login; the demo account
        must have been created using the website's Seed Phrase method.
    -   Notes contact: `Links > HELP Realm` and `Links > OpenChat Community`.

Current submission prep status:

-   This login change has not been distributed. A previous TestFlight upload
    does not include it.
-   Library publication and app distribution require code review and explicit
    owner approval, followed by validation against the published dependency.
-   Final submission requires verified production review credentials and the
    production follow-up deployment described in the submission runbook.

## Suggested Review Notes

TAGGR is a decentralized social network with user-generated content. The iOS app
is a SwiftUI native client for the existing TAGGR production service. It uses a
system authentication session for Internet Identity authorization, and supports
existing TAGGR seed-phrase accounts through native sign-in.

Moderation controls are available from post and profile menus:
users can report posts/users and block users. Public support and privacy links
are available from Account > Privacy & support.

The iOS app can display TAGGR balances, display ICP wallet balances, send ICP,
withdraw rewards, and mint credits through the production canister flow. Auction
bidding and external exchange/trading links are hidden for the iOS submission.

Review access:

-   Use the public demo path without login for feed, public posts, realms,
    profiles, token pages, transaction pages, privacy, and support links.
-   For sign-in, open **Account > Sign in > Password** and enter the phrase
    supplied in the private review access details. The expected username is
    supplied there as well. No new registration or invite is required.
-   Reporting and local blocking do not require tokens or credits.
-   Contact/support: Account > Privacy & support > Contact @FF on TAGGR.

## Moderation

TAGGR is a social network with user-generated content.

-   Report posts/users: post flag action or profile menu opens the in-app report form. Success is shown only after the operator's service saves the report. Failed submissions can be retried without retyping.
-   Block user: profile menu, effective immediately in this iOS client.
-   Operator review: private D1 records accessed with the operator CLI. The operator checks reports within 24 hours and can hide posts or a user's content in the official iOS app.
-   Restrictions do not delete on-chain data or suspend accounts. Lists refresh while the app is active; outages retain the last known list without blocking app access.
-   Support/appeal: Account > Privacy & support > Contact @FF on TAGGR.
-   Verify production report receipt, hide/restore, and real-device behavior before claiming these features are ready for submission.

## Privacy

Privacy policy route: `#/privacy`

The MVP iOS app adds no analytics SDK, advertising SDK, or push notification
token collection. It uses native SwiftUI screens, Internet Identity, and the
same production canister APIs as the website.

## Token And Crypto Policy

The iOS app exposes wallet operations needed for normal TAGGR use.

-   TAGGR and ICP balances are visible in Account.
-   ICP wallet transfers are available after Internet Identity sign-in.
-   ICP credit minting is available after Internet Identity sign-in.
-   Auction bidding is hidden in the iOS app.
-   External exchange/trading links are hidden in the iOS app.

## Universal Links

The app config registers the production canonical domain and lets iOS receive
TAGGR universal links for all app routes. Native auth still returns through
`/ios-auth-callback`.

Before App Store submission, the public canister must serve a valid
`.well-known/apple-app-site-association` file with the real Apple development
team ID. Use this shape:

```json
{
    "applinks": {
        "apps": [],
        "details": [
            {
                "appID": "AKN976G7AK.network.taggr.ios",
                "paths": ["/*"]
            }
        ]
    },
    "webcredentials": {
        "apps": ["AKN976G7AK.network.taggr.ios"]
    }
}
```

## Build Notes

-   Full Xcode is required. Command Line Tools alone does not provide `simctl`.
-   No Rust iOS targets, CocoaPods, XcodeGen, or Tauri CLI are required.
-   The Xcode project is `ios/TAGGR/TAGGR.xcodeproj`.
