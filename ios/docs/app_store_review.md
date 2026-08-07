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
-   Submission value to fill before final review submission:
    -   Demo account: App Review should use the invite code flow below.
    -   Invite code: provide one production invite code in App Store Connect
        review notes after the production follow-up deploy.
    -   Notes contact: `Links > HELP Realm` and `Links > OpenChat Community`

Current submission prep status:

-   TestFlight upload: complete.
-   Production follow-up: pending AASA/privacy/support asset deployment.
-   Final review submission remains blocked until the production invite code is
    added to App Store Connect Review Notes.

## Suggested Review Notes

TAGGR is a decentralized social network with user-generated content. The iOS app
is a SwiftUI native client for the existing TAGGR production service. It uses a
system authentication session for Internet Identity authorization.

Moderation controls are available from post and profile menus after sign-in:
users can report posts/users and block users. Public support and privacy links
are available from `Links`.

The iOS app can display TAGGR balances, display ICP wallet balances, send ICP,
withdraw rewards, and mint credits through the production canister flow. Auction
bidding and external exchange/trading links are hidden for the iOS submission.

Review access:

-   Use the public demo path without login for feed, public posts, realms,
    profiles, token pages, transaction pages, privacy, and support links.
-   To test report and block flows, create a reviewer account through the invite
    code flow. Fill the production invite code in App Store Connect after the
    production follow-up deploy.
-   Contact/support paths are `Links > HELP Realm` and
    `Links > OpenChat Community`.

## Moderation

TAGGR is a social network with user-generated content.

-   Report posts/users: profile menu reports the user; post flag action reports
    the post author.
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
