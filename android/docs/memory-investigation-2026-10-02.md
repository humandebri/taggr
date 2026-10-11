# Memory investigation — October 2, 2026

## Confirmed

-   macOS `loginwindow` logged `showLowMemoryPanel` at **16:15:35 JST**,
    sampled repeatedly, and closed the panel at **16:34:59 JST**. This proves an
    actual system memory-pressure incident before the reported restart.
-   The selected historical unified log does not identify which application held
    the memory. No matching memory-resource, jetsam or Codex crash report was found
    in the user's DiagnosticReports directory. Codex application logs do not contain
    an OOM, renderer-crash or historical heap/footprint measurement for this incident.
-   After restart, the main Codex renderer's RSS ranged around 0.85–1.05 GiB.
    A 47-second, 24-sample window showed 1046 -> 1042 MiB; the desktop main process
    showed 885 -> 880 MiB. A later snapshot was lower. This short observation does
    not reproduce continuous growth or rule out a longer-lived leak.
-   `vmmap` reported the renderer's physical footprint as 852.3 MiB, with a peak
    of 1.0 GiB. Its Chromium PartitionAlloc malloc-zone analysis was incomplete;
    this is not a retained-object or leak analysis. The large virtual address-space
    reservation is not equivalent to physical RAM consumption.
-   During the sample window, Codex-related processes grew from 66 to 71. New
    processes belonged to another Codex execution parent and included two renderers
    and Node/MCP processes. This TAGGR investigation did not start a build or emulator.
    Summed RSS increased from 6422 to 6914 MiB, **including overlapping shared pages**;
    that sum is not an exact physical-footprint total and does not prove a leak.
-   Multiple plugin-server instances are resident: seven code-review instances,
    eight codex-security instances and seven codex-app-tools instances were observed.
    These may belong to separate active sessions; their count alone does not prove
    orphaning or justify terminating them.
-   Old TAGGR Gradle daemons PID 6542 and 13104 and Kotlin compiler daemon PID 6636
    remain from earlier runs. Their logs show idle Gradle state. Kotlin heap use was
    approximately 738 MiB, and the two Gradle heaps used approximately 294 and
    120 MiB. Their RSS later decreased substantially. These are resident compiler
    caches/processes, not proof of an unbounded leak.
-   Earlier "no residual processes" verification covered only Java PIDs started by
    the most recent capped build. It did not cover these older daemons.
-   At the final snapshot, `memory_pressure -Q` reported 83% system-wide free
    memory. The incident is not currently reproduced.

## Log findings and limits

Before restart, Codex recorded 2104 attempts to watch a deleted worktree belonging
to another project and 521 `ResizeObserver` loop warnings. After restart, the
deleted-worktree watcher warning was absent, while UI warnings remained. Neither
event includes allocation data sufficient to attribute the memory incident.

MCP status events were initially mistaken for startup failures. The current
application's 408 status events are 70 `starting` and 338 `ready`, with zero
`failed`; the previous application had one failed event. There is no evidence
for a present failure/restart loop from these status counts.

## Mitigation scope

The existing capped build settings successfully limit new Gradle workload and
avoid new persistent Gradle/Kotlin daemons. They do not limit Codex renderer or
plugin memory, remove old daemons, or establish that a Codex leak was fixed.
No unrelated Codex/browser/plugin process was terminated or plugin uninstalled.
Feature development was held during this investigation.

For attribution of the original incident, the process name and memory amount
shown in the macOS warning/Activity Monitor are needed. If it recurs, capture
that process's physical footprint and PID over time before restarting, then
compare under the same workload. For Codex, a controlled comparison with fewer
active sessions and without loading this long transcript would separate process
multiplication from transcript retention; no new task or app restart was performed
as part of this read-only investigation.

## Local evidence

Ignored `.build/android/` files:

-   `memory-system-before-stop.log`, `memory-panel-details.log`
-   `memory-investigation.jsonl`, `memory-process-inventory.json`
-   `codex-renderer-vmmap.txt`
-   Prior capped-build measurements: `memory-build-samples.log`,
    `memory-post-wire-build.log`

## Emulator follow-up after the user's attribution

The user identified the emulator and Codex as the affected applications.
The installed emulator is 37.2.12.0. Its last runtime settings were 2560 MiB
guest RAM, 1080 x 2424 display and Lavapipe rendering, despite the saved AVD
configuration specifying `2G`. A fresh launch requesting 2048 MiB also logged
`Increasing RAM size to 2560MB`; guest RAM is not a reliable 2 GiB host-process
cap on this system.

A crash-report consent dialog blocked the visible launch. No crash report was
sent. The owned engine did not respond to SIGTERM and was force-stopped. A
premature headless retry was rejected by the existing AVD lock; it created no
second VM. The successful trial started after the original handle was terminal.

