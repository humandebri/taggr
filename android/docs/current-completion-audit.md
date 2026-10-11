# Current completion audit — 2026-10-08

The full Android goal remains unproven. The Swift requirements and implemented
views are the reference; passing selected tests does not establish every flow.

## Evidence inspected now

-   `ios/docs/swift_requirements.md`: native browsing/auth/account/safety/wallet scope;
    push notifications are excluded from the first Swift release.
-   iOS PostInteractionViews shows received-tip event counts. Backend
    `src/backend/env/post.rs` declares `Vec<(UserId, u64)>`; `UserId` is u64.
    Android now decodes/counts valid events and renders tips in its compact
    engagement strip and account-free post statistics. It does not sum money or
    add a payment action. Repeated tips by one user remain separate events.
-   Tip-count checkpoint Debug/Release: 228 JVM cases each, zero failures/errors; both Lint tasks,
    debug/test APK and unsigned release APK/AAB succeed. Earlier selected API 37 UI
    interval is emulator-check-20261008-113626: 30 cases pass, including the new
    decoded-tip-count case at 1.5× text scale, live count updates, zero omission and
    absence of a click action. See tip-count-labelled-final-build.log and
    tip-count-release-artifact-audit.json under ignored .build/android.
-   The earlier private-app-auth/inline-normal-readback.json is an actual backend
    readback: parent 3 lists reply 4; reply 4 has parent 3, author 2 and body
    Local inline reply kept across restart. This proves that earlier local
    authenticated reply, not every write/recovery path.
-   Production GET results are retained in completion-auth-hosting-check.json:
    /.well-known/assetlinks.json returns HTTP 200 **text/html**, the SPA;
    /.well-known/ii-auth-callbacks returns JSON declaring only the iOS callback.
    Source assetlinks.json is still [], and no release signer has been selected.
    Existing assets.rs prepares a certified Android terminal callback and both
    callback declarations; prepare-app-links.mjs prepares the actual certificate
    declaration. Prepared source is not deployed configuration.
-   `adb devices -l` currently lists no connected device. All owned emulator
    intervals reached normal terminal state; no physical-device evidence was added.

## Ordinary-app edit/delete recovery

The private local run used a disposable test account and the ordinary Debug app.
A loopback proxy dropped each call response only after receiving the backend
response. Backend readback independently confirmed the edit (one history patch),
then deletion (empty body, two retained history hashes). After a full process
restart for each operation, **Check post result** confirmed the original request;
the proxy observed exactly one edit_post and one delete_post submission across
both restarts. Pending Save/Delete buttons were disabled. This closes this local
integration gap, without establishing production or every other recovery path.

Evidence under ignored .build/android/private-app-auth: editrecovery-result.json,
editrecovery-calls.jsonl, separate dropped-edit/delete response records, backend
posts-edited/deleted readbacks and outcome/restored/confirmed UI XML. The typed
fixture ended as “Local edit recovery committed. original.”; assertions use the
actual recorded body. A helper assumed every .bin file was an identity file;
remaining files after sign-out are only Google's cached translation models.
Guest state persisted after restart. This verification required no app source fix.

The bounded emulator-check-20261008-115406 interval ended normally with no guard
trigger. Emulator peak RSS was 5,037 MiB, below the 6 GiB stop limit; the emulator
used a 2 GiB guest allocation and builds ran only while it was stopped. Host free
memory stayed at least 61%. This short observation does not prove absence of a
long-running leak. The owned local network/TLS server, disposable keys, emulator
CA, port reverses and authentication were cleaned up afterward.

## Video restoration

The ordinary TaggrApp fixture reproduced a visible video with no owned WebView
after saved-state restoration. Diagnostic logs show the Compose rectangle
(42,546)–(1038,1106) while the host Android View height is zero. Visibility now
uses the clipped window rectangle directly, as defined by
[Android LayoutCoordinates](https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/LayoutCoordinates).
Temporary production logs were removed. VideoNavigationUITest checks actual
playback time advancing, real Activity background pause/manual resume, saved-state
restoration without an extra scroll, fresh player ownership, Back and tab disposal.
The fixture repository is not a discovered mainnet post and composition saved-state
restoration is not full process-death verification.

Final Debug/Release: 228 JVM cases each, both Lint tasks and all public app/test/
unsigned release outputs pass (video-restoration-final-build.log). Four focused
device cases pass in emulator-check-20261008-121836, including actual fullscreen
and hidden-post controls; peak RSS 5,111 MiB, no guard, normal exit. The earlier
30-device-case batch is not a rerun here. Current release artifact evidence is
video-restoration-release-artifact-audit.json. Remaining video gaps include full
process/orientation restoration, playback-position preservation, arbitrary videos
and the actual video-upload/auth flow where configured on iOS.

## YouTube upload foundation

Swift YouTubeUpload.swift and YouTubeUploadView.swift contain upload authorization,
metadata, persistent jobs/background continuation and draft insertion. Android
previously contained only playback. New YouTubeUploads.kt provides metadata
validation, trusted session URLs, cancellable HTTP requests, streaming 4 MiB chunks
with a 64 KiB read buffer, status decoding and explicit status queries after lost
responses. This foundation is not yet connected to the app. Google authorization,
owner/channel-bound durable jobs, background execution, video selection/metadata
UI, cancellation/revoke and draft insertion remain required. OAuth project/signing
configuration has been requested; independent implementation can proceed meanwhile.

Eight protocol/cancellation JVM cases pass; both variants now pass 236 cases, both
Lint tasks and all public outputs. One Android protocol case passes in
emulator-check-20261008-122744, proving Android Unicode grapheme validation and
resumed byte-tail requests with scripted responses, not a real YouTube upload.
Peak RSS 4,570 MiB, no guard, normal exit. See youtube-upload.md and
youtube-upload-protocol-release-artifact-audit.json.

## Saved upload jobs

YouTubeUploadJob/Codec and YouTubeUploadJobStore now implement target binding,
private video import, bounded hashing, encrypted atomic metadata and retained
completed/cancelled receipts with source cleanup. Both variants pass 241 JVM cases
and Lint, and all public artifacts build. Four focused Android cases pass in
emulator-check-20261008-123959 (three actual Keystore/store cases and one scripted
protocol case); peak RSS 4,606 MiB, no guard, normal exit. Current artifact evidence
is youtube-upload-store-release-artifact-audit.json.

