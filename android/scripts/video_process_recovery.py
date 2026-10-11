"""Ordinary guest UI + saved task recovery, coordinated outside the killed app process."""
import json
import re
import time
import xml.etree.ElementTree as ET


def resumed_task_id(activity):
    # API 28 reports mResumedActivity; newer devices report topResumedActivity.
    match = re.search(
        r"(?:topResumedActivity=|mResumedActivity:\s*)ActivityRecord\{[^\n]*org\.taggr\.android/[^\n]* t(\d+)\}",
        activity,
    )
    return match[1] if match else None


def check(adb_run, healthy, output, post_id, domain):
    def command(*args, timeout=20):
        result = adb_run(*args, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout

    def tree(name):
        healthy()
        command("shell", "rm", "-f", "/sdcard/taggr-process-window.xml")
        command("shell", "uiautomator", "dump", "/sdcard/taggr-process-window.xml")
        text = command("exec-out", "cat", "/sdcard/taggr-process-window.xml")
        (output / f"{name}.xml").write_text(text)
        return ET.fromstring(text)

    def wait(name, predicate, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            current = tree(name)
            if predicate(current):
                return current
            time.sleep(1)
        raise RuntimeError(f"{name} not reached; inspect {name}.xml")

    def label(node):
        return " ".join(child.get("text", "") + " " + child.get("content-desc", "") for child in node.iter("node"))

    def has(root, text):
        return any(text in label(node) for node in root.iter("node"))

    def tap(node):
        bounds = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
        if len(bounds) != 4 or bounds[2] <= bounds[0] or bounds[3] <= bounds[1]:
            raise RuntimeError("Cannot tap an unplaced node")
        command("shell", "input", "tap", str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))

    def video_ready(root):
        return has(root, "Conversation") and any(node.get("class") == "android.webkit.WebView" for node in root.iter("node"))

    # Older am help returns a nonzero status even when it prints valid help.
    # This is diagnostic output, not a prerequisite for any checked command.
    help_result = adb_run("shell", "am", "help")
    (output / "activity-shell-help.txt").write_text(
        f"exit={help_result.returncode}\n" + help_result.stdout + help_result.stderr
    )
    command("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", f"https://{domain}/search/{post_id}", "-n", "org.taggr.android/.MainActivity")
    initial = tree("initial")
    if has(initial, "Agree and continue"):
        raise RuntimeError("Requires the previously consented guest test AVD; no terms state changed")
    search = wait("search", lambda root: has(root, "Search TAGGR") and any(node.get("clickable") == "true" and re.search(r"youtube|youtu\.be", label(node), re.I) for node in root.iter("node")))
    row = next(node for node in search.iter("node") if node.get("clickable") == "true" and re.search(r"youtube|youtu\.be", label(node), re.I))
    tap(row)
    wait("conversation-before", video_ready)
    original_pid = command("shell", "pidof", "org.taggr.android").strip()
    activity = command("shell", "dumpsys", "activity", "activities")
    (output / "activity-before.txt").write_text(activity)
    task_id = resumed_task_id(activity)
    if task_id is None:
        raise RuntimeError("Cannot identify our resumed saved task")
    command("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    command("shell", "am", "kill", "org.taggr.android")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        healthy()
        if not adb_run("shell", "pidof", "org.taggr.android").stdout.strip():
            break
        time.sleep(1)
    else:
        raise RuntimeError("Background process did not terminate")
    (output / "process-recovery.json").write_text(json.dumps({"original_pid": original_pid, "task_id": task_id, "post_id": post_id, "terminated": True}, indent=2))
    # A normal launcher intent raises the existing singleTop task without replaying a URL.
    command("shell", "am", "start", "-W", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", "org.taggr.android/.MainActivity", "-f", "0x10200000")
    new_pid = command("shell", "pidof", "org.taggr.android").strip()
    if not new_pid or new_pid == original_pid:
        raise RuntimeError("A distinct restored app process was not observed")
    restored_activity = command("shell", "dumpsys", "activity", "activities")
    (output / "activity-after.txt").write_text(restored_activity)
    restored_task = resumed_task_id(restored_activity)
    if restored_task is None or restored_task != task_id:
        raise RuntimeError("Launcher did not raise the original saved task")
    (output / "process-recovery.json").write_text(json.dumps({"original_pid": original_pid, "restored_pid": new_pid, "task_id": task_id, "post_id": post_id, "terminated": True, "same_task": True}, indent=2) + "\n")
    wait("conversation-after", video_ready)
    after = tree("conversation-after")
    back = next(node for node in after.iter("node") if node.get("clickable") == "true" and label(node).strip() == "Back")
    tap(back)
    wait("search-after", lambda root: has(root, "Search TAGGR") and has(root, str(post_id)))
    (output / "process-recovery.json").write_text(json.dumps({"original_pid": original_pid, "restored_pid": new_pid, "task_id": task_id, "post_id": post_id, "terminated": True, "same_task": True, "conversation_restored": True, "search_restored": True}, indent=2) + "\n")
    print("Passed normal-app video process recovery", flush=True)
