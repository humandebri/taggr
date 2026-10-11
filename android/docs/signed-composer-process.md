# Signed-in composer process recovery — 2026-10-08

A normal-app local check reproduced a restoration defect: after background
process termination, the encrypted account returned in the same saved task but
the open New post preview disappeared and Feed was shown. The existing guest
conversation checks did not exercise this signed-in restoration path.

TaggrApp now resolves initial account restoration before consuming saved root
navigation. It keeps root route state, composer selection and content owner
registered while checking the account's retirement records. The loading and
retired-account screens still gate content and actions; the retired-account
cache-discard behavior is retained. This prevents a temporary loading return
from disposing the restored root state. No password/root key enters saved UI
state, and no publication is automatically retried.

## Actual local verification

A new task-owned managed network ran at http://localhost:18102. A freshly created
dev TAGGR canister used the existing local-taggr.wasm; no production canister was
modified. Its registered user draftprocess had the public test-vector principal
b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe. A loopback-only
TLS proxy at 18445 used a newly generated localhost certificate. A new dedicated
API 33 Pixel 6 AVD trusted that CA through ordinary Android settings; certificate
and hostname validation remained enabled by the existing localhost Debug config.

The first automated password entry generated a different public request principal
and returned no user. Independent backend lookup confirmed the intended user
existed. After waiting for field focus and entering the public fixture one
character at a time, the request principal, signing-root principal and registered
user matched. The exact initially entered string was not recovered; this was an
input-driver discrepancy, not evidence of a password derivation/library defect.
A transient ADB UI-file operation also failed; the original running emulator was
inspected and reused rather than restarted from the observation failure.

Before the production fix, PID 4506 was killed behind HOME in saved task 14. The
ordinary launcher raised that task but Feed appeared instead of the composer.
activity-before/after.txt and composer-before/after.xml retain that failure.
The initial JSON records termination only; subsequent PID/task assertions passed
before the visible-composer wait failed. It does not contain a final success.

After the fix, the ordinary MainActivity restored its actual registered account.
The previously persisted draft was still present under the exact canister/owner/
new namespace. The UI reopened it, selected Preview, went HOME and terminated
PID 3172. Ordinary MAIN/LAUNCHER startup, with no replayed link, created PID 4682
in the same task 16 and restored both body and Preview. Only then did a user-like
Post tap submit the draft. The normal conversation displayed it; independent
backend posts readback confirmed one matching post (ID 1, author 0), and proxy
method tracing confirmed exactly one add_post call. Normal UI sign-out returned
the Account screen to guest state.

Ignored evidence is in .build/android/composer-process: fixed-process-recovery.json,
fixed-activity-before/after.txt, fixed-composer-before/after.xml,
drafts-before-fixed.xml, published-posts-readback.json,
publication-readback-summary.json, calls.jsonl and fixed-recovery-ui.log.
The final bounded run is emulator-check-20261008-180815: API 33, peak emulator RSS
5,272 MiB, Codex baseline/peak 2,843/2,903 MiB, no guard and exit 0. Earlier setup,
observation and pre-fix runs were separate bounded intervals, not successful
composer-recovery checks. Gradle and emulator intervals did not overlap.

The dedicated local network/proxy were stopped after verification. The temporary
AVD, its test identity/user CA and both generated private TLS keys were removed.
Compatibility AVDs and unrelated networks/devices were preserved. Debug was rebuilt
with public defaults; no local override is in the Release artifacts. Both variants
pass 255 JVM cases, both Lint tasks and all Debug/test/unsigned Release APK/AAB
outputs (public-verified-build.log). Public config, manifest and unsigned-artifact
checks are in signed-composer-process-release-artifact-audit.json.

## Public regression checks

Eleven API 33 cases pass in emulator-check-20261008-181406: component app
navigation/restricted bodies, actual ordinary navigation, native search/post
return, video rotation, composer video insertion/owner separation and live
session-expiry draft retention. Peak emulator RSS 5,629 MiB, Codex baseline/peak
2,913/2,914 MiB, no guard and exit 0. The video-insertion cases still use synthetic
Google access/job records; they do not establish real Google authentication.

The minimum-OS guest process check also passes after this change in
emulator-check-20261008-181617: API 28, peak emulator RSS 4,218 MiB, Codex
baseline/peak 2,918/2,962 MiB, no guard and exit 0. The normal launcher restores the
public conversation and its search return in the same saved task. This is guest
recovery; the registered-account composer check above ran on API 33.
Cargo format/check, Python compilation and the three memory attribution checks
pass. No build overlapped an emulator and no memory limit was raised.

## Limits

This proves a registered local password-account text draft/preview recovery and
subsequent real local publication. It does not establish production Internet
Identity, real Google consent/upload, picker-grant or image/video-job restoration,
all private routes, wallet pending-operation recovery, physical devices or
long-session leak resolution. Production callback hosting and signing, actual
Google configuration and the other full Swift parity requirements remain open.