The headless, no-snapshot, no-audio trial ran for four minutes, with a 6 GiB
summed-RSS stop guard and a system-memory-pressure guard. TAGGR booted and was
force-stopped/restarted five times, with no build running. The trial recorded
117 samples, peaked at 5837 MiB summed host RSS, and exited normally (code 0).
RSS later fell to approximately 3.7 GiB. `vmmap` showed physical footprint of
5.6 GiB during the trial and 5.7 GiB near the end. TAGGR itself used 83,723 KiB
PSS and 154,816 KiB RSS early in the trial, including 11,812 KiB of bitmaps.
This confirms substantial emulator-host overhead relative to the guest app.
It does not reproduce prolonged runaway growth, rule out a visible-window or
snapshot-specific problem, or establish a leak fix.

The older TAGGR Java PIDs were confirmed absent. A `gradlew --stop` check
reported no running daemons; it cannot be credited with stopping processes that
had already exited.

[Official emulator release notes](https://developer.android.com/studio/releases/emulator)
list host activity-open/close leak fixes in 36.4.9 and a macOS 26.3 Hypervisor
cleanup leak fix in 36.6.11. These predate the installed version; updating alone
cannot be assumed to resolve this incident on macOS 27.

Use bounded emulator sessions after compilation, avoid snapshot restoration
while isolating the issue, and close the owned emulator after device checks.
Keep Codex image/log output small. These workload limits do not repair Codex
renderer/plugin retention. Preserve the full Android feature goal while making
verification batches short.

Additional ignored evidence: `emulator-memory-check.py`,
`emulator-memory-test.jsonl`, `emulator-memory-result.json`,
`emulator-memory-launch.log`, `emulator-vmmap-test.txt`,
`emulator-vmmap-test-end.txt`.

## Resume guard — 2026-10-08

The bounded runner now rejects active Gradle/Kotlin Java processes before AVD
launch and stops its owned AVD if a build starts during observation. It measures
both GUI and CLI Codex processes by executable name, preserving macOS paths with
spaces and ignoring shell command text. Aggregate Codex RSS growth over 1,024 MiB
from the pre-launch baseline also stops only the owned AVD; it never terminates
Codex or another user's build. This threshold is a workload guard, not a diagnosis
of a memory leak. Existing 6 GiB emulator RSS, 15% host free-memory and elapsed-time
guards remain in place. RSS sums can double-count shared physical pages.

Three process-attribution regression tests pass (`python3
android/scripts/test-memory-guard.py`). A short real AVD launch/idle/shutdown run
passed in `emulator-check-20261008-142650`: emulator peak RSS 4,554 MiB, aggregate
Codex baseline 2,481 MiB and peak 2,486 MiB, no guard fired, emulator exit 0.
Evidence is in `.build/android/memory-resume-guard.log` and that run's
`memory.jsonl` / `summary.json`. This run did not execute app feature tests or
prove long-session memory stability. The latest app checkpoint remains 252 JVM
cases per variant and 27 selected Android cases, with authenticated background
YouTube transfer and the other documented parity gaps still pending.

## Codex growth guard observed — 2026-10-08

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

## Android 13 resume memory observation — 2026-10-08

Two selected actual API 33 batches passed (19 cases in 171913 and 12 ordinary
UI/media cases in 172458), with peak emulator RSS 5,481 and 5,682 MiB respectively.
The latter Codex baseline/peak was 3,502/3,623 MiB. Both checks had no guard trigger
and normal owned-AVD shutdown; these counts do not cover every authenticated flow.

A separate boot plus 180-second idle observation passed in
emulator-check-20261008-172649, with 343 memory samples and exit 0. Emulator peak
was 5,062 MiB; Codex baseline/peak was 3,552/3,586 MiB; host free-memory percentage
never fell below 84%. Between elapsed seconds 60 and 180, emulator RSS ranged
5,036–5,062 MiB (early/late median 5,039/5,060), while Codex ranged 3,420–3,580 MiB
(early/late median 3,549/3,496). The exact window and values are recorded in
idle-memory-observation.json. The emulator shows a small increase over this short
window; this is not prolonged stability evidence or a leak diagnosis. Idle
observation executes no app interaction or upload workload. No limits were raised,
no Codex process was terminated and no build overlapped the emulator.

The normal API 33 compatibility AVD is retained. The separate fresh-state Cold AVD
created solely for notification reproduction was removed after every owned check
reached terminal shutdown; the shared SDK image was retained. Python compilation,
three attribution checks and cargo format/check pass. The final 19-case rerun
passed but the initial one-off paused-notification miss remains unexplained.
Actual Google transfer, older-than-33 devices, visible/snapshot-specific behavior
and long-session leak resolution remain open.
