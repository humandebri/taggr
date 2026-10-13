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
-   Cut, plain-text paste, undo and redo update the document binding. Image paste
    routes every image item provider through the normal attachment pipeline and
    takes priority over alternate text in the same paste. Tests use explicit item
    providers so they do not require OS clipboard approval; system clipboard
    permission and rich-text paste remain manual checks.
    Clipboard contents changed by cut are restored after the test.
-   Disabling, dismissing and reopening the editor preserve text and restore focus.
-   Bold, italic, list, quote and link replace the selected UTF-16 range. Empty
    selections insert at the caret; link labels come from the selection, including
    an empty label. Link URL input is preserved verbatim. Empty URLs and cancellation
    preserve the document. Quotes use the Web prefix rule and ordinary newlines.
-   Restored new-post, reply and edit drafts can be edited through the hosted input
    and saved back through the real local draft store.
-   Narrow/wide host layouts and accessibility text sizing retain available width.
    This exercises resizing, not physical rotation or the complete composer chrome.
-   Image insertion uses the Web newline rule at the saved document cursor without
    deleting selected text. Formatting and image edits share document-level undo
    history with typing and explicit-item-provider paste.
-   Link and photo pickers snapshot the document and selection before presentation.
    Stale results do not modify a changed or dismissed document; import cancellation
    restores the selection. The editor is disabled during image import.

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

## Web parity contract

Run `node ios/scripts/composer-web-parity.cjs`. It extracts the actual callbacks
and image insertion function from the Web form using the installed TypeScript
parser and executes the same fixtures bundled into the iOS tests. The fixtures
cover Japanese, emoji, combining characters, partial/multiline/empty selections,
repeated formatting, empty/verbatim URLs and image boundaries.

Parity means the same Markdown for the same input, selection and image markers.
iOS retains native image presentation and local draft persistence. It does not
add the Web-only toolbar buttons or copy Web autosave gaps. Image transcoding and
marker generation remain platform-specific. Whitespace-only posts are rejected,
but valid submission bodies retain leading/trailing spaces and newlines.

The iOS caret contract is explicit: bold/italic retain the enclosed selection;
empty link insertion places the caret inside `[]`; other replacements place it
at the end. Cancellation restores the saved selection. Web does not explicitly
set a post-transformation selection, so its browser-dependent caret is not copied.

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

## Web parity implementation verification (2026-09-13)

The editor now binds text segments directly to the document. It no longer keeps
an additional segment-local text state that could overwrite a toolbar update
while committing marked text. A document controller maps UTF-16 selections across
image markers, snapshots modal operations, and shares undo history between text
segments. Both the composer and the standard post/edit submission paths preserve
boundary whitespace; reposting is outside this change.

-   Final Simulator run: **22 composer tests passed, 0 failed, 0 skipped**.
    This includes actual link-sheet insertion/cancellation/empty URL, active marked
    text followed by formatting, image failure/cancellation, image insertion while
    disabled, caret restoration, undo/redo, and formatted draft restoration in new
    post/reply/edit contexts. New-post and edit API mocks also verified exact Candid
    arguments preserving leading indentation and trailing newlines.
-   Expanded run: **47 tests, 41 passed, 6 failed, 0 skipped**. Result bundle:
    `.build/composer-investigation/Logs/Test/Test-TAGGR-2026.09.13_14-20-39-+0900.xcresult`.
    The failures are listed below; this is not an all-suite pass.
-   Web shared fixtures: **14 Markdown and 4 image cases passed**, using callbacks
    extracted from the actual form rather than a duplicate Web implementation.
-   Playwright CLI exercised the actual Web `Form` in a local API-mocked harness:
    selected `TAGGR` became `[TAGGR](https://example.com)`, cancellation preserved
    the text and returned focus, and Bold produced `**TAGGR**` at the selection.
    Submission was disabled. The only browser console error was a missing favicon.
    Screenshot: `.playwright-cli/page-2026-09-13T05-05-37-288Z.png`.
