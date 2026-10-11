# TAGGR Android

Native Kotlin / Jetpack Compose client alongside `../ios/`, using the existing
IC canister backend and the sibling Kotlin SDK. The app now has the iOS-style
Feed / Realms / Inbox / Account navigation, Hot / Latest / Personal channel
pills, native Markdown and image viewing, public profiles and Realm detail,
post search, terms acceptance and report/block controls.

Account II/Password sign-in / encrypted restoration / sign-out, account creation, text posts and
replies, persistent drafts, pending-post result recovery, reactions, bookmarks,
follow, Realm membership and inbox read actions are connected in source.
The ordinary app has now completed private local HTTPS integration runs: II
login, encrypted session restoration after emulator restart, invitation-based
registration, text post/reply, image upload/display/edit, Follow/Mute/Unmute, Block/Unblock, reaction submission, bookmark save/remove across app process restart, Realm join/leave/create/edit, local NNS Ledger balance, ICP transfer, actual lost-response recovery/deduplicated retry credit purchase with interrupted-payment continuation, CMC storage creation with interrupted-stage continuation and own-post deletion, reward withdrawal with reply-loss recovery, profile settings restoration, named/anonymous voting and named vote replacement, Pin/Unpin, Hide/Unhide, repost creation with reply-loss recovery, persistent Inbox read/archive state, watched-thread notifications/Unwatch and sign-out. Only II's hardware passkey step
used local dummy authentication. Other authenticated feature journeys and
physical-device/mainnet passkey verification remain unproven; see
[authentication evidence](docs/auth-validation.md). No production deployment
has happened.

This is not yet an iOS feature parity release. Full feature and release readiness
is tracked in [completion tracking](docs/completion-plan.md). Unsigned APK/AAB outputs and their verified limits are recorded in [release artifact checks](docs/release-readiness.md).

## Layout

-   `app/src/main/java/org/taggr/android/data/`: backend transport and post decoding.
-   `app/src/main/java/org/taggr/android/ui/`: Compose theme.
-   `FeedViewModel.kt`: feed / conversation loading and cancellation.
-   `MainActivity.kt`: native feed and conversation screens.
-   `app/src/test/`: JSON contract, content restrictions and asynchronous state tests.
-   `app/src/androidTest/`: real device UI tests and a mainnet read-only smoke test.

Keep the app in one Gradle module until another module is necessary. Share the
backend contracts, behavior and assets with iOS; Swift source is not shared with
Kotlin.