The store remains independent from auth/composer/background dispatch. Restoring
through a new store instance does not establish real app process recovery. Next
implementation must connect authorization, channel identity, persisted request
state, background continuation and insertion into the original retained draft.

## Google authorization adapter

The official play-services-auth 22.0.0 dependency and GoogleYouTubeAuth adapter
are added. Partial grants and mismatched account/channel do not provide upload
access. Cache clearing/revoke requests are scoped to the selected Google account.
The additional email scope identifies the account for refresh/revoke without a
legacy Google sign-in flow. Actual app UI and worker integration remain required.
The real Google consent/API path is not verified; Debug certificate registration
information has been prepared in google-oauth-registration.md.

Both variants pass 243 JVM cases, both Lint tasks and public artifact assembly.
Seven focused Android cases pass in emulator-check-20261008-125224: actual SDK
classes with scripted AuthorizationClient/HTTP plus prior store/protocol cases.
Peak RSS 3,945 MiB, no guard, normal exit. Current artifacts are recorded in
youtube-auth-release-artifact-audit.json. No Google account action/Cloud mutation
or mainnet write, signing/distribution or deployment occurred.

## Remaining priorities

1. Resolve the other recorded verification gaps, including historical storage
   migration and ambiguous install/registration, historical/encrypted content,
   and video/fullscreen/background restoration. Keep the full original scope.
2. Review remaining iOS UI and supported-flow differences; metadata counts alone
   do not establish complete UI parity. Translation is in-body rather than the
   iOS icon strip, and Google's actual model sometimes retains original prose;
   the app labels that outcome rather than claiming perfect translation quality.
3. Select the actual release/Play signing identity, generate/review its App Links
   JSON, then obtain approval for any production deployment. Publish valid JSON
   and the Android II callback declaration/terminal. Verify ordinary production
   II sign-in and physical-device behavior with the user's authorized identity.
   These are pending user/deployment gates, not proof that an emulator cannot
   use passkeys. No mainnet writes or deployment occurred in this audit.
4. Publication requires SDK metrics/privacy/store descriptions to match the app,
   final release signing and a complete requirement-by-requirement review.

The completion-plan's historical verification table and logs remain useful
pointers, but rows marked connected/implemented and unsigned artifacts are not a
substitute for missing integration, real-account or device evidence.

## Persisted upload dispatch — 2026-10-08

YouTubeUploadRunner connects the saved job to one HTTP dispatch per step. It saves
CHECKING before sending bytes, checks the owner/network/canister/channel/draft
binding, and uses an expected-record comparison when saving. Response loss or
cancellation leaves a recoverable status-query state. Authorization failures,
expired sessions, permanent HTTP failures and bounded retry delays have distinct
outcomes. A caller still must serialize execution and honor the returned delay;
this runner is not a background scheduler.

Five new JVM cases cover lost completion replies across new runner instances,
pre-dispatch save failure and target mismatch, cancellation, bounded no-progress
retries and authorization/session expiry. Debug and Release each pass 248 cases,
both Lint tasks and all app/test/unsigned Release APK/AAB assembly. Eight focused
Android cases pass in emulator-check-20261008-130718, including a real Keystore
record reopened through a new store/runner after a scripted accepted upload with
its completion reply lost. Only one data request occurs; recovery queries the
original session, saves the completed receipt and removes the source. A stale
record update is rejected. This proves store-instance recovery, not app process
or background worker recovery, and uses scripted HTTP rather than real Google
uploading. Peak emulator-tree RSS is 4,612 MiB; no guard fired and it exited
normally. Gradle and emulator execution did not overlap.

Evidence: youtube-runner-final-build.log, youtube-runner-device.log and
youtube-runner-release-artifact-audit.json under ignored .build/android.
Foreground consent, video/metadata/progress/cancel UI, serialized scheduling,
original-draft URL insertion and real-account verification remain to be connected.

## Foreground upload sheet — 2026-10-08

PostComposer now opens YouTubeUploadScreen for new posts, replies and edits.
The sheet connects Google foreground authorization/consent, channel validation,
video-only system selection, app-private import and the persisted upload runner.
It shows title/description limits, unlisted/public/private selection, an explicit
made-for-kids choice, synthetic-media declaration, terms/guidelines confirmation,
acknowledged-byte progress, retry and confirmed cancellation. Dispatch is
serialized by a process-wide coroutine mutex. Closing cancels its owned work;
reopening the original draft and connecting the same channel reloads the saved
job and allows explicit resumption. Tokens remain in memory. Import opens and
hands its stream to the owning store within the same IO context.

Completed jobs can be inserted into the original draft. AccountViewModel checks
owner/network/canister and atomically commits the URL plus a job receipt marker
so retrying insertion does not append it twice. This insertion path and actual
consent/video import/upload through the ordinary signed-in composer still need
end-to-end verification. There is no verified real Google upload. Background
service/worker continuation, process-death restoration of the whole workflow,
video preview, disconnect/revoke UI, unreadable-record discard and the repost
composer's attachment route remain required for full iOS parity.

Debug and Release each pass 248 JVM cases, both Lint tasks and all app/test/
unsigned Release APK/AAB assembly (youtube-sheet-final-build.log). Eleven focused
Android cases pass in emulator-check-20261008-131629: three new UI cases for the
ordinary sheet's open/close behavior without initiating Google consent, required
account/video/audience/consent and busy gates, default unlisted metadata, Unicode
and UTF-8 limits; plus the existing eight auth/store/protocol cases. The actual
sheet screenshot is ui-captures/youtube-upload-sheet.png and was visually checked.
These isolated cases do not establish the full ordinary-app upload workflow.
Peak emulator-tree RSS was 4,942 MiB, no guard, normal exit; build and emulator
intervals did not overlap. Current unsigned artifact evidence is
youtube-sheet-release-artifact-audit.json under
ignored .build/android. No real Google action, mainnet write, deployment,
release signing/distribution or mutable Git operation occurred.

