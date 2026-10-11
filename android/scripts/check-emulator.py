#!/usr/bin/env python3
"""Run a bounded macOS Android check, then shut down only the AVD we started."""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time


def process_rows():
    rows = [line.split(None, 3) for line in subprocess.check_output(
        ["ps", "-axo", "pid,ppid,rss,comm"], text=True, timeout=5
    ).splitlines()[1:]]
    commands = dict(line.split(None, 1) for line in subprocess.check_output(
        ["ps", "-axo", "pid,args"], text=True, timeout=5
    ).splitlines()[1:] if len(line.split(None, 1)) == 2)
    return [row + [commands.get(row[0], "")] for row in rows if len(row) == 4]


def codex_rss(rows):
    # Include the CLI as well as GUI helpers; macOS process names contain spaces.
    return sum(int(row[2]) for row in rows
               if len(row) >= 4 and "codex" in row[3].casefold())


def codex_snapshot(rows):
    # Keep per-PID evidence without command arguments, which may contain private data.
    return [{"pid": int(row[0]), "ppid": int(row[1]), "rss_kib": int(row[2]), "comm": row[3]}
            for row in rows if len(row) >= 4 and "codex" in row[3].casefold()]


def build_pids(rows):
    markers = ("org.gradle.launcher.daemon.bootstrap.GradleDaemon",
               "org.gradle.launcher.GradleMain",
               "org.gradle.wrapper.GradleWrapperMain",
               "org.jetbrains.kotlin.daemon.KotlinCompileDaemon")
    return [int(row[0]) for row in rows if len(row) >= 5
            and Path(row[3]).name == "java"
            and any(marker in row[4] for marker in markers)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--avd", required=True)
    parser.add_argument("--port", type=int, default=5556)
    parser.add_argument("--public-video-process-post", type=int, help="Recover this public video post through a killed normal app process")
    parser.add_argument("--classes", help="Comma-separated Android test classes/methods")
    parser.add_argument("--pull-ui-captures", action="store_true",
                        help="Pass a unique screenshot run ID to fixtures and pull their app-specific captures")
    parser.add_argument("--idle-seconds", type=int, default=30)
    parser.add_argument("--timeout-seconds", type=int, default=240)
    parser.add_argument("--max-codex-growth-mib", type=int, default=1024,
                        help="Stop our AVD if aggregate Codex RSS grows this much from launch")
    args = parser.parse_args()
    if not 5554 <= args.port <= 5682 or args.port % 2:
        parser.error("Use an even emulator port from 5554 to 5682")
    if args.timeout_seconds <= 0 or args.idle_seconds < 0 or args.max_codex_growth_mib <= 0:
        parser.error("Timeout must be positive and idle duration nonnegative")
    if args.public_video_process_post is not None and (args.public_video_process_post <= 0 or args.classes or args.pull_ui_captures):
        parser.error("Use a positive public video post ID without instrumentation/capture flags")
    if args.classes and not re.fullmatch(r"[A-Za-z0-9_.$#,]+", args.classes):
        parser.error("Invalid test class filter")
    if args.pull_ui_captures and not args.classes:
        parser.error("--pull-ui-captures requires --classes")

    root = Path(__file__).resolve().parents[2]
    initial_rows = process_rows()
    builds = build_pids(initial_rows)
    if builds:
        raise RuntimeError(f"Build processes are active ({builds}); finish the build before the AVD")
    codex_baseline = codex_rss(initial_rows)
    codex_peak = codex_baseline
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = str(sdk / "platform-tools/adb")
    serial = f"emulator-{args.port}"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output = root / ".build/android" / f"emulator-check-{stamp}"
    output.mkdir(parents=True, exist_ok=False)
    (output / "codex-baseline.json").write_text(json.dumps(codex_snapshot(initial_rows), indent=2) + "\n")
    devices = subprocess.check_output([adb, "devices"], text=True, timeout=10)
    if re.search(r"^emulator-\d+\s", devices, re.MULTILINE):
        raise RuntimeError("An emulator is already running; leave it alone")
    available = subprocess.check_output(
        [str(sdk / "emulator/emulator"), "-list-avds"], text=True, timeout=10
    ).splitlines()
    if args.avd not in available:
        raise RuntimeError("Requested AVD does not exist")

    def adb_run(*command, timeout=20):
        return subprocess.run(
            [adb, "-s", serial, *command],
            capture_output=True, text=True, timeout=timeout,
        )

    started = time.monotonic()
    stopped = threading.Event()
    failures = []
    peak = 0
    passed = False
    device_api = None
    with (output / "emulator.log").open("w") as emulator_log:
        emulator = subprocess.Popen(
            [str(sdk / "emulator/emulator"), "-avd", args.avd, "-port", str(args.port),
             "-memory", "2048", "-lowram", "-gpu", "lavapipe",
             "-no-snapshot", "-no-audio", "-no-window"],
            stdout=emulator_log, stderr=subprocess.STDOUT, start_new_session=True,
        )

        def watch():
            nonlocal peak, codex_peak
            try:
                with (output / "memory.jsonl").open("w") as samples:
                    while not stopped.wait(0.5) and emulator.poll() is None:
                        rows = process_rows()
                        owned = {emulator.pid}
                        while True:
                            expanded = owned | {int(row[0]) for row in rows
                                                if len(row) >= 4 and int(row[1]) in owned}
                            if expanded == owned:
                                break
                            owned = expanded
                        rss = sum(int(row[2]) for row in rows
                                  if len(row) >= 4 and int(row[0]) in owned)
                        peak = max(peak, rss)
                        codex_current = codex_rss(rows)
                        codex_peak = max(codex_peak, codex_current)
                        pressure = subprocess.check_output(
                            ["memory_pressure", "-Q"], text=True, timeout=5
                        )
                        free = re.search(r"free percentage: (\d+)%", pressure)
                        if free is None:
                            raise RuntimeError("Cannot read host memory pressure")
                        elapsed = time.monotonic() - started
                        samples.write(json.dumps({
                            "elapsed_s": round(elapsed, 1), "emulator_rss_mib": round(rss / 1024),
                            "host_free_percent": int(free[1]),
                            "codex_total_rss_mib": round(codex_current / 1024),
                            "codex_growth_mib": round((codex_current - codex_baseline) / 1024),
                            "codex_processes": codex_snapshot(rows),
                        }) + "\n")
                        samples.flush()
                        if rss > 6 * 1024 * 1024:
                            raise RuntimeError("Emulator RSS exceeded 6 GiB")
                        if codex_current - codex_baseline > args.max_codex_growth_mib * 1024:
                            raise RuntimeError("Codex RSS growth exceeded the configured limit")
                        if build_pids(rows):
                            raise RuntimeError("Build started while the emulator was running")
                        if int(free[1]) < 15:
                            raise RuntimeError("Host free memory fell below 15%")
                        if elapsed > args.timeout_seconds:
                            raise RuntimeError("Emulator time limit exceeded")
            except Exception as error:
                failures.append(str(error))
                if emulator.poll() is None:
                    try:
                        os.killpg(emulator.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass

        monitor = threading.Thread(target=watch, daemon=True)
        monitor.start()

        def healthy():
            if failures or emulator.poll() is not None:
                raise RuntimeError("; ".join(failures) or "Emulator exited unexpectedly")

        try:
            deadline = started + min(120, args.timeout_seconds)
            while time.monotonic() < deadline:
                healthy()
                if adb_run("shell", "getprop", "sys.boot_completed", timeout=5).stdout.strip() == "1":
                    break
                time.sleep(1)
            else:
                raise RuntimeError("Emulator boot timed out")
            api_result = adb_run("shell", "getprop", "ro.build.version.sdk", timeout=5)
            if api_result.returncode or not api_result.stdout.strip().isdigit():
                raise RuntimeError("Cannot identify the actual guest Android API")
            device_api = int(api_result.stdout.strip())
            (output / "device-api.txt").write_text(str(device_api) + "\n")
            healthy()
            if args.public_video_process_post is not None:
                from video_process_recovery import check
                installed = adb_run("install", "-r", str(root / "android/app/build/outputs/apk/debug/app-debug.apk"), timeout=40)
                if installed.returncode:
                    raise RuntimeError("APK installation failed: " + installed.stdout + installed.stderr)
                config = (root / "android/app/build/generated/source/buildConfig/debug/org/taggr/android/BuildConfig.java").read_text()
                domain = re.search(r'TAGGR_DOMAIN = "([a-zA-Z0-9.-]+)"', config)
                if not domain:
                    raise RuntimeError("Cannot read the current public app domain")
                check(adb_run, healthy, output, args.public_video_process_post, domain[1])
            elif args.classes:
                for apk in ("debug/app-debug.apk", "androidTest/debug/app-debug-androidTest.apk"):
                    installed = adb_run("install", "-r", str(root / "android/app/build/outputs/apk" / apk), timeout=40)
                    if installed.returncode:
                        raise RuntimeError("APK installation failed: " + installed.stdout + installed.stderr)
                    healthy()
                instrument = ["shell", "am", "instrument", "-w", "-r", "-e", "class", args.classes]
                if args.pull_ui_captures:
                    instrument += ["-e", "ui_capture_run", stamp]
                instrument += ["org.taggr.android.test/androidx.test.runner.AndroidJUnitRunner"]
                try:
                    result = adb_run(*instrument, timeout=args.timeout_seconds)
                except subprocess.TimeoutExpired as error:
                    # Preserve partial instrumentation evidence before owned-AVD cleanup.
                    partial = []
                    for chunk in (error.stdout, error.stderr):
                        if isinstance(chunk, bytes):
                            partial.append(chunk.decode("utf-8", errors="replace"))
                        elif chunk:
                            partial.append(chunk)
                    (output / "tests.log").write_text("".join(partial))
                    raise
                (output / "tests.log").write_text(result.stdout + result.stderr)
                healthy()
                match = re.search(r"OK \((\d+) tests?\)", result.stdout)
                tests_failed = bool(result.returncode or not match or "FAILURES!!!" in result.stdout)
                if args.pull_ui_captures:
                    pulled = adb_run("pull", f"/sdcard/Android/data/org.taggr.android/files/ui-checks/{stamp}",
                                     str(output / "ui-captures"), timeout=20)
                    (output / "captures.log").write_text(pulled.stdout + pulled.stderr)
                    if (pulled.returncode or not list((output / "ui-captures").glob("*.png"))) and not tests_failed:
                        raise RuntimeError("Requested fixture captures were not available")
                    healthy()
                if tests_failed:
                    raise RuntimeError("Device tests failed; inspect tests.log and captures.log when requested")
                print(f"Passed {match[1]} device tests", flush=True)
            else:
                for _ in range(args.idle_seconds):
                    healthy()
                    time.sleep(1)
            healthy()
            passed = True
        finally:
            # Keep the monitor active through shutdown; never leave a background AVD.
            if emulator.poll() is None:
                try:
                    adb_run("emu", "kill", timeout=10)
                    emulator.wait(timeout=15)
                except (subprocess.TimeoutExpired, OSError):
                    if emulator.poll() is None:
                        os.killpg(emulator.pid, signal.SIGKILL)
                        emulator.wait(timeout=10)
            stopped.set()
            monitor.join(timeout=12)
            if emulator.returncode != 0:
                failures.append(f"Emulator shutdown exited with {emulator.returncode}")
            summary = {"passed": passed and not failures, "device_api": device_api, "peak_emulator_rss_mib": round(peak / 1024),
                       "codex_baseline_rss_mib": round(codex_baseline / 1024),
                       "codex_peak_rss_mib": round(codex_peak / 1024),
                       "max_codex_growth_mib": args.max_codex_growth_mib,
                       "guard": failures, "emulator_exit": emulator.returncode, "logs": str(output)}
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(json.dumps(summary), flush=True)
            if failures:
                raise RuntimeError("; ".join(failures))


if __name__ == "__main__":
    main()
