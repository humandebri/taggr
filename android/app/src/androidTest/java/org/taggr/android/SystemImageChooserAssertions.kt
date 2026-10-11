package org.taggr.android

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*

private fun activityDump(): String {
    val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
    return automation.executeShellCommand("dumpsys activity activities").use { descriptor ->
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use {
            it.readText()
        }
    }
}

private fun resumedLine(): String =
    activityDump()
        .lineSequence()
        .firstOrNull {
            "topResumedActivity=" in it || "mResumedActivity:" in it
        }
        .orEmpty()

internal fun assertSystemImageChooserAndCancel(
    capturePrefix: String,
    advanceFrame: () -> Unit = {},
) {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    try {
        val deadline = SystemClock.elapsedRealtime() + 15000
        while ("ChooserActivity" !in resumedLine() && SystemClock.elapsedRealtime() < deadline) {
            advanceFrame()
            SystemClock.sleep(200)
        }
        fun chooserLabels(): String {
            val root = instrumentation.uiAutomation.rootInActiveWindow ?: return ""
            fun walk(node: android.view.accessibility.AccessibilityNodeInfo): String = buildString {
                append(node.text?.toString().orEmpty())
                    .append(' ')
                    .append(node.contentDescription?.toString().orEmpty())
                    .append('\n')
                for (index in 0 until node.childCount) node.getChild(index)?.let {
                    append(walk(it))
                }
            }

            return walk(root)
        }
        val drawnDeadline = SystemClock.elapsedRealtime() + 15000
        var labels = chooserLabels()
        while (!labels.contains("Apps list") && SystemClock.elapsedRealtime() < drawnDeadline) {
            advanceFrame()
            SystemClock.sleep(200)
            labels = chooserLabels()
        }
        val opened = activityDump()
        val run = InstrumentationRegistry.getArguments().getString("ui_capture_run")
        val output =
            if (run != null) File(context.getExternalFilesDir(null), "ui-checks/$run")
            else context.cacheDir
        check(output.mkdirs() || output.isDirectory)
        File(output, "$capturePrefix-activity.txt").writeText(opened)
        File(output, "$capturePrefix-accessibility.txt").writeText(labels)
        val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(output, "$capturePrefix.png").outputStream().use {
            check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        screenshot.recycle()
        assertTrue(labels, labels.contains("Apps list"))
        assertTrue(opened, "ChooserActivity" in resumedLine())
    } finally {
        instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_BACK").close()
    }
    val deadline = SystemClock.elapsedRealtime() + 10000
    while (
        "org.taggr.android/.MainActivity" !in resumedLine() &&
            SystemClock.elapsedRealtime() < deadline
    ) {
        SystemClock.sleep(200)
    }
    assertTrue(resumedLine(), "org.taggr.android/.MainActivity" in resumedLine())
}