## Completed-video insertion and disconnect — 2026-10-08

The production draft insertion path now checks the actual composer slot and full
job target, saves the URL with its receipt, and preserves existing body/realm.
The upload sheet offers confirmed Google revoke while retaining saved progress.
All 15 selected Android cases pass in emulator-check-20261008-132422, including
real sheet/Keystore/SharedPreferences with scripted Google identity replies;
peak RSS 4,953 MiB, no guard, normal exit. Debug/Release each pass 248 JVM cases,
both Lint tasks and all public artifacts. Current evidence is
youtube-insertion-release-artifact-audit.json. Detailed scope and remaining
background/preview/reset/receipt-cleanup/repost/real-account gaps are recorded in
[youtube-upload.md](youtube-upload.md). The tests do not prove ordinary signed-in
app uploads or full process recovery. No real Google account action, mainnet
write, signing/distribution, deployment or mutable Git command occurred.

## Confirmed upload reset and receipt cleanup — 2026-10-08

Restoration failures now block new selection until retry or an explicit local
reset confirmation. Reset rejects changed confirmations and unexpected files;
it removes only its recognized private upload files/key. Draft discard cleans
that draft's insertion markers. All 20 selected Android cases pass in
emulator-check-20261008-133106 (peak RSS 4,960 MiB, no guard, normal exit), including
real Keystore/files and confirmation UI with scripted Google identity replies.
Debug/Release each pass 248 JVM cases, both Lint tasks and public artifact assembly.
Current evidence is youtube-reset-release-artifact-audit.json. Detailed reset
scope and remaining full-app/background/preview/repost/real-account gaps are in
[youtube-upload.md](youtube-upload.md). No real Google action, mainnet write,
deployment, release signing/distribution or mutable Git operation occurred.

## Selected local video preview — 2026-10-08

The upload form now includes a native local-URI video preview with manual
Play/Pause, lifecycle pause and release on selection replacement or close.
All 22 selected Android cases pass in emulator-check-20261008-134005, including
actual codec-generated MP4 playback in the production form and real Activity
background/return behavior. Peak RSS 4,637 MiB, no guard, normal exit. Debug/Release
each pass 248 JVM cases, both Lint tasks and all public artifacts; final test
assembly/Lint also pass. Current evidence is video-preview-release-artifact-audit.json.
The screenshot and exact coverage/remaining seek, picker, full-app/background/
repost/real-account requirements are described in [youtube-upload.md](youtube-upload.md).
No real Google action, mainnet write, deployment, release signing/distribution or
mutable Git operation occurred. A short bounded run does not prove that long-session
memory leaks are absent.

## Video seek and saved preview position — 2026-10-08

The native preview now has an accessible seek slider and time display. Same-URI
saved-composition restoration retains position without autoplay; changing URI
starts a different player near zero. All 23 selected Android cases pass in
emulator-check-20261008-135158 (peak RSS 5,047 MiB, no guard, normal exit).
The initial switch check was repaired to wait for the new player rather than
reading the old prepared view; no app workaround was added. Debug/Release each
pass 248 JVM cases, both Lint tasks and public assembly; final test assembly/Lint
also pass. Current evidence is video-seek-release-artifact-audit.json. Exact
coverage and remaining full-process/picker/background/repost/real-account gaps
are in [youtube-upload.md](youtube-upload.md). The full completion goal remains
unproven. No real Google action, mainnet write, deployment, release signing/
distribution or mutable Git operation occurred.

## Account-bound execution preparation — 2026-10-08

Schema 2 preserves the original Google email inside encrypted job metadata,
supports unbound schema-1 migration through foreground authorization, and rejects
re-binding. The foreground sheet uses a shared loop that checks TAGGR ownership
before each dispatch and preserves confirmed progress on account change.
Debug/Release each pass 252 JVM cases, both Lint tasks and all public artifacts.
All 24 selected Android cases pass in emulator-check-20261008-140120 (peak RSS
5,028 MiB, no guard, normal exit), including the new actual Keystore account case.
Current evidence is youtube-execution-release-artifact-audit.json. The planned
UIDT JobService, notification stop control and older-Android foreground fallback
remain to be implemented; this is not background-upload completion. Details and
the original remaining scope are in [youtube-upload.md](youtube-upload.md).
No real Google action, mainnet write, deployment, signing/distribution or mutable
Git operation occurred.

## OS transfer service integration — 2026-10-08

The upload sheet now schedules API-34+ UIDT work or a native foreground fallback,
observes encrypted progress, and coordinates cancel/disconnect with background
execution. Nonexported services/receiver, notifications/Pause, ownership/session
checks and background consent-required handling are implemented. All 27 selected
Android cases pass in emulator-check-20261008-141837 (peak RSS 4,874 MiB, no guard,
normal exit), including real UIDT and foreground-service startup/guarded stop on
API 37, preserved saved data and scheduling-extras privacy. Debug/Release each
pass 252 JVM cases, both Lint tasks and public assembly; final test assembly/Lint
also pass. Current evidence is youtube-background-release-artifact-audit.json.
These tests do not prove authenticated background byte transfer, active notification
Pause, process recovery, permission denial or older Android/long screen-off behavior.
Exact follow-up, including fallback wake/time budgets and the original full scope,
is recorded in [youtube-upload.md](youtube-upload.md). No real Google action,
mainnet write, deployment, signing/distribution or mutable Git operation occurred.

## Foreground fallback CPU ownership — 2026-10-08

The fallback now acquires a bounded partial CPU lock for source validation,
account-bound authorization and each dispatch, releases it before retry backoff,
and pauses after thirty minutes without discarding its saved progress. API 34+
user-initiated jobs do not use the manual lock. The old-Android upload sheet
explains the resume requirement. Actual OS lock observations cover success,
failure, cancellation and timeout. All 252 JVM cases in each variant and both
Lint/build variants pass; 29 selected API 37 device cases pass in
`emulator-check-20261008-143312` (peak emulator RSS 4,920 MiB, no guard, normal exit).
See `youtube-upload.md` for exact evidence and remaining old-device/authenticated
screen-off/process-restart gaps. This is not full iOS feature parity or production
readiness.

