# YouTube upload implementation status

Android playback is implemented. Uploading is **not available in the app yet**.
The reference is ios/TAGGR/TAGGR/YouTubeUpload.swift and Views/YouTubeUploadView.swift.

## Implemented foundation

YouTubeUploads.kt validates the Swift metadata fields: title graphemes, UTF-8
description size, public/unlisted/private visibility, explicit kids audience,
synthetic-media declaration and acceptance of community rules. It prepares
metadata/session requests, sends file chunks with bounded reads and queries
server-acknowledged offsets before resuming an interrupted request. Completion,
authorization expiry, session expiry, temporary failures and permanent failures
remain distinct. Session URLs are restricted to the documented HTTPS Google
upload endpoint; redirects and automatic connection retries are disabled.

The protocol follows Google's
[resumable upload guide](https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol).
A caller must persist its session before sending chunks and query status after
response loss; these HTTP methods do not automatically create a durable job.

Eight JVM cases cover metadata, credentials/session destinations, session creation,
response-loss recovery, completion/status/range parsing, error categories and owned
call cancellation. The Android case checks ICU grapheme handling and exact resumed
file bytes with scripted HTTP responses. There was no real Google sign-in/upload.
Both variants pass 236 JVM cases and Lint. Evidence: youtube-upload-protocol-\*.log
and emulator-check-20261008-122744 under ignored .build/android.

## Saved-job foundation

YouTubeUploadJob/Codec preserve the exact entered metadata and bind a job to the
TAGGR owner, network, canister, YouTube channel and draft slot. A strict schema and
invariants reject malformed progress, unknown versions and invalid receipts.
YouTubeUploadJobStore uses a namespace-specific Android Keystore AES-256-GCM key,
binds all target fields as authenticated data and atomically saves encrypted
metadata/session URLs in noBackupFilesDir. Video bytes stay in private app storage
and are imported with a 64 KiB buffer; size and SHA-256 are checked on restoration.
Completion/cancellation removes the source after saving its receipt. A different
target cannot decrypt or clear the record. Expired or changed-source jobs are rejected and preserved for explicit
cancellation. Corrupt encrypted metadata also fails closed. A confirmed local discard/reset
flow has since been added; see the recovery reset section below.

Five JVM job/codec cases pass; both variants now pass 241 cases and Lint. Three
Android Keystore/store cases plus the prior protocol case pass in
emulator-check-20261008-123959. Evidence includes encryption/restoration across
new store instances, rejection of wrong target operations, completed receipt/source
cleanup, same-length source mutation and seven-day expiry. This is store-instance
restoration; a real background worker/process restart is not yet verified.

## Authorization adapter foundation

GoogleYouTubeAuth uses Google's AuthorizationClient in play-services-auth 22.0.0,
verified against official Google Maven metadata and the actual API classes. It
requests YouTube upload/read and account-email access on explicit YouTube actions,
returns a PendingIntent for foreground consent, rejects partial grants and checks
the verified account email and selected channel. Refresh requests can be bound to
the original Google account; cache clearing and revoke use that account/scopes.
Google tokens remain in memory. Scope/email requirements and Debug certificate
registration are described in [google-oauth-registration.md](google-oauth-registration.md).

Three Android adapter cases exercise actual SDK request/result objects with a
scripted AuthorizationClient and HTTP transport. They verify expected account and
scopes, no offline token request, cache clearing/revoke requests, pending resolution,
partial-grant rejection and changed account/channel rejection. This is not real
Google consent or token refresh/revoke. Two new JVM channel/account cases bring
each variant to 243 cases. Seven selected Android cases pass in
emulator-check-20261008-125224, including prior store/protocol cases.

## Required next integration

-   Connect the existing Google authorization adapter to foreground consent and
    channel state; account connection/revocation must remain independent from
    TAGGR sign-in and match the saved job.
-   Immutable app-owned video import; owner/canister/draft-bound encrypted job/session
    persistence and recovery; tokens must not be written into job metadata.
-   Background execution, bounded retries, cancel confirmation and source cleanup.
-   Swift-equivalent metadata/selection/progress UI and insertion of the completed
    URL into the correct retained draft, including reply/edit contexts.