Post translation uses Google Translate through Google's on-device ML Kit API.
Tap **Translate with Google** below a post to translate into the device language;
models are downloaded on demand over Wi-Fi. The original remains visible, with
inline results, **Hide translation**, cancellation and retry. Unchanged prose
returned by the model is labelled; matching source/device languages are labelled
**Already in device language** instead of **Translated**. Text and results
stay on-device; Google receives ML Kit performance and usage metrics. The info
button is available before translation and includes the notice, attribution and
privacy links. See [Google Translate information](https://cloud.google.com/translate)
and [ML Kit privacy information](https://developers.google.com/ml-kit/terms).
`RealPostTranslationUITest` uses the actual model and verifies cached translation
with Wi-Fi/mobile data disabled; its TAGGR posts come from an injected repository.

## Development

Open this `android/` directory in Android Studio. Its bundled JDK is sufficient.
This project pins AGP 9.2.1, Gradle 9.4.1, Kotlin / Compose compiler 2.2.10 and
Compose BOM 2026.09.00. Compile SDK is 37.0; target SDK is 36; minimum SDK is 28
(Android 9). Android 16 has been exercised; Android 17 / API 37.0 is also
installed for browser authentication capability and focused UI checks.

Install SDK Platform 37.0, Build Tools 36.0.0 and Platform Tools using the Studio
SDK Manager or the official Android CLI. Create a Pixel ARM64 AVD on Apple
Silicon. Google Play images include Chrome and are useful for the later native
authentication milestone.

On this Mac, Android Studio Rabbit 1 (2026.2.1.8), Android Emulator 37.2.12 and
`TAGGR_Pixel_9_API_36` are installed. Platform Tools 37.0.1 crashed while starting
ADB on macOS 27.0.1; the SDK uses the separately verified working 36.0.2 instead.
The newer tools are preserved under `~/Library/Android/taggr-tool-backups/`.

For terminal builds on this Mac:

Builds default to a 1536 MiB heap, two workers, no parallel projects and no
persistent daemon. Run one heavy verification at a time; see
[development resource limits](docs/development-resources.md).

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
```

Build the debug and instrumentation APKs first, then use the bounded emulator
runner from the repository root. It shuts down its owned AVD after the check:

```sh
python3 android/scripts/check-emulator.py \
    --avd TAGGR_Auth_Pixel_9_API_37 \
    --classes org.taggr.android.NormalAppNavigationTest,org.taggr.android.ProfileStatisticsNativeReadTest
```

`TaggrNetworkTest` calls mainnet queries only and requires internet access.
`NormalAppNavigationTest` and the native public-post recovery cases use the actual
MainActivity and public reads; many component tests use injected repositories.
These public-read batches do not submit posts or transfers. Build output, local
SDK paths and signing keys are ignored by Git.

Finish Gradle/Kotlin builds before starting an emulator. The runner rejects a
live build and monitors its owned AVD throughout the check and shutdown. It stops
that AVD if emulator RSS exceeds 6 GiB, aggregate Codex RSS grows more than
1,024 MiB, host free memory falls below 15%, a build starts or the time limit is
reached. It does not terminate Codex. Logs include actual guest API, per-process
Codex RSS and terminal shutdown status. RSS sums are not unique physical usage;
passing a bounded check does not establish that a long-running leak is fixed.

Dedicated `TAGGR_Compat_Pixel_3_API_28` and `TAGGR_Compat_Pixel_6_API_33` AVDs cover
the minimum supported Android 9 and Android 13 respectively. Current
compatibility evidence and remaining gaps are in
[current-completion-audit.md](docs/current-completion-audit.md); use the same
runner with that AVD name to repeat selected checks.

## IC transport

The Swift app's `ICNativeClient` is not usable by the JVM. This client resolves
our sibling [IC4J fork](https://github.com/humandebri/ic4j-agent) through the
Gradle composite builds at `../../ic4j-agent` and `../../ic4j-agent/android`,
using `org.ic4j:ic4j-agent-android:0.9.0-native-SNAPSHOT`.
Clone that repository next to `taggr` before building Android. The fork uses
API v3 for queries/read_state, API v4 for calls, a pinned mainnet root key, and
verified query signatures. It supplies Android-compatible Ed25519 support
without registering an application-level security provider.

TAGGR's legacy `hot_posts`, `last_posts` and `posts` methods expect raw JSON
arguments and return `[post, meta]` envelopes, so these methods do not use Candid
encoding. See `../../ic4j-agent/NATIVE_CLIENT_PARITY.md` for the library feature
matrix, Kotlin suspend APIs, shared Swift interoperability fixtures and remaining
callback/app integration work. Kotlin uses ktfmt's
Kotlin style; the repository's `make format` also runs normally.

## Authentication and callback hosting

MainActivity registers the Kotlin SDK's InternetIdentityAuthenticator before the
activity starts. AccountViewModel restores and saves validated sessions using
Android Keystore, keeps the same production derivation origin as iOS, and
connects the session to the TAGGR queries/updates. Debug-only Gradle overrides
support isolated local canister validation; release builds ignore them.

The backend source includes `/android-auth-callback` and its canonical
`<canister-id>.icp0.io` declaration alongside the existing iOS callback. The
certified `/.well-known/assetlinks.json` starts with no trusted signing identity
(`[]`). Prepare it using `node android/scripts/prepare-app-links.mjs <actual-app-signing-SHA256>`
after selecting the release/Play signing certificate. Review and deploy these
assets before claiming production sign-in works. Debug signing fingerprints
must not be trusted on the production callback host.

The earlier SDK-only real Chrome test and its precise limits are documented in
[auth-validation.md](docs/auth-validation.md). Native app flow verification is
tracked separately in [completion-plan.md](docs/completion-plan.md).

The bootstrap application ID remains `org.taggr.android`. No push notifications
are planned in the current iOS parity scope.

Password sign-in matches the Web/Swift Ed25519 derivation (15,000 SHA-256 rounds with exact UTF-8 input) and requires an existing TAGGR user before saving. The root key/password are not retained in the session store; a fresh 30-day delegated session is encrypted with Android Keystore. Local normal-app login, unknown-account refusal, process-restart restoration, signed posting and sign-out have been verified with a public disposable test vector. Actual production credentials and physical devices remain unverified.