## Corrupt local preview recovery — 2026-10-08

An actual corrupt local MP4 exposed unreleased preview ownership after the error
message. The error callback now releases immediately, disables playback/seek and
permits a valid URI replacement to play. The new device regression failed before
the fix in emulator-check-20261008-143649 and passes with six existing preview/form
cases in emulator-check-20261008-143908. Both Debug/Release variants pass 252 JVM
cases, Lint and all public artifacts; the final unsigned artifact audit is
preview-failure-release-artifact-audit.json. This does not prove all picker grant
or full-process restoration cases. Current iOS RepostSheet has no attachment bar;
adding a repost video button is not required by that UI reference. See
youtube-upload.md for evidence and remaining upload gates.

## Account YouTube management — 2026-10-08

Current iOS SettingsView includes explicit YouTube connect/channel/disconnect
controls even before TAGGR sign-in. Android Account now provides these controls,
confirmation before revoke, retained saved upload progress and a shared in-memory
connection for the ordinary new/reply/edit composer. Session install clears the
selection on owner change/sign-out/expiry; asynchronous authorization is guarded
by the initiating owner. Saved tokens are not introduced.

Both variants pass 252 JVM cases and Lint; app/test/unsigned release builds pass.
Fifteen selected device cases pass in emulator-check-20261008-145141, including
the actual ordinary guest MainActivity route and scripted SDK panel/shared-receipt
flows. Normal signed-in MainActivity connection sharing and expiry, real Google
consent/revoke/upload and full-process connection recovery are not established by
these selected fixtures. Exact evidence and remaining gates are in youtube-upload.md
and youtube-account-release-artifact-audit.json. The full original goal remains
unproven.

## Restricted-post reference audit and deleted hashes — 2026-10-08

The current Swift requirement document explicitly excludes push notifications and
auction/exchange actions from its native release. Android's auction/token links
route to Account without exposing a bidding UI. Swift contentRestriction and the
actual FeedViews safety notice keep encrypted, moderated, deleted and NSFW bodies
unavailable; there is no decryption screen to replicate. Historical/edit wire
verification remains distinct from inventing a history/decryption UI absent from
that reference.

One concrete difference was deleted-post hash prefixes: Swift displays the first
16 characters of every retained hash; Android previously discarded this display
data. TaggrPost now retains textual hashes and PostContent displays selectable
16-character prefixes only for its deleted notice. Stronger encryption/moderation
restrictions suppress the hashes too. Backend Post::delete stores SHA-256 hex
strings, so these prefixes match Swift's character prefixes. Restricted body
rendering remains unreachable, including image/video body renderers.

Both variants pass 253 JVM cases, both Lint tasks and all app/test/unsigned release
builds (`deleted-hashes-build.log`); Cargo formatting/check also passes. Three
focused Android hidden/restricted-content cases pass in
emulator-check-20261008-145830, including a backend-envelope decoder fixture with
retained secret text/image/video references and two hashes, exact displayed
prefixes, no Show/video body control, and encryption/moderation priority. These
fixtures do not establish every historic canister wire variant or a new live
backend deletion. Earlier actual local edit/delete response-loss verification
remains separate evidence.

Emulator peak RSS was 4,888 MiB, aggregate Codex baseline/peak 2,434/2,562 MiB,
no guard fired, normal exit. Current unsigned artifacts and public manifest/config
checks are in deleted-hashes-release-artifact-audit.json. This short run is not
proof of long-session leak resolution. Production callback/signing/physical auth,
real Google configuration/transfer and the other documented native integration
verification gaps still prevent declaring the full goal complete.

## Draft-specific video/post sequencing — 2026-10-08

Active/queued video sending now blocks only its own draft's Post/Submit/Save and
saved-draft discard, matching Swift's active-upload canSubmit check. The ViewModel
also checks before posting and clearing a draft. Network/owner/canister/slot
matching includes pending UIDT extras and the fallback start interval. Stale work
completion does not erase newer ownership; failed start removes queued ownership.

All 253 JVM cases per variant, Lint and public artifacts pass. Twelve focused
Android cases pass on the final source in emulator-check-20261008-151700, covering
real OS target ownership, production submit-control refusal/re-enable, replacement
ownership, failed fallback start and retained reply/completion flows. This proves
selected guards; it does not establish a real authenticated backend refusal or
upload/post sequence. Exact evidence is in youtube-upload.md and the
video-composer-guard-release-artifact-audit.json checkpoint. Automatic insertion was still open at this checkpoint; the subsequent section
records its implementation and selected owner-switch verification. Full process
restoration remains open alongside the other full-goal requirements. No signing/deployment/real Google
account action occurred.

## Automatic completed-video insertion — 2026-10-08

The visible composer now polls its own completed video receipt while STARTED and
inserts the URL through the existing atomic draft/receipt commit before clearing
the expected job snapshot. It uses the latest saved body, retains failed
insertions for retry and does not acknowledge another owner, Google account,
network, canister or draft. A stale acknowledgement cannot erase a replacement
upload. The initial completion check disables submission; polling uses the shared
nonblocking dispatch lock and pauses while the upload dialog or account action is
active. Editor state, image picker callbacks and import scopes are keyed by owner.
The consumer also follows the current AccountViewModel when its instance changes.

The 19-case device checkpoint emulator-check-20261008-153318 passed actual
Keystore insertion-before-acknowledgement, failed insertion retention,
owner/account/draft refusal and stale-clear replacement protection, together with
existing store, inline reply, submit guard and completion UI cases. Emulator peak
RSS was 4,998 MiB, Codex baseline/peak 3,122/3,170 MiB; no guard fired and the owned
emulator exited normally.

The final build passes 253 JVM cases per variant, both Lint tasks, Debug/test APK
and unsigned release APK/AAB. One additional device case passes in
emulator-check-20261008-154528 using real SDK self-delegated identities, actual
Keystore session restoration, production AccountViewModels and PostComposer.
It verifies visible automatic insertion, cleared completion record, switching to
a separate owner's editor without leaking the URL, and returning without a
duplicate. The second owner edits only its own draft. This is a same-composition
ViewModel/owner switch, not a real II sign-in, same-ViewModel sign-out or full app
process restart. Public IC reads are permitted; no publication or other backend
mutation is attempted. The channel/access and completed-upload receipt are
synthetic fixtures; no Google consent or transfer is claimed.

