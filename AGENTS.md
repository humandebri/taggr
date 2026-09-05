# AGENTS.md

User instructions **always** override this file.

## Taggr

Taggr is a decentralized social network implemented in 2021 and deployed to Internet Computer.
Read the [whitepaper](./src/frontend/assets/WHITEPAPER.md) for more details.

## Approach

-   Be very concise in output but thorough in reasoning.
-   Think before acting and make absolutely sure you understand the problem before trying to solve it.
-   Always ask for clarifications in case of doubts. Never guess.
-   Challenge the user if their inputs are inconsistent with your reasoning.
-   Avoid dependencies at any cost as long as they are not strictly necessary. If you need to use a library, make sure it is widely used and well maintained.
-   Do not re-read files you have already read unless the file may have changed.
-   Keep solutions simple and direct. No over-engineering. Do not invent things if possible, do everything in an idiomatic way.
-   Only fix bugs based on evidence obtained by debugging; never ever create speculative fixes unless user explicitly approved.

## Control

-   Never execute mutable Git commands: the user needs to review all your changes.
-   **Never** execute mutable system commands without user's explicit confirmation unless they asked you to do so.

## Efficiency

-   Always think ahead and try to optimize your steps to reduce the token expense.
-   If you need to consume a really big input, get a user confirmation.

## Code

-   Use ICP CLI for Internet Computer commands; do not use dfx.
-   Use the locally installed `idb` CLI for iOS Simulator and connected-device
    discovery, app and XCTest workflows, UI automation, logs, screenshots, and
    recordings. Start with `idb list-targets --json` and pass the selected
    target's UDID explicitly. Use `simctl` or `devicectl` directly only when
    `idb` does not support the required operation or when diagnosing why `idb`
    cannot see a target.
-   Always apply formatting (make format) and cargo check.

## iOS Native Auth

-   Native sign-in flow is:
    iOS `ASWebAuthenticationSession` -> Internet Identity `/authorize` ICRC-167
    URL -> `/ios-auth-callback` fragment response -> iOS app.
-   The public callback domain must be controlled by the app, serve a valid
    AASA response, appear in the app entitlements, and be declared by the
    derivation origin at `/.well-known/ii-auth-callbacks`.
-   Production and staging callbacks use their respective canister
    `<canister-id>.icp0.io` hosts. Do not add user-owned custom domains to the
    callback declaration.
-   For physical-device local canister auth before production AASA is deployed,
    use the active TAGGR HTTPS tunnel as the iOS callback domain:
    `TAGGR_CALLBACK_DOMAIN=<active-taggr-tunnel-host>`. The tunnel must serve a
    valid AASA response, declare only its own callback URL, and appear in the
    app entitlements.
-   A working physical-device build must satisfy all of these at the same time:
    `TAGGR_DERIVATION_ORIGIN` points to the active TAGGR HTTPS tunnel,
    `TAGGR_II_URL` points to an ICRC-167 Internet Identity `/authorize` URL,
    `TAGGR_CALLBACK_DOMAIN` points to the active callback domain that serves
    valid AASA and `/.well-known/ii-auth-callbacks`, and the callback URL exactly matches the
    `ASWebAuthenticationSession.Callback.https` matcher.
-   If sign-in looks inert, first check for stale `SafariViewService` /
    `ASWebAuthenticationSession` state, dead quick-tunnel DNS, and whether the
    device is locked before changing code.