-   Android OAuth package/certificate registration, consent/API project setup and
    authorized real-account verification. As noted in the iOS submission runbook,
    public production uploading also needs Google's OAuth/API verification.

These items remain part of the original completion goal. The transport tests do
not establish UI parity, persistence, background uploads or publication readiness.

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

YouTubeDraftInsertion is the production draft persistence path used by
AccountViewModel. It requires a completed job and matching full target, preserves
the saved body/realm, and commits the video URL plus insertion receipt together.
PostComposer passes its actual new/reply/edit slot independently of the job, so a
receipt for another draft cannot be accepted. Repeated insertion of the same
receipt preserves the existing body. The sheet now provides confirmed Disconnect
YouTube; successful account/scoped revocation clears in-memory access and retains
saved progress/receipts. Uploaded YouTube videos are not deleted by disconnect.

Four new Android cases pass: actual SharedPreferences for new/reply/edit/repost
slot isolation, body/realm retention and repeated codec-restored receipt insertion;
wrong owner/network/canister/channel/draft and incomplete job rejection without
writes; the real sheet with a Keystore-completed receipt and scripted SDK/HTTP
identity replies inserting the retained reply draft then clearing its upload; and
confirmed revoke preserving the receipt. Only scripted account/channel reads occur,
with no upload dispatch or real Google account operation. The production signed-in
composer, full app-process death and actual Google consent/upload still require
end-to-end verification. SharedPreferences reopening here occurs in the same app
process. The repost persistence case does not prove a repost attachment UI route.

All 15 selected Android cases pass in emulator-check-20261008-132422. Peak
emulator-tree RSS is 4,953 MiB, no guard, normal exit. Debug/Release each pass 248
JVM cases, both Lint tasks and public artifact assembly. Evidence is
youtube-insertion-final-build.log, youtube-insertion-device.log and
youtube-insertion-release-artifact-audit.json under ignored .build/android. No Gradle/emulator overlap occurred. Kotlin ktfmt,
root cargo fmt/check and documentation Prettier checks pass.

Remaining upload work includes background continuation, video preview, confirmed
unreadable/expired-record reset, insertion-receipt lifecycle/cleanup, the repost
attachment route and the authorized real-account workflow. Full iOS parity and
publication readiness remain unproven.

## Confirmed local recovery reset and receipt cleanup — 2026-10-08

The sheet now blocks new selection after restoration failure and offers retry or
explicitly confirmed local discard. Its warning covers wrong account/channel/
draft, expiry, corrupt metadata and unavailable source, explains that another
account's saved progress may be removed, and that accepted YouTube videos remain.
No remote deletion is performed. Confirmation is bound to a fingerprint of the
namespace, file inventory/statistics and bounded encrypted-record bytes; a changed
record rejects the old confirmation. Reset uses the dispatch mutex and store lock,
removes only recognized metadata/canonical UUID video files and its own Keystore
alias/directory. Unexpected files, directories or symlinks reject deletion rather
than being recursively removed. Corrupt oversized metadata inspection is bounded;
video contents are not rehashed by the discard inspection. A successful reset
allows a fresh encrypted job. Draft deletion now also removes only that draft's
insertion receipt markers, so they do not accumulate or prevent fresh insertion.

Five new Android cases verify corrupt-record discard/new-key job restoration,
stale-confirmation rejection and separate namespace retention, expired-record
preservation plus unexpected-file rejection, draft-specific receipt cleanup and
fresh insertion, and the real sheet's wrong-account restoration failure with
Keep/Discard confirmation behavior. Actual Keystore/files/SharedPreferences are
used; Google identity replies remain scripted. All 20 selected cases pass in
emulator-check-20261008-133106, peak emulator-tree RSS 4,960 MiB, no guard, normal
exit. Debug/Release each pass 248 JVM cases, both Lint tasks and all public
artifacts. Evidence: youtube-reset-final-build.log, youtube-reset-device.log and
youtube-reset-release-artifact-audit.json under ignored .build/android. Build and
emulator intervals do not overlap. No real Google account operation, mainnet
write, deployment, release signing/distribution or mutable Git operation occurred.

Background continuation, video preview, repost attachment routing, whole-app
process recovery and authorized actual Google upload/composer verification remain
required, along with the other original app-completion gaps.