Final emulator peak RSS was 4,240 MiB, Codex baseline/peak 3,443/3,450 MiB; no guard
fired, normal exit. Gradle and emulator did not overlap. Short checks do not prove
long-session memory leak resolution. Evidence: video-auto-completion-final-build.log,
video-auto-completion-device.log, video-auto-completion-composer-device.log and
video-auto-completion-release-artifact-audit.json under .build/android. Cargo
format/check passed before the final account-key change (which affects Kotlin only).

After full process death, Google connection is intentionally memory-only and
requires explicit reconnect to identify the original channel before automatically
consuming its receipt. Real Google registration/consent/background upload,
full-process/orientation restoration, older-device verification and production
callback/signing/physical auth remain open. No signing or deployment occurred.

## Live composer session expiry — 2026-10-08

A new device test exercises the production AccountViewModel and PostComposer with
a real SDK self-delegation expiring after 45 seconds, restored through the actual
Keystore. While the same ViewModel and editor remain open, the real session timer
detaches the identity, clears memory-only Google access and removes the old owner's
visible text. It preserves that owner's saved draft and scoped resumable-upload
record, including its original Google email, session URL and acknowledged byte
count; saved credentials are cleared. No backend mutation, real II sign-in or
Google authorization/transfer is attempted. The channel and partial-upload record
are synthetic fixtures without an active dispatcher. This proves live timer/editor
expiry and retained records, not expiry during an actual network upload.

The expiry test and automatic insertion/owner-switch test both pass in
emulator-check-20261008-155239 (2 cases, 54.656 seconds of instrumentation).
Memory guard did not fire: emulator peak RSS 4,812 MiB; aggregate Codex
baseline/peak 3,256/3,295 MiB. Owned emulator exit was normal. Gradle and emulator
intervals do not overlap. Evidence is composer-expiry-build.log,
composer-expiry-device.log and that run's tests.log/summary.json under
.build/android. The first build exposed an invalid test-only phase name; the
fixture was corrected to the actual CHECKING state with a resumable URL before
device execution. Final test APK build and Debug Lint pass; production source and
unsigned release hashes are unchanged from the previous automatic-insertion
checkpoint. This is additional evidence rather than a production behavior change.

Real mainnet/physical-device II, actual Google registration and transfer, full app
process/orientation recovery, older-device behavior and long-session host memory
stability remain unproven. No signing, deployment or distribution occurred.

## Denied video-provider recovery — 2026-10-08

Actual VideoView/ContentResolver operations now have device evidence for a Binder
provider that throws SecurityException on open. The preview reports unavailability,
releases its owned media player, removes play controls and can play a valid local
replacement. A separate production YouTubeUploadScreen case uses a scripted
ActivityResultRegistry to deliver that content URI and synthetic already-connected
Google access. After Upload is pressed, the actual source open is rejected; title,
description, audience and terms consent remain intact. No durable job or dispatcher
is created, the picker can be opened again and Close works. This is a real Binder
permission error with a test provider and scripted picker result, not a real system
picker grant being revoked or a real Google upload. The source handles the error
without a new production behavior patch. Full parent-composer draft preservation
and real picker grant persistence are separate requirements.

Final evidence: video-permission-sheet-build.log, video-permission-sheet-device.log
and emulator-check-20261008-160536/tests.log / summary.json under .build/android.
All 9 selected device cases pass (5 preview, 3 form, 1 full upload sheet), with
21.342 seconds of instrumentation. Peak emulator RSS 4,989 MiB; aggregate Codex
baseline/peak 3,257/3,299 MiB. No guard fired and the owned emulator exited normally.
Test APK build and Debug Lint pass. Only test and runner code changed, so production
JVM counts and release hashes remain at the prior automatic-insertion checkpoint.
The test provider's class/authority are absent from release APK/AAB DEX and manifests.
No real Google consent, transfer, publication, signing or deployment occurred.

The initial provider was Kotlin in the independent test APK process, where the
target APK's Kotlin runtime is unavailable. Crash-buffer evidence showed
NoClassDefFoundError for kotlin.jvm.internal.Intrinsics. That failed run
(emulator-check-20261008-155730) hit the 240-second time guard and shut down normally;
peak RSS 4,814 MiB, Codex 3,249/3,279 MiB. It is not passing app evidence. The
provider fixture was changed to platform-only Java, without adding dependencies
or changing Kotlin app code. The next 8-case checkpoint passed in
emulator-check-20261008-160246 before the additional full-sheet case. Timeout
handling in check-emulator.py now preserves partial instrumentation output before
cleanup; Python compilation and the three process-attribution tests pass. The new
timeout-output branch itself has not been exercised by a subsequent timeout.

Physical/real-picker grant lifetime, full process/orientation restoration,
long authenticated background transfer, older devices, production auth/signing
and long-session host memory stability remain open. Short passing runs do not
establish a long-session leak fix.

The upload-sheet case was then strengthened by selecting Private before source
open and asserting Private remains selected after failure. Final focused evidence:
video-permission-visibility-build.log, video-permission-visibility-final-device.log
and emulator-check-20261008-161123 (1 case passed). The preceding 9-case checkpoint
remains the broad preview/form run; this final case adds changed-visibility
retention. Peak emulator RSS 4,703 MiB; Codex baseline/peak 3,589/3,593 MiB; no guard,
normal exit. Cargo format/check also pass (video-permission-cargo-check.log).

An intervening attempt emulator-check-20261008-160836 stopped before instrumentation:
Codex aggregate RSS grew from 4,547 to 5,652 MiB in 1.7 seconds, exceeding the
unchanged 1,024 MiB growth limit. Emulator peak was only 371 MiB and shutdown was
normal. This is guard evidence, not an app test failure or a memory-leak diagnosis.
After stopping, four short process snapshots were stable around 3,807 MiB; the
largest current process was the UI Renderer around 1,902 MiB. That post-event
snapshot cannot identify which process caused the transient rise. The runner now
records codex-baseline.json and per-PID RSS/name values in each memory.jsonl sample
without command arguments, so future growth can be attributed. Existing three
attribution tests and Python compilation pass. No thresholds were raised and no
Codex process was killed. The successful retry occurred after terminal shutdown
and observed stability; it does not establish long-session leak resolution.

