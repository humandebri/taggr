# Composer compatibility checks

The composer stores Markdown as plain text, with image markers managed by
`PostDraftDocument`. Changing the UI editor must preserve that document format
and the existing draft store. The current editor uses UIKit `UITextView` inside
SwiftUI; it does not depend on a third-party editor library.

## Automated gate

Run `TAGGRTests/TaggrQuoteTests` on an iOS Simulator. The focused hosted composer tests
cover the actual document editor inside its scrolling layout, rather than just
calling string-edit helpers:

-   Empty and populated text fields fill the available width and keep the left margin.
-   Initial focus and focus during typing remain active.
-   Programmatically marked Japanese text survives SwiftUI updates, commits and
    cancels without duplication after typed input. The restored-text marked-range
    test runs without first-responder focus: a live system keyboard can
    asynchronously replace synthetic marked text via candidate updates.
    Neither test substitutes for actual Japanese keyboard conversion on a draft.
-   UTF-16 selections replace Japanese text with emoji without corrupting the document.
-   Clearing all text keeps the field usable; multiline text increases its height.
-   Editing after an image preserves the image marker and the preceding text.
-   Cut, plain-text paste, undo and redo update the document binding. Paste uses
    an explicit string item provider so it does not require OS clipboard approval;
    system clipboard permission and rich-text paste remain manual checks.
    Clipboard contents changed by cut are restored after the test.
-   Disabling, dismissing and reopening the editor preserve text and restore focus.
-   Bold, italic, list and link actions append their existing templates at the end;
    they do not format the selected text. Quote acts on the selected lines.
-   Restored new-post, reply and edit drafts can be edited through the hosted input
    and saved back through the real local draft store.
-   Narrow/wide host layouts and accessibility text sizing retain available width.
    This exercises resizing, not physical rotation or the complete composer chrome.
-   Quote selection, quote continuation/termination, and the active image segment
    remain covered by the existing quote tests.

For the hosted gate, use the selected target's UDID:

```sh
qrun -- xcodebuild test \
  -project ios/TAGGR/TAGGR.xcodeproj -scheme TAGGR \
  -destination 'platform=iOS Simulator,id=A4C71745-1496-4F8A-AB5E-169AECC12430' \
  -derivedDataPath .build/composer-investigation \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO -only-testing:TAGGRTests/TaggrQuoteTests \
  CODE_SIGNING_ALLOWED=NO
```

Also run the existing `TaggrTests` cases for `PostDraftDocument`, `PostDraftStore`,
`PostDraftSession`, image batches, enqueued posts, and image submission/editing.
They exercise local storage and mocked APIs, without sending real posts.

Use `idb list-targets --json` to select the target explicitly. Build with
`xcodebuild build-for-testing`, then run the selected tests through idb. If idb
cannot launch tests, document that infrastructure failure and use Xcode's test
runner against the same target. Check the executed test count: a successful
command that selects zero tests is not a pass.

## Before changing editor engines or distributing a build

Keep dependency versions pinned. Run the same behavioral tests against the old
and candidate implementations; do not change expectations to accommodate a
regression. Keep Markdown serialization, draft persistence, toolbar behavior,
and the engine change in separate reviewable changes.

Also test on a physical iPhone with Japanese flick input: conversion candidates,
conversion cancellation, backspace, selection, paste, undo/redo, toolbar actions,
keyboard dismissal/reopening, and image insertion. Exercise root posts, replies,
and editing/restoring an existing draft. Check small/large text sizes, rotation,
and the oldest supported iOS version as well as the current version.

Programmatic `setMarkedText` tests do not establish compatibility with every
system keyboard or third-party keyboard. Do not publish an editor migration
based solely on compilation, string-helper tests, or a mocked keyboard sequence.

## Verification record (2026-09-12)

The original hosted reproduction failed before the fix: the empty editor had
zero width, populated text had 101 pt width instead of 366 pt, and initial/ongoing
focus failed. Returning the proposed width fixed layout; keeping UIKit focus in
ordinary SwiftUI state and applying it after window attachment fixed focus.

The available simulator is iPhone 17 / iOS 26.5
(`A4C71745-1496-4F8A-AB5E-169AECC12430`). `idb list-targets --json` currently fails
while describing its companion, so XCTest runs through Xcode on that target.
iOS 17.4 is the deployment minimum, but no 17.4 simulator runtime is installed.
A paired iPhone 15 is visible to Xcode; actual Japanese flick input has not been
verified. Native UIKit tests do not require a web/Playwright substitute.

Physical keyboard, actual rotation, complete toolbar/link-sheet interactions,
and minimum-supported-OS checks remain pending. Passing hosted tests alone does
not establish completion of those checks.

On 2026-09-13, development build `202609130930` was installed and launched on the
paired iPhone 15. The user subsequently explicitly requested committing this fix
and publishing it to external TestFlight. This authorizes beta distribution with
the documented verification gaps; it is not a report that those checks passed.
No cryptographic scope or backend API changes are included.

### Results

-   Hosted composer and quote gate: **18 passed, 0 failed, 0 skipped**. Xcode also
    compiled the iOS app and test target. Result bundle:
    `.build/composer-investigation/Logs/Test/Test-TAGGR-2026.09.12_22-34-55-+0900.xcresult`.
-   `cargo check --workspace --offline`, `make format`, Markdown formatting check
    and `git diff --check`: passed.
-   The expanded run selected 20 existing draft/submission cases in addition to the
    hosted suite. It exposed five pre-existing failing cases, also present in the
    earlier pre-fix run: `testEditPostUploadsImageBeforeEditPost`,
    `testEnqueuedPostDoesNotRefreshStaleFeedRoute`,
    `testEnqueuedPostKeepsRetryableAndUncertainDrafts`,
    `testImagePostKeepsEnqueuedAPIWhenSessionChangesDuringUpload`, and
    `testPostDraftDocumentInsertsAndMovesImageMarkers`. The first four involve
    verification/mock submission paths (two trap); the last disagrees about blank
    lines after image movement. Their production code and assertions are unchanged.
    This is **not** a claim that the entire iOS suite passes.
-   An earlier general-clipboard paste run blocked on the OS permission dialog
    while the Mac was locked. The final test supplies a string item provider and
    checks actual UIKit paste/undo/redo and the document binding; clipboard permission
    handling remains unverified. Do not treat that path as tested by the item-provider
    test.