## Selected local video preview — 2026-10-08

YouTubeUploadForm now displays SelectedVideoPreview for the selected picker URI.
It uses the platform VideoView with explicit Play/Pause, no autoplay, content-URI
validation and a friendly native playback failure notice. The lifecycle observer
pauses on ON_PAUSE/ON_STOP and does not automatically restart on return. Replacing
the URI or leaving composition calls the owned view's stopPlayback and clears its
listeners. No remote video URI is accepted and no preview-only media dependency
was added. Scrubbing/seek UI, real system-picker grant restoration and arbitrary
selected-video format coverage remain to be verified for full AVKit parity.

Two Android cases use an actual locally generated 3-second AVC MP4 (Android
MediaCodec/MediaMuxer, no downloaded media), the production upload form and native
VideoView. They verify a real duration and advancing playback position, actual
Activity CREATED/RESUMED pause/manual resume, replacement and final release with
no old view retained in the tree, and refusal to create a player for an HTTPS URI.
The inspected screenshot is selected-video-preview.png in ui-captures under
emulator-check-20261008-134005. It shows the selected local fixture, playback
control and metadata form; it is not real Google uploading or full app process
recovery. All 22 selected Android cases pass, peak emulator-tree RSS 4,637 MiB,
no guard, normal exit. This bounded run is not proof of long-session leak absence.

Debug/Release each pass 248 JVM cases, both Lint tasks and public artifact assembly
(video-preview-final-build.log); the final form/capture test update also passes
Debug test assembly/Lint (video-preview-device-build.log). Current artifacts are
recorded in video-preview-release-artifact-audit.json. Kotlin ktfmt, root cargo
fmt/check and changed-document Prettier checks pass; Gradle/emulator intervals
remain separate. Background continuation, repost attachment routing, full process
recovery and authorized actual Google consent/upload/composer verification remain
required, along with the other original app-completion gaps.

## Native seek controls and saved preview position — 2026-10-08

SelectedVideoPreview adds an accessible seek slider and elapsed/total time.
Seek completion updates the actual native position; scrubbing does not start
playback. Position is saved within the URI-keyed composition, while playing
state is intentionally not restored. Prepared players seek to the bounded saved
position. The lifecycle pauses playback and sampling runs only while resumed;
release also clears the owned seek listener/player reference.

The real generated-AVC form case now seeks while paused, verifies native position,
then requires new playback advancement. A third preview case uses
StateRestorationTester to restore the same URI near its saved two-second position
without playback, then changes URI and requires a newly prepared player near zero.
The first interval (-134803) passed seek/same-URI restoration but the final switch
assertion read the old prepared view: its wait checked duration only. The test now
requires the old view released and a different prepared view before asserting its
position. No speculative app fix was made. All 23 selected Android cases pass in
emulator-check-20261008-135158; peak emulator-tree RSS 5,047 MiB, no guard, normal
exit. The inspected selected-video-preview.png shows the slider and 0:01 / 0:03.

This proves saved-composition restoration and actual native seek/playback; it does
not prove full app process death, physical-device picker grant persistence or all
media formats. Actual background/return pause/manual resume remains covered by
the form case. Debug/Release each pass 248 JVM cases, both Lint tasks and public
assembly (video-seek-final-build.log); final test assembly/Lint pass in
video-seek-device-build.log. Current unsigned outputs are recorded in
video-seek-release-artifact-audit.json. Root cargo fmt/check, Kotlin ktfmt and
changed-document Prettier checks pass, with no Gradle/emulator overlap.

Background upload continuation, repost attachments, whole-app process recovery,
authorized real Google consent/upload/composer verification and the other original
completion gaps remain required. No real Google action, mainnet write, deployment,
release signing/distribution or mutable Git operation occurred.

## Account-bound shared execution loop — 2026-10-08

Upload schema 2 adds the original verified Google account email to encrypted job
metadata; tokens remain memory-only. The decoder accepts genuine schema-1 jobs
without this field, and refuses an email injected into that legacy schema. A
validated foreground connection binds an unbound job before dispatch. Once bound,
the store refuses changing/removing the email. Foreground restoration also rejects
a mismatched Google account even when its channel ID matches. The existing
Keystore envelope/AAD namespace is unchanged; migration does not require rewriting
records merely to inspect them.

