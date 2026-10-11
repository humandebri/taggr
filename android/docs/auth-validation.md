# Android browser authentication validation

Validated on 2026-10-02 by operating `TAGGR_Pixel_9_API_36` (`emulator-5554`)
through ADB, using the real Chrome AuthTab and the fork's Kotlin SDK.

## Results

-   Chrome opened the SDK's ICRC-167 URL and fetched the HTTPS callback declaration.
-   Digital Asset Links associated `org.taggr.android` with the actual debug APK
    signing certificate; Google's check returned `linked: true`.
-   A disposable identity was created in a dedicated local Internet Identity.
-   II returned its canister-signed delegation through AuthTab's HTTPS callback.
-   The SDK verified the delegation against the local network root and saved the
    session in the Android Keystore-backed encrypted store.
-   After force-stopping and cold-starting the app, both the session and a saved
    signed query were restored from disk and verified. The principal was unchanged.
-   A P-256 child delegation narrowed targets to the configured canister and
    permissions to `queries`.
-   The restored session sent a signed `lookup` query to II. Default query
    verification succeeded and decoded one Candid reply value.
-   Sign-out deleted the session and saved query; loading afterward was rejected
    with `No saved session`.
-   Closing the real Chrome tab produced cancellation, and a new authentication
    attempt could immediately reopen Chrome.

This was a **local II integration test**. Local dummy authentication replaced
the hardware passkey step; delegation issuance, browser redirects, certificate
verification, network queries and Keystore operations were real. Mainnet passkey
login and production callback deployment remain unverified.

The July network launcher bundled an II frontend without ICRC-167 fragment
transport and displayed `Unable to connect`. Updating to
`v16.0.0-2026-09-25-03-28` resolved that failure. Existing networks were not stopped.

Requesting explicit `targets` exposed another useful negative case: this II
returned an unrestricted chain, which the SDK correctly rejected. Standard II
login used default options; child delegation narrowing was verified separately.
Do not silently accept an unrestricted response to a restricted request.

## Debug harness

`app/src/debug/.../AuthValidationActivity.kt` is excluded from release builds.
Launch it with public configuration values:

```sh
adb -s emulator-5554 shell am start -W \
  -n org.taggr.android/.AuthValidationActivity \
  --es callbackOrigin https://YOUR-CALLBACK-HOST \
  --es iiOrigin https://YOUR-LOCAL-II-HOST \
  --es rootKey BASE64-DER-LOCAL-ROOT-KEY
```

Use the public root from `icp network status --json` for the selected local
network, converting its hex DER value to Base64. The callback host needs
`/.well-known/assetlinks.json` with the APK's actual certificate fingerprint and
`/.well-known/ii-auth-callbacks` declaring its `/android-auth-callback` URL.

The existing local proxy supports opt-in `TAGGR_ANDROID_AUTH=1`.
For a callback-only server, set `TAGGR_STATIC_ONLY=1` and provide a static root;
API paths return 404. `TAGGR_II_DUMMY_AUTH=1` is limited to a `.localhost` upstream
and must only be used with a disposable local II.

The test used a dedicated network under ignored `.build/android/auth-network`,
gateway port 18100, and temporary HTTPS tunnels. The tunnels and proxies were
stopped after verification. No production canister was deployed or changed.

Evidence is retained locally under `.build/android/`: `auth-restored.png`,
`auth-query-verified.png`, build logs and the public network configuration.
Private session material remains in the app's encrypted store and is deleted
by sign-out; it was not copied to these artifacts.

## Private loopback ownership probe — current environment

A new debug-only `LocalAuthTabProbeActivity` opens a fixed localhost HTTPS page and reports only the AuthTab result code and whether a non-secret test fragment matches. It does not request an identity, delegation or signed session. App build and Lint passed (`.build/android/private-auth/build.log`); root formatting and cargo check passed in that directory. This is a diagnostic artifact, not a replacement for normal-app authentication.

