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
    -   Provide App Review with an active demo account or an invite code with
        enough credits to create an account.
    -   Use the signed-in account to verify reporting and blocking from profile
        and post menus.
-   Submission placeholder to fill before upload:
    -   Demo account: App Review should use the invite code flow below.
    -   Invite code: APPREVIEW-TODO-PRODUCTION-INVITE
    -   Notes contact: `Links > HELP Realm` and `Links > OpenChat Community`

Accepted replacement format:

-   Demo account: either a reviewer-only Internet Identity sign-in procedure
    with the expected TAGGR username, or an explicit statement that App Review
    should use the invite code flow below.
-   Invite code: one production invite code with enough credits to create a
    reviewer account and exercise report/block flows.

## Suggested Review Notes

TAGGR is a decentralized social network with user-generated content. The iOS app
is a SwiftUI native client for the existing TAGGR production service. It uses a
dedicated WKWebView only for Internet Identity authorization.

Moderation controls are available from post and profile menus after sign-in:
users can report posts/users and block users. Public support and privacy links
are available from `Links`.

Token, transaction, and wallet-related views are read-only in the iOS app.
Transfers, minting, auction bidding, and external exchange/trading links are
hidden for the iOS submission.

## Moderation

TAGGR is a social network with user-generated content.

-   Report user/post: profile menu and post flag action.
-   Block user: profile menu.
-   Review reports: visible to stalwarts through report banners.
-   Support/contact: `#/links` links to HELP realm, OpenChat community, and source
    repository.

## Privacy

Privacy policy route: `#/privacy`

The MVP iOS app adds no analytics SDK, advertising SDK, or push notification
token collection. It uses native SwiftUI screens, Internet Identity, and the
same production canister APIs as the website.

## Token And Crypto Policy

MVP policy: read-only token/crypto surfaces in the iOS app.

-   Token and transaction pages remain visible.
-   Wallet transfers are hidden in the iOS app.
-   ICP credit minting is hidden in the iOS app.
-   Auction bidding is hidden in the iOS app.
-   External exchange/trading links are hidden in the iOS app.

## Universal Links

The app config registers the production canonical domain and limits universal
links to public TAGGR routes for posts, users, realms, transactions, and token
pages.

Before App Store submission, the public canister must serve a valid
`.well-known/apple-app-site-association` file with the real Apple development
team ID. Use this shape:

```json
{
    "applinks": {
        "details": [
            {
                "appIDs": ["AKN976G7AK.network.taggr.ios"],
                "components": [
                    { "/": "/post/*" },
                    { "/": "/user/*" },
                    { "/": "/realm/*" },
                    { "/": "/transaction/*" },
                    { "/": "/transactions" },
                    { "/": "/transactions/*" },
                    { "/": "/tokens" },
                    { "/": "/tokens/*" }
                ]
            }
        ]
    }
}
```

## Build Notes

-   Full Xcode is required. Command Line Tools alone does not provide `simctl`.
-   No Rust iOS targets, CocoaPods, XcodeGen, or Tauri CLI are required.
-   The Xcode project is `ios/TAGGR/TAGGR.xcodeproj`.
