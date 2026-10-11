# Development resource limits

After a reported memory increase on October 2, 2026, development resumed with
bounded builds. The report's source has not yet been identified. A process snapshot
after the desktop app restarted does not establish what leaked before restart.

`gradle.properties` limits the Gradle heap to 1536 MiB and metaspace to 512 MiB,
uses at most two workers, disables parallel project execution and persistent
daemons, and runs the Kotlin compiler in process. These are workload limits, not
a proven fix for a leak. Native allocations and worker JVMs can still add memory
beyond the heap limit.

Run one heavy check at a time. Keep logs in `.build/android/`, return only the
result or an actionable error, and inspect screenshots only when needed. Do not
run an emulator, a local IC network and an uncached build together while
investigating memory pressure. Leave other tasks' processes alone.

The capped assemble/unit-test/Lint run and an uncached Kotlin compile passed.
A subsequent compile/unit-test/Lint run was sampled every 500 ms from process
launch: its new Java processes' combined RSS peaked at 1754 MiB over 39 samples,
and the run exited successfully. See `.build/android/memory-build-samples.log`
and `.build/android/memory-post-wire-build.log` for that measurement.
A short post-restart measurement
showed no sustained runaway growth; that does not rule out a long-session leak.
Raw measurements are in ignored `.build/android/memory-samples.log` and
`.build/android/memory-compile-samples.log`. Capture the affected process's RSS
over time before attributing a leak to TAGGR, the emulator, Gradle or Codex.

## Bounded emulator checks

The API 37.0 Google APIs ARM64 image is installed in the dedicated
`TAGGR_Auth_Pixel_9_API_37` AVD. Its Chrome reports 145.0.7632.218. During a
capability probe, the emulator increased requested RAM from 2 GiB to 4 GiB;
software-rendered process-tree RSS reached 7,275 MiB and triggered shutdown.
Changing only the renderer to `host` still exceeded the 6 GiB limit. That mode
also warned that hardware OpenGL rendering on macOS is deprecated.

The emulator's documented `-lowram` option removes the automatic RAM lower
bound ([upstream implementation](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/android/android-emu/android/main-common.c)).
With `-memory 2048 -lowram -gpu lavapipe`, the same AVD completed boot, browser
capability checks and a 60-second idle check with a sampled peak of 4,698 MiB.
This establishes a reduction for this short workload, not a long-session leak
fix or physical-device performance. `ro.config.low_ram` was empty; the flag
should not be interpreted as proof of Android Go runtime behavior.

Use the checked-in runner from the repository root after building the APKs:

```sh
python3 android/scripts/check-emulator.py \
    --avd TAGGR_Auth_Pixel_9_API_37 \
    --classes org.taggr.android.NormalAppNavigationTest,org.taggr.android.ProfileStatisticsNativeReadTest
```

It refuses to start while another emulator is present, uses a dedicated serial
and no snapshots, and samples emulator-tree RSS, aggregate Codex RSS and host
free memory every 500 ms. It stops its owned process group above 6 GiB RSS,
below 15% host free memory, on monitoring failure or after four minutes. These
are sampled termination thresholds; a burst can overshoot between samples.
It also shuts down after success or failure and records the result in ignored
`.build/android/emulator-check-*/`. A guard firing fails the check even if the
instrumentation reports success. Existing AVD data is preserved. Without a
class filter it performs a short boot/idle check and does not run the full suite.

Do not start a Gradle build concurrently with this runner. The earlier Codex
memory report remains unresolved; aggregate process RSS samples alone cannot
identify a leaking renderer or prove its correction.

The ordinary-app local-auth test also exposed a concrete cleanup issue in the
installed ICP network launcher: `icp network stop` reported success and its
launcher exited, but its owned PocketIC child retained the 18100 gateway and
51815 management port with a 30-day TTL. It was about 107 MiB RSS, not evidence
that it caused the originally reported emulator/Codex leak. The child PID and
command matched this turn's startup, and its management API listed exactly one
instance. Only that orphan was then terminated; both ports were checked closed.
After future local tests, verify the selected gateway actually closes rather
than treating the CLI message alone as proof. Never terminate another project's
or shared PocketIC process.