-   `cargo check`, TypeScript checking, frontend build, `make format`, formatting
    checks and `git diff --check` passed during implementation.
-   idb can list and boot the Simulator with host access, but `idb xctest run app`
    failed with `Connection lost`; Xcode's test runner is the fallback on the same
    iPhone 17 / iOS 26.5 Simulator.

Expanded checks still expose pre-existing failures outside the changed editor:
`testEditPostUploadsImageBeforeEditPost` and
`testSubmitPostPassesRealmAndReloadsRealmFeed` do not mock the realm lookup now
required before publishing; `testEnqueuedPostKeepsRetryableAndUncertainDrafts`
fails verification before reaching the update whose uncertain outcome it expects.
`testEnqueuedPostDoesNotRefreshStaleFeedRoute` and
`testImagePostKeepsEnqueuedAPIWhenSessionChangesDuringUpload` terminate the test
process. `testPostDraftDocumentInsertsAndMovesImageMarkers` still disagrees about
blank lines in the unchanged image-movement helper. These failures are not
silently skipped or counted as passes. The edit whitespace regression test was
updated to provide its required realm response and assert both verification calls.

Physical-device Japanese keyboard conversion, actual Photos library selection,
rotation and the minimum supported OS remain unverified for this patch. The
hosted tests use real UIKit input and SwiftUI link-sheet controls, but synthetic
marked text is not a substitute for a physical Japanese keyboard check. No
physical-device installation, production submission or TestFlight upload was
performed for this patch.

## Unified editing history follow-up (2026-09-13)

UIKit text changes now update the document only through `recordTyping`. The
second segment write was removed: once a pasted blob marker splits a text
segment, applying the same replacement again duplicated the marker and its
following text. The regression test inserts multiple blob markers with Japanese
and emoji text into empty and already segmented documents and checks undo/redo.

Undo snapshots now retain document identity, Markdown, local image data and the
UTF-16 selection. Image insertion, deletion, both drag destinations and YouTube
URL insertion use the same controller as typing and formatting. Removing one of
several references retains the attachment; undoing the last reference's deletion
restores its data, including after the deletion was saved to disk. Upload
acknowledgement remains outside undo/redo and follows successful draft saving.
Automatic URL insertion does not open the keyboard, and duplicate URLs do not
create another undo step. Disconnection clears history and pending selection.
The existing image-movement whitespace algorithm remains unchanged.

A mixed-history test exposed an additional selection issue: `UITextInput`
insertion does not always invoke the delegate's pre-change callback. The editor
now also remembers selection changes while the view still matches the previous
model. This restores the original caret when undo reaches the initial typing
operation, without capturing the selection after the text has already changed.

-   All **26 composer tests passed**, including four new regression tests for
    pasted blob Markdown, mixed history, automatic URL insertion, and actual
    `PostDraftSession` image restoration/persistence in new/reply/edit contexts.
-   Final expanded run: **51 tests, 45 passed, 6 failed, 0 skipped**. The same
    six failures listed in the previous section remain; there are no additional
    failing tests. Result bundle:
    `.build/composer-investigation/Logs/Test/Test-TAGGR-2026.09.13_15-02-08-+0900.xcresult`.
-   Web fixtures passed: **14 Markdown and 4 image cases**. Playwright CLI again
    verified selected-text link insertion and cancellation preserving text and
    restoring focus on the actual Web Form with submission disabled.
    Snapshot: `.playwright-cli/page-2026-09-13T06-00-13-591Z.yml`.
-   TypeScript checking, frontend build, `cargo check` and `make format` passed.
-   Swift 6.3.2 initially crashed compiling a bound actor method used as a Binding
    setter. An explicit setter closure compiled successfully; no toolchain or
    dependency change was needed. Temporary diagnostic output was removed.

Verification used the existing iPhone 17 / iOS 26.5 Simulator and Xcode test-runner
fallback documented above. Physical-device Japanese keyboard and Photos picker
checks remain unperformed. No physical install, commit, push or distribution was
performed during this follow-up.