YouTubeUploadExecution is now the sheet's shared dispatch loop. It requires the
saved Google account/channel/target and checks the current TAGGR owner before each
dispatch, leaving confirmed progress intact when ownership changes. It honors the
persisted retry delay only for active phases and retains the runner's pre-send
CHECKING/status-query recovery. Auth and OS scheduling remain the caller's job.
This is a background prerequisite, not an implemented background upload service.

Four new JVM cases cover schema migration/account validation, accepted-upload
reply loss with a saved status-query/backoff and no byte resend, owner change
between dispatches, and unbound/wrong Google credentials failing before save or
HTTP. Debug/Release each pass 252 cases, both Lint tasks and public artifact
assembly. One new actual Keystore case verifies encrypted email, reopened-store
identity and rejection of changing/removing the binding. All 24 selected Android
cases pass in emulator-check-20261008-140120; peak emulator-tree RSS 5,028 MiB,
no guard, normal exit. Evidence: youtube-execution-final-build.log,
youtube-execution-device.log and youtube-execution-release-artifact-audit.json.
No Gradle/emulator overlap occurred. Root cargo fmt/check and Kotlin/document
formatting checks pass.

The chosen next scheduler direction follows Android's official
[user-initiated data transfer documentation](https://developer.android.com/develop/background-work/background-tasks/uidt):
UIDT JobScheduler on API 34+, scheduled from a visible user action, with an ongoing
notification and graceful notification stop control. Lower supported versions
need a foreground-service fallback. JobService/notification/fallback are not yet
implemented or wired. The worker must load the trusted TAGGR session, authorize
the saved Google account/channel, return foreground-consent-required rather than
launching consent, persist progress before every dispatch, and stop on owner
change/system cancellation without resending an ambiguous chunk. Background
completion, process restart, repost routing and the authorized real-account
workflow remain required. No real Google action, mainnet write, deployment,
release signing/distribution or mutable Git operation occurred.

## OS transfer services connected — 2026-10-08

The sheet now schedules user-initiated JobScheduler work on API 34+ and a native
dataSync foreground service below that API. The UIDT component is disabled by
resources below API 34. Manifest services/receiver are nonexported; JobService
also requires the signature-level BIND_JOB_SERVICE guard. An ongoing notification
contains generic progress and a Pause PendingIntent; jobs finish/detach after a
terminal result, and caller/system stop cancels owned work while retaining saved
request state. Foreground fallback is nonsticky and implements the modern timeout
callback. No new library dependency was added. Platform execution follows the
[UIDT guide](https://developer.android.com/develop/background-work/background-tasks/uidt)
and [foreground timeout rules](https://developer.android.com/develop/background-work/services/fgs/timeout).

Background execution reloads target-bound metadata/source, checks public-build
network/canister configuration and the trusted stored TAGGR session/expiry, and
refreshes the original Google account/channel. Foreground install/sign-out/expiry
observation stops work when ownership changes. A pending Google consent resolution
is saved as authorization-required and never launched by the worker. A process-wide
mutex serializes dispatch/reset/cancellation. The sheet polls encrypted metadata
without rehashing the video each second and lets closing continue the OS work;
cancel and disconnect pause/join background execution before destructive/revoke
steps. POST_NOTIFICATIONS is requested from explicit upload/resume actions.
Scheduling extras contain IDs/target scope but no email/token/session capability
or private title. Tokens remain outside app-owned persisted jobs.

Three new Android cases use actual UIDT JobService and foreground-service startup
on API 37 with notification permission granted to the test app. A missing TAGGR
owner stops before Google authorization, leaves the source/job unchanged, removes
the pending OS job/active execution and posts a nonongoing paused notification.
The third case checks scheduling extras privacy. All 27 selected Android cases
pass in emulator-check-20261008-141837; peak emulator-tree RSS 4,874 MiB, no guard,
normal exit. The test notification grant is retained in this dedicated test AVD;
it is not a grant on a physical/user device. Debug/Release each pass 252 JVM cases,
both Lint tasks and all public artifacts (youtube-background-final-build.log).
Final test assembly/Lint pass in youtube-background-device-build.log. Current
unsigned output/configuration/manifest evidence is youtube-background-release-artifact-audit.json.
Root cargo fmt/check, Kotlin ktfmt and changed-document Prettier checks pass;
Gradle/emulator intervals remain separate.

These tests prove real service startup/guarded stop, not authenticated background
byte transfer. Required follow-up includes authenticated normal-app background
upload/status recovery, notification Pause during an active transfer, full process
restart/Task Manager stop, notification denial, older-API execution/timeout and
fallback CPU/wake-lock/time-budget handling for long screen-off work. Scheduler
eligibility/failure and sign-out races need integration verification. Repost
attachments, authorized real Google consent/upload/composer verification and the
other original completion gaps remain. No real Google action, mainnet write,
deployment, release signing/distribution or mutable Git operation occurred.

## Scoped CPU lock for the foreground fallback — 2026-10-08

The Android 9–13 foreground-service path now holds a partial CPU wake lock only
while loading/validating the saved source, resolving account-bound authorization,
or executing an individual dispatch with its ownership check. Each scope has a
three-minute coroutine timeout and a slightly longer OS lock timeout. `finally`
releases the actual lock on completion, failure and cancellation. Retry backoff
holds no manual wake lock. Android 14+ user-initiated jobs use OS scheduling and do
not acquire this lock. This follows the requirement to keep manual locks brief in
[Android's wake-lock guidance](https://developer.android.com/develop/background-work/background-tasks/awake/wakelock).

The fallback also pauses after a thirty-minute execution budget, preserves its
durable record and stops the foreground service. The upload sheet explains this
limit on Android below 14. The modern OS `onTimeout` callback posts a paused
notification before cancellation. Resumption uses the existing persisted status
recovery; no timeout handler deletes progress or starts another upload session.

All 252 JVM cases per Debug/Release variant, both Lint tasks and all app/test and
unsigned release builds pass (`youtube-wake-final-build.log`). The lost-reply
execution test additionally proves the dispatch scope has ended before retry
backoff. Actual OS `dumpsys power` observations verify the lock is present during
work and absent after success, exception, cancellation and timeout. Together with
existing upload tests, 29 API 37 device cases pass in
`emulator-check-20261008-143312`; peak emulator RSS 4,920 MiB, aggregate Codex RSS
2,528 MiB baseline / 2,530 MiB peak, no guard, emulator exit 0. Cargo format/check
and artifact/manifest/unsigned signature checks also pass.

The actual fallback service is still exercised on API 37, not a physical Android
9–13 device. Authenticated long uploads with the screen off, full process restart,
active-transfer notification pause and denied notifications remain unverified.
A short successful run does not establish that earlier long-session memory
pressure or Codex retention is resolved. No real Google authorization, YouTube
upload, signing, publication or production deployment occurred in this checkpoint.

## Failed preview disposal — 2026-10-08

A real corrupt local MP4 reproduced an error message without releasing the owned
SelectedVideoView/MediaPlayer (`emulator-check-20261008-143649`, one failed
assertion). The error listener now marks playback unready, clears pending seek
state and releases listeners and playback immediately. A replacement URI creates
an independent player and can play normally. This addresses a proven local
resource-retention bug, not the reported Codex host-memory incident.

Seven focused preview/upload-form Android cases pass after the fix in
`emulator-check-20261008-143908`, including the corrupt-source release and valid
replacement, existing background pause, disposal, seek restoration and form
validation. Peak emulator RSS was 4,989 MiB; aggregate Codex baseline/peak was
2,448/2,454 MiB; no guard fired and the emulator exited normally. Both variants
pass 252 JVM cases, both Lint tasks and app/test/unsigned release builds. Evidence
is in `preview-failure-*` under `.build/android`; Cargo format/check also passes.
The earlier 29-case service/upload batch was not rerun here. Expired picker grants,
permission-denied providers, long authenticated screen-off transfer and full app
process restoration remain separate unverified cases.

RepostSheet in the current iOS PostInteractionViews.swift has no image/video
attachment bar. Android's corresponding repost form therefore does not need an
extra video button to match that reference. New, reply and edit composers retain
their existing upload route; isolated insertion receipts can still support a
repost draft slot without implying a repost UI attachment feature.

## Account connection management and shared selection — 2026-10-08

Account now has a YouTube card in guest and signed-in states, matching the current
iOS SettingsView connection controls. Showing the card makes no authorization
request. Connect explicitly calls the existing Google adapter and can launch the
foreground consent resolution. A verified connection displays the channel title;
Disconnect requires confirmation, pauses/joins owned sending, revokes that Google
account's scopes and retains upload progress. Errors retain a retryable UI.

AccountViewModel holds the connection only in memory. New/reply/edit upload
sheets share it and load the original target's durable receipt without another
foreground authorization. Background sending still refreshes the original Google
account/channel independently and checks the current TAGGR session. A TAGGR owner
change, sign-out or expiry clears the shared selection. Late authorization cannot
install a connection for a different owner. After process restart users explicitly
reconnect; no Google access token is written to preferences or job metadata.

Final public-default app source passes 252 JVM cases per Debug/Release variant,
both Lint tasks and app/test/unsigned release outputs
(`youtube-account-guest-final-build.log`, `youtube-account-device-build.log`).
Fifteen API 37 device cases pass in emulator-check-20261008-145141: four Account
panel cases, four completed-upload UI cases, three adapter cases, three upload-form
cases and one actual MainActivity guest Account/support route. The panel and
adapter cases use real SDK classes with scripted replies, not real Google account
actions. Guest navigation verifies an enabled Connect button while both TAGGR
principal and YouTube selection remain null; it does not press the real button.
Shared-connection receipt insertion uses no additional scripted Google HTTP call.

Emulator peak RSS was 4,997 MiB, aggregate Codex baseline/peak 3,225/3,405 MiB,
no guard fired and emulator exit was zero. Cargo format/check and unsigned artifact
checks pass. This short observation does not establish long-session memory
stability. The earlier 13-case authenticated-panel batch was superseded by the
15-case final run. Actual Google consent/cancellation, connection state through
full app death, real authenticated background upload and physical/old-device
behavior remain unverified. OAuth project/signature registration remains an
external prerequisite; no Google Cloud mutation, real revoke/upload, signing,
publication or deployment occurred.

## Draft-specific submit protection — 2026-10-08

Swift canSubmit refuses submission while its draft's video is running. Android
now matches active ownership by TAGGR principal, financial network, canister and
draft slot, using tracked OS work plus pending UIDT job extras. The fallback also
records a queued start before calling startForegroundService, so the interval
before onStartCommand is protected; a failed start clears only that queued
attempt. Owner changes/pause clear queued ownership. Completion of an older work
handle cannot remove the replacement work's target.

The ordinary new/reply/edit composer disables Post/Submit/Save and saved-draft
Discard while that specific draft is sending, and explains waiting or pausing.
Other draft slots/accounts/networks/canisters remain independent. Lifecycle-bound
polling stops below STARTED and refreshes on return. AccountViewModel checks again
at action start and immediately before add_post/edit_post; discardDraft checks
before clearing the local record. These guards retain the draft on refusal and
introduce no upload cancellation or post retry by themselves.

All 253 JVM cases per Debug/Release variant, both Lint tasks and all public app/test
and unsigned release outputs pass (`video-composer-queued-final-build.log`). Twelve
Android cases pass in emulator-check-20261008-151700: two production submit-control
and ownership cases, four real-service/extras/start-failure cases, two retained
inline-reply cases and four completed-upload insertion/disconnect cases. Actual
UIDT/fallback services are held at the shared dispatch mutex to observe their
matching draft before the trusted missing-account guard stops them. The fallback
helper is forced on API 37; this is not an Android 9–13 device verification. The
blocked-start test uses an explicit ContextWrapper failure without starting a
real service. No authenticated backend posting attempt was made in this batch.

Final emulator peak RSS 4,727 MiB, aggregate Codex baseline/peak 2,927/2,927 MiB,
no guard, normal exit. Cargo format/check and current public manifest/config and
unsigned artifact checks pass. The two earlier 11-case batches are checkpoints,
not the final source proof. Real authenticated upload/post interaction and old
physical devices remain unverified. Automatic consumption was still open at this checkpoint; the following section
records its implementation. Full process restoration and the remaining original
parity scope still require verification; Use video in post remains available.

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
