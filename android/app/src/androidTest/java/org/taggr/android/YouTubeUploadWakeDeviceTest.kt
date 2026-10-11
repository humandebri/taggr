package org.taggr.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.YouTubeUploadWake

/** Observe the OS lock itself, not a test substitute or only a coroutine flag. */
@RunWith(AndroidJUnit4::class)
class YouTubeUploadWakeDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun held(): Boolean {
        val descriptor = instrumentation.uiAutomation.executeShellCommand("dumpsys power")
        val text =
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use {
                it.readText()
            }
        return text.lineSequence().any {
            it.contains("PARTIAL_WAKE_LOCK") && it.contains("TAGGR:YouTubeUpload")
        }
    }

    @Test
    fun completionAndFailureReleaseActualCpuLock() = runBlocking {
        val wake = YouTubeUploadWake(instrumentation.targetContext)
        assertFalse(held())
        assertEquals(
            42,
            wake.run {
                assertTrue(held())
                42
            },
        )
        assertFalse(held())
        try {
            wake.run {
                assertTrue(held())
                error("fixture failure")
            }
            fail("Expected failure")
        } catch (_: IllegalStateException) {}
        assertFalse(held())
    }

    @Test
    fun cancellationAndTimeoutReleaseActualCpuLock() = runBlocking {
        val wake = YouTubeUploadWake(instrumentation.targetContext)
        val entered = CompletableDeferred<Unit>()
        val work = launch {
            wake.run {
                assertTrue(held())
                entered.complete(Unit)
                awaitCancellation()
            }
        }
        entered.await()
        work.cancelAndJoin()
        assertFalse(held())
        try {
            YouTubeUploadWake(instrumentation.targetContext, 200).run { awaitCancellation() }
            fail("Expected timeout")
        } catch (_: TimeoutCancellationException) {}
        assertFalse(held())
    }
}