## Normal-app public video configuration recreation — 2026-10-08

A new test uses actual MainActivity, its production ViewModels and anonymous,
certificate-verified public TAGGR reads. It selects a visible video post from
search results (final run: post 1460571, video wmxU6jCMRhY), opens it through the
ordinary search row, requests landscape then portrait through the Activity,
checks the actual OS resource orientation and retains Conversation. Each old
VideoWebView is released; a distinct current WebView loads the same public embed
URL to progress 100. Back releases the final WebView and returns to the saved
post-ID search query with no attached video views. No repository/body/player
fixture is substituted. This proves this public native route and two real
configuration recreations, not playback position, full process death, Google
upload restoration, every video or physical-device behavior. The video is not
played by this test.

The new case and existing native public search/recreation/system-Back case pass
together on final test source: emulator-check-20261008-162736, 2 cases, 22.444
seconds of instrumentation. Emulator peak RSS 4,443 MiB; aggregate Codex
baseline/peak 2,953/2,958 MiB; no guard, normal exit. Gradle and emulator did not
overlap. Evidence: video-activity-rotation-final-build.log,
video-activity-rotation-final-device.log and the run's tests.log/summary.json under
.build/android. Test APK build, Debug Lint and Cargo format/check pass
(video-activity-rotation-cargo-check.log). Only test code changed, so production
source, release artifacts and 253-per-variant JVM checkpoint are unchanged; the
full JVM/release matrix was not rerun for these test-only edits.

The first new-case attempt timed out because its polling caught a WebView getter
exception outside the UI thread. Diagnostic run emulator-check-20261008-162055
confirmed WebView.checkThread/getProgress on the instrumentation thread. All
WebView getter observations were moved onto scenario.onActivity, and polling no
longer hides those exceptions. In the next combined run the new case passed,
but the existing search case asserted Conversation visibility before its layout
was displayed. It now waits for actual display before the same assertion. The
initial and intermediate failing batches are diagnostic evidence, not passing
app behavior; no speculative production fix was applied. All owned emulators
were shut down normally. Long-session leak resolution remains unproven.

Full process restoration, selected-upload/picker grant restoration, live
Google transfer, older Android devices and production callback/signing/physical
II remain separate open requirements. No authentication, account mutation,
signing, deployment or distribution occurred.

## Normal app killed-process conversation recovery — 2026-10-08

A host-driven guest UI check exposed a real process-restoration defect. After a
public video conversation was backgrounded, am kill terminated the app, and a
URL-free ordinary launcher intent raised the same saved task. The old PID 2342
became 3809 in task 1028, but the UI returned to Hot Feed: the focused post existed
only in FeedViewModel memory. Failure evidence: emulator-check-20261008-163906
process-recovery.json, activity-before/after.txt and conversation-after.xml.

FeedViewModel now saves only the focused post ID through SavedStateHandle and
reloads current post/thread data after account restoration completes. MainActivity
supplies the handle through its native CreationExtras factory. Closing a
conversation or discarding account caches clears the saved focus; duplicate
restore calls do not duplicate an active read. Root owner checks wait until
session restoration resolves and discard focus when the owner changes. No post
body or WebView is serialized and no mutation is replayed.

The same host-driven normal-app check passes on the fixed source in
emulator-check-20261008-164846: PID 2498 terminates, PID 3905 restores the same
ActivityRecord/task 1029, Conversation and an attached WebView return, and Back
returns to the saved post-ID search. The task is launched without replaying its
post/search URL. Current public post 1460571 is used; no repository, post body or
player fixture is substituted. Accessibility snapshots establish the visible
conversation/WebView and search input, not frame progress or resumed playback.
The rotation test separately covers actual embed URL/progress. This is guest
process recovery, not signed-in process/Google upload/picker/physical II recovery.
The driver preserves app data and requires an already-consented dedicated guest
AVD. It does not accept terms, authenticate or publish.

Both variants pass 255 JVM cases, both Lint tasks, Debug/test APK and unsigned
Release APK/AAB outputs (video-normal-process-verified-build.log). Two new JVM
cases cover saved focus reload without duplicate target reads and clearing on
close/account-cache discard. Initial fixture assertions conflated thread/empty
reply reads with the focused-post load; those test-only counters were corrected
before successful validation. No speculative production patch followed those
fixture failures.

Four final regression cases pass in emulator-check-20261008-165048: native public
video landscape/portrait/search return, native search/recreation/system Back,
real Keystore/ViewModel composer insertion/owner separation and live delegation
expiry/retained draft/video record. Fixed process check peak emulator RSS 4,649
MiB, Codex baseline/peak 2,532/2,565 MiB; regression peak 5,000 MiB, Codex
2,442/2,453 MiB. Both had no guard and normal owned-AVD exit. Gradle and emulator
did not overlap. Cargo format/check pass. Unsigned artifact/public config/manifest
verification is in video-normal-process-release-artifact-audit.json, with current
hashes at the top of release-readiness.md. No signing or deployment occurred.

Repeat the host check with the current public debug APK and a visible video post:

    python3 android/scripts/check-emulator.py --avd TAGGR_Auth_Pixel_9_API_37 --port 5556 --public-video-process-post 1460571 --timeout-seconds 240

The initial driver preflight assumed a shell help string for saved-task focus;
it was replaced with an ordinary launcher and actual same-task comparison.
The next UI observation showed text lives inside a clickable ancestor, so the
selector now reads descendant labels. Those harness attempts did not establish
process recovery; the third pre-fix attempt did and exposed the defect. Helpers
are dependency-free Python and pass compilation plus the existing three memory
attribution tests. The final successful JSON predates adding its explicit
same_task output field; actual identical task IDs are independently preserved in
both dumps and were checked by the same driver before success.

Signed-in/root owner process recovery, complete selected-upload/process/picker
restoration, actual Google transfer, older devices, production callback/signing
and physical auth remain open. A short passing check does not establish long
session leak resolution or full Swift equivalence.