[Chrome's AuthTab documentation](https://developer.chrome.com/docs/android/custom-tabs/guide-auth-tab) identifies Chrome 137 as the stable introduction. The current installed emulator browser reports `versionName=133.0.6943.137`. Current [Chromium AuthTab verification source](https://raw.githubusercontent.com/chromium/chromium/main/chrome/android/java/src/org/chromium/chrome/browser/browserservices/ui/controller/AuthTabVerifier.java) builds a default-HTTPS verification origin from the callback host. Its [asset-link handler](https://raw.githubusercontent.com/chromium/chromium/main/components/content_relationship_verification/digital_asset_links_handler.cc) fetches the declared file directly from that origin. These current upstream sources do not establish the behavior of the installed older browser.

The local test served the actual debug APK fingerprint over one-day localhost TLS on host port 18443. A host request verified that TLS chain and fetched assetlinks. The generated CA was installed only into the disposable emulator, with no Mac trust-store change. The browser reached a connection-refused page: `adb reverse tcp:443 tcp:18443` had failed with `cannot bind listener: Permission denied`. There was no successful AuthTab return or ownership-verification result, so this is transport-failure evidence, not evidence of a rejected delegation, broken passkey or successful private auth.

The first emulator run stopped through the seven-minute time guard (peak 5,775 MiB, exit 0). A separate bounded cleanup run removed only `TAGGR disposable emulator CA`; the User trusted-credentials tab was checked empty afterward. The copied CA file was deleted, no ADB reverse mapping remained, the local TLS server was stopped and both generated private keys were deleted. Cleanup peak was 5,490 MiB, no guard fired and emulator exit was 0. Final checks found no emulator/Gradle/Kotlin daemon. Logs remain under ignored `.build/android/private-auth/`; no authentication/session material was used or copied.

Next private-auth work must resolve default-HTTPS reachability and use a browser supporting the actual AuthTab contract before attempting local II and the ordinary TAGGR login/post flow. This has not relaxed certificate, DAL, callback-origin, nonce or delegation checks. External authentication tunnels remain subject to the pending consent described in the completion plan.

## API 37 private HTTPS ownership probe

The official Google APIs ARM64 system image `system-images;android-37.0;google_apis;arm64-v8a` revision 6 was installed into the separate `TAGGR_Auth_Pixel_9_API_37` AVD. The original API 36 AVD was retained. The new image reports API 37, `ro.debuggable=1` and Chrome `145.0.7632.218`; no separately downloaded browser APK was needed. `adb root` and `adb reverse tcp:443 tcp:18443` both succeeded. The reverse listener exists only inside this disposable emulator; host port 443 still requires permission and was not changed.

A one-day localhost certificate was signed by `TAGGR disposable emulator CA 37`, installed only in that AVD's User trusted-credentials store. The loopback TLS server served the installed debug APK's actual fingerprint, the fixed non-secret probe page and callback. Chrome fetched `/probe` and `/.well-known/assetlinks.json` over the private reverse mapping. The page was visually inspected and its callback link tapped. The probe returned `Local AuthTab result: -1; callback matched: true`. Closing a subsequent AuthTab returned `0; callback matched: false`; immediately reopening and tapping the callback returned success again. The preserved XML results are `result-success.xml`, `result-cancel.xml` and `result-retry.xml` under ignored `.build/android/private-auth2/`. This establishes AuthTab callback ownership/transport with trusted localhost TLS on this image. No certificate/DAL check was disabled, no Android domain was manually marked verified, and no identity, delegation, passkey or signed session was involved. It does not establish normal TAGGR II authentication or authenticated writes.

Afterward, only the added CA was uninstalled. `ca-removed.xml` shows the User tab selected and empty. The copied public CA and device UI dump were removed, the reverse mapping was removed and checked empty, and adbd was returned to non-root mode. The exact owned loopback TLS server was stopped and both generated private keys deleted. The first bounded probe run ended after its planned idle duration before the callback could be tapped; it had loaded the page and completed Chrome's initial setup. The follow-up run produced the success/cancellation/retry evidence and cleanup. No external tunnel, Mac trust-store change, production change or canister-network startup occurred.

The API 37 emulator's default boot raised requested RAM to 4 GiB and exceeded the 6 GiB process-tree RSS guard. The checked-in bounded runner now uses the experimentally verified `-memory 2048 -lowram -gpu lavapipe` configuration and samples every 500 ms; see `development-resources.md`. The older Espresso 3.5.0 resolved through Compose failed all four selected UI tests before app interaction because reflective `InputManager.getInstance` is absent. The explicit test-only Espresso 3.7.0 dependency contains the [official fix](https://developer.android.com/jetpack/androidx/releases/test#espresso-3.7.0). The identical four normal navigation/public profile cases then passed, with a 4,882 MiB peak, no guard and emulator exit 0. Build/Lint and 169 JVM tests passed (`private-auth/api37-espresso-build.log`); the successful device result is `emulator-check-20261007-224414/`. These short runs do not prove that the reported long-session Codex/emulator leak is resolved.

The private probe runs peaked at 4,734 MiB and 4,901 MiB respectively; neither guard fired and both emulators exited 0. Root `make format`, `cargo check --locked` and `git diff --check` passed afterward. Final checks found no emulator, Gradle/Kotlin daemon or owned probe server; ADB listed no devices and host free memory was 74%. The main Codex renderer snapshot was 1,237,680 KiB, approximately 1.18 GiB; this single post-run sample does not resolve the prior long-session report.

## Ordinary TAGGR local login, registration, post and reply

The ordinary `MainActivity` flow has now been exercised with private localhost HTTPS, not the SDK validation activity. The dedicated `.build/android/auth-network` network was started at its actual `http://localhost:18100/` endpoint. Its reported public BLS root matched the saved root. The old detached TAGGR canister was absent, so a new detached canister was created and the existing dev-only TAGGR Wasm installed in initial-install mode. No existing state was reinstalled. The test target was `4caro-hl777-77775-aaaba-cai`; the original canister/credits on mainnet were untouched.

The current [official II release](https://github.com/dfinity/internet-identity/releases/tag/release-2026-10-02), `release-2026-10-02`, supplied the frontend Wasm. Its SHA256 matched both the published checksum file and the release's `a8bf61eb5745e241f0fe54e35e915cf9f68b4068c36bf7119637c85af04b111b`. A separate local frontend canister `4fbx2-kt777-77775-aaabq-cai` was installed with the official Candid init contract, the managed local II backend `rdmx6-jaaaa-aaaaa-aaadq-cai`, HTTPS backend origin `https://localhost:18444`, root-key fetching and local-only dummy authentication. The previously recorded `v16.0.0-2026-09-25-03-28` string is not a GitHub release tag; that attempted release lookup returned 404. No installed II backend or user's identity was upgraded.

A loopback-only TLS server forwarded the actual local canister APIs and served debug APK assetlinks plus `https://localhost/android-auth-callback` in `ii-auth-callbacks`. It never logged request queries, bodies, cookies or callback fragments. One-day CA trust was installed only in the dedicated AVD. The debug manifest now selects a [domain-specific network security configuration](https://developer.android.com/privacy-and-security/security-config): system and User CA trust for exact `localhost`, with cleartext still forbidden. No trust-all client, hostname exception or custom global security provider was introduced. Lint rejected localhost as a public verified App Link, so manifest `autoVerify` is false only when the configured browsing host is exact localhost; the default/public host still uses true. Release-generated manifest has no debug trust configuration or debug probe activities, its autoVerify remains true, and merged release resources contain no debug CA XML.

The debug build used localhost for API/derivation/callback, the reported local BLS root, the local TAGGR canister and II at localhost:18444. App build/Lint and 169 JVM tests passed (`private-auth2/local-app-final-build.log`). On the emulator, the ordinary terms screen and Account's Continue with Internet Identity launched AuthTab. A disposable II identity was created using the explicitly enabled dummy seed-index prompt. II issued the real delegation and returned it to the normal app, which showed the authenticated Principal and account-creation form. The host TLS/canister query paths and Android Keystore/session handling were real; only the hardware passkey step was substituted.

After the bounded emulator shut down and restarted, the ordinary app restored the exact same authenticated Principal without another browser login (`session-restored.xml`). Unfunded normal registration correctly returned `payment missing`. To test the supported invitation registration path, only a dev bootstrap inviter was seeded via `create_test_user` with fake credits. Its normal create_invite endpoint created a single 10,000-credit invitation. The app then registered `androidlocal` through the normal username/invite form and showed 10,000 credits (`account-created.xml`). The app's user was not directly seeded; paid registration/real ICP funding was not tested.

The ordinary Feed Post form sent `Android local HTTPS roundtrip test 20261007` once and displayed Posted successfully plus the author/body in the conversation (`post-published.xml`). Its ordinary Reply form sent `Local reply from the normal Android app` once and showed success (`reply-published.xml`). An independent public CLI read of local posts verified persisted post ID 2, reply ID 3, author ID 1 for both, and reply parent ID 2 (`published-posts.json`, `persistence-summary.json`). No automatic replay, unknown-result recovery, attachment upload, edit, delete, financial transfer or other authenticated feature was established by these two writes.

Finally, normal Account Sign out returned to the guest Continue with Internet Identity screen (`signed-out.xml`). The exact added User CA was removed, and the User tab was verified selected and empty (`ca-removed.xml`). Copied CA/UI files and both reverse mappings were removed and checked empty; adbd was unrooted. The exact owned TLS server and selected local network were stopped and both generated private keys deleted. All evidence is under ignored `.build/android/private-app-auth/`; private session/key material was not exported into evidence. This is a real normal-app local integration result, not proof of a physical-device/mainnet passkey flow, production ownership deployment, all iOS feature parity or long-session leak resolution.

The login, registration/publication and cleanup emulator runs sampled peaks of 5,271, 4,665 and 4,735 MiB respectively. All three had no guard and exited 0 after their configured durations. The first two ended before the next manual step; their confirmed terminal handles were checked before a subsequent bounded run. That does not invalidate the already recorded state transitions, nor make every idle-run result an automated authentication assertion. XML/result and independent persistence assertions supply the integration evidence.

The final build removed all local Gradle overrides and passed normal app/test APK assembly, Lint and 169 JVM tests (`private-app-auth/default-final-build.log`). Newly generated debug/release BuildConfig files were checked for public default URLs and empty override root; both default merged manifests restored public autoVerify=true, and release still excludes local trust/probes. Root formatting, cargo check and diff whitespace checks passed. The installed disposable-AVD APK remains the local test variant, signed out; the final workspace APK is restored to the normal public configuration. No production build was distributed.

Final process/port verification found the launcher had reported network shutdown while its owned PocketIC child remained, reparented to PID 1 with a 30-day TTL. Its observed startup PID/command, sole gateway and management API's single instance established ownership; that child alone was terminated. The selected gateway and private TLS/management ports were then verified closed. This cleanup finding is recorded in `development-resources.md`; the successful local auth/write result does not depend on retaining that process.

### Follow-up image and edit flow — 2026-10-08

The same normal AuthTab + real local II delegation path authenticated the image test account, with only passkey authentication substituted by local dummy seed 0. A long interactive attempt failed the existing SDK lifetime bound (`Session key or lifetime mismatch`); restarting with a fresh authorization request completed successfully. The Swift reference has the same expiry bound; no validation was weakened. The image test account was directly seeded in this run, so it does not add signup evidence.

After successful native login, normal storage registration, Photo Picker import, bucket upload, posting and editing were exercised and independently read back. See `completion-plan.md` for observed app fixes and exact evidence. Final sign-out and CA removal were verified in the normal UI. The local TLS private keys and owned runtime services were removed/stopped; public/default APK regeneration follows. Real-device/mainnet passkeys remain unverified.

### Follow-up Follow/Mute/Block — 2026-10-08

Another fresh normal-app local II login returned the same expected Principal within the existing expiry bound. The fixture seeded two fake-credit users directly; no signup/funding assertion is made. Follow, confirmed Mute, Unmute, confirmed Block and Unblock were operated through the other user's ordinary profile. Independent public canister reads confirmed each stored membership, and the normal app displayed/restored hidden-content state for Block/Unblock. `completion-plan.md` records exact steps and ignored evidence. Normal Sign out, empty User CA tab, adb reverse cleanup, unrooting and owned server/key/network cleanup were completed. Hardware/mainnet passkeys, real operator reporting and remaining authenticated journeys are still unverified.

### Follow-up reactions and bookmarks — 2026-10-08

Fresh ordinary Account/AuthTab authentication returned the expected native Principal. The official frontend's old cached identity belonged to the previously discarded network; its anchor rejection was resolved through the official new-identity menu with dummy seed 0. Actual local signed reaction 11 persisted on peer post 2 and was independently verified by ICP CLI. Bookmark saving and removal each survived a full app process restart and native signed own-user refresh. The native signed post query also enforced peer-blocked React/Reply controls and restored them after unblocking. Details and exact artifacts are in `completion-plan.md`. Normal sign-out, exact User CA deletion, reverse/root/file cleanup, TLS/key removal and owned network cleanup were verified. This is local ordinary-app integration evidence; real mainnet/physical passkeys remain unverified.

### Follow-up Realm membership and Inbox — 2026-10-08

Fresh ordinary AuthTab authentication returned the expected native Principal using only the official local dummy authenticator for the hardware step. Normal Realm Join/Leave, individual/all notification reads, archive restoration, exact notification post/reply navigation and Watch/Unwatch were exercised. Membership and watchers were independently verified by canister reads; private notification flags survived app process restart with fresh signed user reads. The actual welcome notice also exposed literal Markdown markup in Android; the shared native Markdown renderer now replaces the plain message text. `completion-plan.md` records exact evidence, the passing nine-case Inbox/Realm UI verification of this fix, and normal sign-out/User CA/adb/TLS/key/network cleanup. Real-device/mainnet passkeys remain unverified.

### Follow-up Realm management and local NNS Ledger — 2026-10-08

Fresh ordinary AuthTab authentication on an NNS-enabled isolated network returned the expected native Principal using only the official local dummy authenticator for the hardware step. Normal Realm creation/automatic membership and controller editing were independently read back. Normal ICP transfer used the actual managed NNS Ledger and fake development funds: block 34 sent 0.1 ICP plus 0.0001 ICP fee, with exact independent balances and restoration after process restart. Details, evidence and the observed Realm success-screen fix are in `completion-plan.md`. Sign-out, temporary CA/adb/root cleanup, owned TLS/private-key/network cleanup and default public APK restoration completed. Lost-response transfer recovery, CMC operations and hardware/mainnet passkeys remain unverified.

### Follow-up actual lost-response transfer recovery — 2026-10-08

Ordinary app authentication on a fresh local NNS-enabled network supported two actual reply-loss journeys. The first pending transfer survived process restart; explicitly retrying the frozen original payment returned block 34 without changing either balance. The second pending transfer survived restart and Check transfer result recovered block 35 without another Ledger submission. Independent balances matched exactly two fake-ICP amounts and fees. `completion-plan.md` and ignored `recovery-protocol-summary.json` record the actual fault injection, UI assertions and Ledger evidence. Hardware/mainnet passkeys and real funds remain unverified.

### Follow-up credit purchase and interrupted payment — 2026-10-08

Ordinary app/II authentication supported actual local invoice creation, fake-ICP payment and credit settlement. One normal purchase and one purchase with a deliberately lost Ledger response each minted exactly 1,000 credits. The interrupted purchase survived process restart; Check / continue recovered its original payment and settled without another payment. Independent credits and all three Ledger balances matched, and the final receipt/credits survived restart. `completion-plan.md` records evidence and the observed transport-message improvement. Normal sign-out and temporary CA/adb/root/TLS/key/network cleanup completed. Hardware/mainnet passkeys and actual ambiguous settlement response recovery remain unverified.

### Follow-up actual CMC storage creation — 2026-10-08

Ordinary app/II authentication supported actual local Ledger payment, CMC canister creation, verified module installation, registration and usable image storage. One deliberately lost Ledger reply and one lost CMC reply each survived full process restart. Explicit continuation reused payment block 34, with one native Ledger submission total, and registered the created bucket. A normal image post used that bucket; actual WebP readback and screenshot display were verified. Own-post deletion was independently confirmed afterward. `completion-plan.md` records the evidence and observed transport-message improvement. Normal sign-out and temporary CA/adb/root/TLS/private-key/network cleanup completed. Hardware/mainnet authentication, actual ambiguous install/registration recovery and broader management flows remain unverified.

### Follow-up reward withdrawal and profile settings — 2026-10-08

Ordinary app/II authentication supported actual reward withdrawal from the separately funded local NNS Ledger subaccount. A deliberately withheld TAGGR response left a durable pending operation. After full process restart, explicit result checking recovered the original request without another update submission; independent Ledger reads confirmed one net 0.0099 fake-ICP payment and one fee. Normal profile edits saved name/about/links/reward mode and the user's own Principal as controller; backend reads and a restarted authenticated editor confirmed persistence. Details and evidence are in `completion-plan.md`. Hardware/mainnet passkeys and production deployment remain unverified.

### Follow-up polls, pin/hide and repost recovery — 2026-10-08

Ordinary app/official local II authentication supported named voting, reply-loss recovery without resubmission, named vote replacement and anonymous voting. Independent backend reads and restarted native UI confirm exact vote membership and anonymous non-changeability. Own-post Pin/Unpin and peer-post Hide/Unhide persisted on the backend, with authenticated restart checks. An actual Repost response was withheld after creation; the saved comment/pending record survived process restart, and result checking opened the existing post without another update. Source-card navigation opened the original and Back matched Swift's source-screen route. `completion-plan.md` records precise evidence and harness corrections; these checks do not establish production/hardware authentication.