## Actual Android 13 compatibility — 2026-10-08

A dedicated Pixel 6 AVD uses the installed official Android 13 / API 33 Google
Play ARM64 image, revision 9. The harness now records the actual guest SDK in
`device-api.txt` and `summary.json`; this establishes API 33 execution rather
than forcing an older code branch on an API 37 device. Android 13 selects the
native foreground-service fallback through the normal background entry point;
UIDT JobScheduler remains the API 34+ route.

The final 19-case batch passes in emulator-check-20261008-171913: background
service/queued ownership, wake-lock cleanup, encrypted upload-store retention,
composer guards and upload-form controls. Peak emulator RSS was 5,481 MiB,
aggregate Codex baseline/peak 3,474/3,474 MiB, no memory guard fired and the owned
AVD exited normally. Build and emulator intervals did not overlap.

The first 19-case run (emulator-check-20261008-170052) passed 18 and missed the
paused notification in the automatic-route case. The forced foreground-service
case passed in that same run. The automatic-route case subsequently passed alone
on the existing AVD (170844), alone on a newly created AVD with fresh local
notification state (171205), and in the final full batch. Its original cause is
unresolved; no speculative production notification change was made. A delayed
failure now reports notification enablement, running state and system notification
observations, and the case name identifies the platform route without implying
that Android 13 supports UIDT.

The test-only build and Debug Lint pass (api33-final-build.log); Python compilation
and the three memory-attribution checks pass. Production artifacts and the
255-case JVM matrix remain those verified in the preceding process-restoration
checkpoint. This verifies saved-upload interruption without a TAGGR account,
not actual Google authentication/transfer or prolonged screen-off uploading.
Devices below API 33 and long-session memory stability remain unverified.

The additional 12-case ordinary UI/media batch passes on actual API 33 in
emulator-check-20261008-172458. It covers guest account support/privacy controls,
Realm-to-profile return, transaction search and incoming links, selected-video
playback/pause/replacement/release, denied provider/form metadata retention,
public video landscape/portrait recreation and search return, and native post
Back/recreation. The public video case used post 1460571 / wmxU6jCMRhY and checked
actual embed loading after each rotation. Permission input is a test provider and
scripted picker result, not physical picker revocation or a Google transfer.
Peak emulator RSS was 5,682 MiB, aggregate Codex baseline/peak 3,502/3,623 MiB,
no guard fired and shutdown exited 0. These are two separate batches (19 and 12),
not every Android test or authenticated feature. The memory values are summed
process RSS and do not establish prolonged leak resolution.

A separate 180-second idle memory observation passes in
emulator-check-20261008-172649 (343 samples): emulator peak 5,062 MiB, Codex
baseline/peak 3,552/3,586 MiB, no guard and exit 0. This is idle host observation,
not a prolonged app/upload workload or a leak fix; detailed ranges are in
memory-investigation-2026-10-02.md. Cargo format/check pass after shutdown
(api33-compat-cargo-check.log). The temporary fresh-state Cold AVD was removed;
the main API 33 AVD and SDK image remain available.

## Minimum supported Android 9 — 2026-10-08

The app still declares minSdk 28. A dedicated Pixel 3 AVD now runs the official
Android 9 / API 28 Google Play ARM64 image, revision 2, confirmed from installed
source.properties and guest device-api.txt. This adds minimum-OS execution
evidence rather than inferring compatibility from newer devices or Lint.

Five initial cases pass in emulator-check-20261008-173232: three injected app
navigation/restricted-content cases and two actual Keystore self-delegation cases
covering encrypted restoration, clearing and real expiry. They do not establish
Internet Identity login. Peak emulator RSS 4,622 MiB, Codex baseline/peak
3,507/3,519 MiB, no guard and exit 0.

Fourteen subsequent cases pass in emulator-check-20261008-173331: two actual
certificate/signature-verified public feed/search reads plus the twelve ordinary
native navigation/media cases previously run on API 33. Public video post
1460571 / wmxU6jCMRhY survives actual landscape/portrait Activity recreation and
returns to search. Local selected-video playback/release and scripted denied
provider metadata retention pass. Peak emulator RSS 4,483 MiB, Codex baseline/peak
3,414/3,416 MiB, no guard and exit 0. No backend mutation or Google consent/upload
was performed. These selected batches do not verify every supported feature.

The process-recovery driver previously recognized only topResumedActivity. Actual
API 28 dumpsys output uses mResumedActivity; the helper now recognizes both while
still requiring TAGGR as the resumed package. Checks against saved actual API 28
and API 37 dumps pass, and historical-only/other-package records are rejected.
The first API 28 host recovery attempt (173454) stopped before app navigation
because am help prints valid help with a nonzero status. That diagnostic output
is now recorded with its exit code without treating it as a capability gate;
actual commands and saved-task/process checks retain strict failure handling.
That initial attempt does not establish app process restoration.

The final host-driven API 28 process check passes in
emulator-check-20261008-173540: process 3177 terminated in the background, normal
launcher startup created process 4118 in the same saved task 36, restored the
public video conversation, then Back restored the search. The URL was not replayed
at restoration. Peak emulator RSS 4,263 MiB, Codex baseline/peak 3,421/3,426 MiB,
no guard and exit 0. Actual task dumps and process-recovery.json retain the proof.
This extends the preceding production saved-focus fix to the minimum OS; it does
not prove signed-in/root owner, Google upload/picker or playback-position recovery.

The first 19-case API 28 background batch (emulator-check-20261008-173636) passed
17; the two service cases failed before service dispatch with Unknown permission:
android.permission.POST_NOTIFICATIONS. The test fixture unconditionally granted
that permission. It now grants only on API 33+, matching
[Android's notification permission specification](https://developer.android.com/develop/ui/compose/notifications/notification-permission).
No production permission/service behavior was changed and no assertions were
removed. Test APK and Debug Lint pass (api28-background-permission-build.log).
The initial failed batch shut down normally with no memory guard; it is not
passing background-service evidence. Python compilation and the three existing
memory attribution checks pass.

The final minimum-OS background batch passes all 19 cases in
emulator-check-20261008-173809, including actual foreground-service startup through
both the normal platform entry and forced fallback, paused notification, preserved
scoped job/source, wake-lock release, upload-store validation, composer guards and
form controls. Peak emulator RSS 4,281 MiB, Codex baseline/peak 3,107/3,115 MiB,
no guard and normal exit. Across the three separate API 28 batches, 38 selected
cases passed, plus the separate normal-app killed-process recovery check. This
closes minimum-OS evidence for those flows; it does not establish every wallet,
Realm, account or write operation on API 28, real II/Google authorization, real
upload, long screen-off work or physical-device behavior. The normal compatibility
AVD and image are retained for future verification. Production artifacts and the
255-case-per-variant JVM matrix remain unchanged from the previous checkpoint.

The changed notification fixture's API 33 branch also passes both actual service
cases in emulator-check-20261008-173902: peak emulator RSS 4,372 MiB, Codex
baseline/peak 3,121/3,122 MiB, no guard and exit 0. This is a focused regression of
the changed permission preparation, not a rerun of every API 33 case. Cargo
format/check pass after shutdown (api28-compat-cargo-check.log). Actual API 28 and
API 37 before/after resumed-task parser checks, including historical-only and
other-package rejection, are recorded in api28-harness-observation-check.json.
No new production app code, release signing, deployment, real Google action or
mutable Git operation occurred in this compatibility checkpoint.

## Signed-in root/composer process restoration — 2026-10-08

The normal registered local-account check exposed and fixed loss of the open
composer during transient account-record restoration. Actual same-task process
replacement preserves the text draft and Preview; a subsequent UI Post produces
one independently verified local post and one add_post call. See
[signed-composer-process.md](signed-composer-process.md) for the before/after
evidence, cleanup, build checks and limits. Real Google transfer/picker/video-job
process restoration remains a separate requirement.

## Storage install/registration response-loss integration — 2026-10-08

Both actual local completed-install and completed-registration response losses now recover through the ordinary registered app after a full emulator restart. Each journey has exactly one payment, CMC creation, install and registration, with independently queried module hash and user bucket. See [storage-creation-recovery.md](storage-creation-recovery.md). This supersedes the ambiguous install/registration gap in the historical priority list; historical storage migration and other remaining priorities remain open.

## Actual OS image chooser — 2026-10-08

The API 33 OS chooser boundary now passes with visible generated-image preview, actual accessibility/resumed-Activity evidence, cancellation back to MainActivity and the existing original-byte/read-only FileProvider case. See [photo-sharing-verification.md](photo-sharing-verification.md) for the failed screenshot/title assumptions, final proof and narrower scope. A normal photo-library share-button journey and external recipient readback remain unverified. This is test/evidence work, with no production app change.

The subsequent ordinary public photo-library button journey also passes on API 33, including actual public image acquisition, OS image preview and cancellation back to the same post viewer (emulator-check-20261008-191049). This supersedes the normal share-button gap above. External recipient delivery remains unverified; details and the test-clock diagnostic are in photo-sharing-verification.md.

## Current Swift Realm fallback contrast — 2026-10-08

The latest working-tree Swift RealmBadgeView now selects contrasting text for light/dark label backgrounds. Android RealmDetailsCard used white initials on every background; it now selects black/white by the same relative-luminance contrast comparison using Compose, without a dependency. Both variants pass 255 JVM tests, both Lint tasks and all public app/test/unsigned Release builds. Three API 33 Realm cases pass; actual light/dark screenshots were visually inspected. Evidence and current artifact hashes are recorded in release-readiness.md and ignored realm-initials-contrast-\* files. This narrows a real UI difference while the original completion scope and authentication/distribution gaps remain open. Unrelated working-tree iOS changes were inspected as the current reference and preserved.

## Native Markdown selection tools — 2026-10-08

The source comparison found Android PostComposer lacked Swift ComposePostAttachmentBar actions. The shared native editor now provides Bold, Italic, Bullet list, Quote and captured-selection Link insertion over UTF-16 selections, retaining the existing scoped draft callback and disabled/stale-text gates. Debug/Release each pass 257 JVM cases, both Lint tasks and all public artifacts. Five selected API 33 editor/reply/video-insertion cases pass (192417). The invocation/startup failures are preserved with their narrower evidence in [markdown-editor.md](markdown-editor.md). Full undo equivalence, selected attachment insertion and real-account/process journeys still require scope review; this addition does not establish full completion.

## Repost formatting and composer account replacement — 2026-10-08

Repost comments now use the same MarkdownEditor and existing scoped draft callback; busy/pending states retain their editor and submission gates. The expanded nine-case regression batch exposed a genuine first-owner draft overwrite after ViewModel replacement, diagnosed from both retained preferences and semantic text. PostComposer now binds collection to key(account), preventing its previous flow state from being paired with the new account callback. The exact nine-case batch passes after the fix (194307), with four repost, two editor, two reply and one automatic-video/owner-storage case. See markdown-editor.md for unsuccessful attempts and their limits. Both variants pass 257 cases, both Lint tasks and all public unsigned artifacts; release-readiness.md reflects current hashes. No real repost, Google authorization/upload, signing or deployment occurred.

## Image cursor insertion and guarded resumption — 2026-10-08

Image attachments now use the captured selection start and Swift newline/order rules; the one-time selection request preserves trailing text and subsequent typing. Ticket validation binds canister/owner/draft/body and import waits for saved metadata restoration. Debug and Release each pass 260 JVM cases, both Lint tasks and all public unsigned builds. The final API 33 editor/repost/reply/video-owner batch passes all ten cases (200249). Emulator peak RSS was 5,484 MiB; aggregate Codex-path RSS was 2,911→2,915 MiB, no guard, normal shutdown. One prior attempt stopped before boot on a 1,032 MiB Codex-path growth guard: six transient bundled Node processes accounted for the increase while GUI/CLI stayed effectively flat. They had exited before the successful retry. Limits were preserved. This is short-session evidence, not a long-session memory-leak fix. See [image-insertion.md](image-insertion.md) for failed attempts and the remaining actual-picker/process/authenticated-upload requirements.
