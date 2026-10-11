package org.taggr.android

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class SelectedVideoPreviewUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun players(view: View): List<SelectedVideoView> =
        if (view is SelectedVideoView) listOf(view)
        else if (view is ViewGroup)
            (0 until view.childCount).flatMap { players(view.getChildAt(it)) }
        else emptyList()

    /** Local 3-second AVC fixture, generated using Android's codec; no downloaded media. */
    private fun video(file: File) {
        val encoder = MediaCodec.createEncoderByType("video/avc")
        val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
            val format =
                MediaFormat.createVideoFormat("video/avc", 64, 64).apply {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, 64000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, 15)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                }
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            val frame =
                ByteArray(64 * 64 * 3 / 2) { if (it < 64 * 64) 100.toByte() else 128.toByte() }
            val info = MediaCodec.BufferInfo()
            var inputFrames = 0
            var sentEnd = false
            var track = -1
            val deadline = SystemClock.elapsedRealtime() + 15000
            while (true) {
                check(SystemClock.elapsedRealtime() < deadline) { "Fixture encoding timed out" }
                if (!sentEnd) {
                    val index = encoder.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val end = inputFrames == 45
                        encoder.getInputBuffer(index)!!.apply {
                            clear()
                            if (!end) put(frame)
                        }
                        encoder.queueInputBuffer(
                            index,
                            0,
                            if (end) 0 else frame.size,
                            inputFrames * 1000000L / 15,
                            if (end) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0,
                        )
                        inputFrames++
                        sentEnd = end
                    }
                }
                val output = encoder.dequeueOutputBuffer(info, 10000)
                if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                    started = true
                } else if (output >= 0) {
                    if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        check(started)
                        muxer.writeSampleData(track, encoder.getOutputBuffer(output)!!, info)
                    }
                    encoder.releaseOutputBuffer(output, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            runCatching { encoder.stop() }
            encoder.release()
            if (started) muxer.stop()
            muxer.release()
        }
    }

    private fun <T> main(block: () -> T): T {
        var result: T? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    @Test
    fun nativeLocalPlaybackPausesInBackgroundAndReleasesOnReplacementAndClose() {
        val directory = File(context.cacheDir, "taggr-shared-images").apply { mkdirs() }
        val first = File(directory, "preview-${UUID.randomUUID()}.mp4")
        val second = File(directory, "preview-${UUID.randomUUID()}.mp4")
        try {
            video(first)
            first.copyTo(second)
            val selected =
                mutableStateOf(
                    FileProvider.getUriForFile(context, "${context.packageName}.images", first)
                )
            val show = mutableStateOf(true)
            compose.setContent {
                TaggrTheme {
                    Column(
                        Modifier.fillMaxSize()
                            .safeDrawingPadding()
                            .verticalScroll(rememberScrollState())
                    ) {
                        if (show.value)
                            YouTubeUploadForm(
                                true,
                                false,
                                false,
                                {},
                                { error("Unexpected upload") },
                                selected.value,
                            )
                    }
                }
            }
            compose.waitUntil(10000) {
                main { players(compose.activity.window.decorView).singleOrNull()?.duration ?: 0 } >
                    1000
            }
            val original = main { players(compose.activity.window.decorView).single() }
            assertFalse(main { original.isPlaying })
            compose.onNodeWithContentDescription("Video preview position").performSemanticsAction(
                SemanticsActions.SetProgress
            ) {
                assertTrue(it(1000f))
            }
            compose.waitUntil(5000) { main { original.currentPosition } in 750..1250 }
            assertFalse(main { original.isPlaying })
            val stamp = InstrumentationRegistry.getArguments().getString("ui_capture_run")
            if (stamp != null) {
                compose.waitForIdle()
                val bitmap =
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    )
                val captures =
                    File(context.getExternalFilesDir(null), "ui-checks/$stamp").apply { mkdirs() }
                File(captures, "selected-video-preview.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }
            val seekedPosition = main { original.currentPosition }
            compose.onNodeWithText("Play preview").assertIsEnabled().performClick()
            compose.waitUntil(5000) { main { original.currentPosition } > seekedPosition + 100 }
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertFalse(main { original.isPlaying })
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            assertFalse(main { original.isPlaying })
            val position = main { original.currentPosition }
            compose.onNodeWithText("Play preview").performClick()
            compose.waitUntil(5000) { main { original.currentPosition } > position + 100 }
            compose.runOnIdle {
                selected.value =
                    FileProvider.getUriForFile(context, "${context.packageName}.images", second)
            }
            compose.waitUntil(10000) {
                main {
                    original.released &&
                        (players(compose.activity.window.decorView).singleOrNull()?.duration ?: 0) >
                            1000
                }
            }
            val replacement = main { players(compose.activity.window.decorView).single() }
            assertNotSame(original, replacement)
            assertFalse(main { replacement.isPlaying })
            assertTrue(main { replacement.currentPosition } < 500)
            compose.runOnIdle { show.value = false }
            compose.waitForIdle()
            assertTrue(main { replacement.released })
            assertTrue(main { players(compose.activity.window.decorView).isEmpty() })
        } finally {
            first.delete()
            second.delete()
        }
    }

    @Test
    fun pausedSeekRestoresOnlyForSameUriAndDoesNotRestartPlayback() {
        val directory = File(context.cacheDir, "taggr-shared-images").apply { mkdirs() }
        val first = File(directory, "preview-${UUID.randomUUID()}.mp4")
        val second = File(directory, "preview-${UUID.randomUUID()}.mp4")
        try {
            video(first)
            first.copyTo(second)
            val selected =
                mutableStateOf(
                    FileProvider.getUriForFile(context, "${context.packageName}.images", first)
                )
            val restoration = StateRestorationTester(compose)
            restoration.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        SelectedVideoPreview(selected.value)
                    }
                }
            }
            compose.waitUntil(10000) {
                main { players(compose.activity.window.decorView).singleOrNull()?.duration ?: 0 } >
                    1000
            }
            val original = main { players(compose.activity.window.decorView).single() }
            compose.onNodeWithContentDescription("Video preview position").performSemanticsAction(
                SemanticsActions.SetProgress
            ) {
                assertTrue(it(2000f))
            }
            compose.waitUntil(5000) { main { original.currentPosition } in 1750..2250 }
            compose.waitForIdle()
            restoration.emulateSavedInstanceStateRestore()
            compose.waitUntil(10000) {
                main {
                    val current = players(compose.activity.window.decorView).singleOrNull()
                    original.released &&
                        current != null &&
                        current !== original &&
                        current.currentPosition in 1750..2250
                }
            }
            assertFalse(main { players(compose.activity.window.decorView).single().isPlaying })
            val restored = main { players(compose.activity.window.decorView).single() }
            compose.runOnIdle {
                selected.value =
                    FileProvider.getUriForFile(context, "${context.packageName}.images", second)
            }
            compose.waitUntil(10000) {
                main {
                    val current = players(compose.activity.window.decorView).singleOrNull()
                    restored.released &&
                        current != null &&
                        current !== restored &&
                        current.duration > 1000
                }
            }
            assertTrue(
                main { players(compose.activity.window.decorView).single().currentPosition } < 500
            )
            assertFalse(main { players(compose.activity.window.decorView).single().isPlaying })
        } finally {
            first.delete()
            second.delete()
        }
    }

    @Test
    fun failedLocalVideoReleasesPlayerAndValidReplacementCanPlay() {
        val directory = File(context.cacheDir, "taggr-shared-images").apply { mkdirs() }
        val invalid = File(directory, "preview-${UUID.randomUUID()}.mp4")
        val valid = File(directory, "preview-${UUID.randomUUID()}.mp4")
        try {
            invalid.writeText("This is not a video")
            video(valid)
            val selected =
                mutableStateOf(
                    FileProvider.getUriForFile(context, "${context.packageName}.images", invalid)
                )
            compose.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        SelectedVideoPreview(selected.value)
                    }
                }
            }
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithText("Video preview unavailable. You can choose another video.")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            val failed = main { players(compose.activity.window.decorView).single() }
            assertTrue(
                "Failed preview must release its owned media player",
                main { failed.released },
            )
            compose.onNodeWithText("Play preview").assertDoesNotExist()
            compose.runOnIdle {
                selected.value =
                    FileProvider.getUriForFile(context, "${context.packageName}.images", valid)
            }
            compose.waitUntil(10000) {
                main { players(compose.activity.window.decorView).singleOrNull()?.duration ?: 0 } >
                    1000
            }
            val replacement = main { players(compose.activity.window.decorView).single() }
            assertNotSame(failed, replacement)
            compose.onNodeWithText("Play preview").performClick()
            compose.waitUntil(5000) { main { replacement.currentPosition } > 100 }
        } finally {
            invalid.delete()
            valid.delete()
        }
    }

    @Test
    fun deniedContentProviderReleasesPlayerAndAllowsValidReplacement() {
        val denied = Uri.parse("content://org.taggr.android.test.denied-video/expired.mp4")
        fun attempts() =
            context.contentResolver.call(denied, "attempts", null, null)!!.getInt("count")
        assertThrows(SecurityException::class.java) {
            context.contentResolver.openFileDescriptor(denied, "r")?.close()
        }
        val before = attempts()
        val directory = File(context.cacheDir, "taggr-shared-images").apply { mkdirs() }
        val valid = File(directory, "preview-${UUID.randomUUID()}.mp4")
        try {
            video(valid)
            val selected = mutableStateOf(denied)
            compose.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        SelectedVideoPreview(selected.value)
                    }
                }
            }
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithText("Video preview unavailable. You can choose another video.")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            assertTrue(
                "The actual VideoView must open the rejecting Binder provider",
                attempts() > before,
            )
            val failed = main { players(compose.activity.window.decorView).single() }
            assertTrue(main { failed.released })
            compose.onNodeWithText("Play preview").assertDoesNotExist()
            compose.runOnIdle {
                selected.value =
                    FileProvider.getUriForFile(context, "${context.packageName}.images", valid)
            }
            compose.waitUntil(10000) {
                main { players(compose.activity.window.decorView).singleOrNull()?.duration ?: 0 } >
                    1000
            }
            val replacement = main { players(compose.activity.window.decorView).single() }
            assertNotSame(failed, replacement)
            compose.onNodeWithText("Play preview").performClick()
            compose.waitUntil(5000) { main { replacement.currentPosition } > 100 }
        } finally {
            valid.delete()
        }
    }

    @Test
    fun remoteVideoUriDoesNotCreatePlayer() {
        compose.setContent {
            TaggrTheme { SelectedVideoPreview(Uri.parse("https://example.test/video.mp4")) }
        }
        compose
            .onNodeWithText("Video preview unavailable. Choose the video again.")
            .assertIsDisplayed()
        assertTrue(main { players(compose.activity.window.decorView).isEmpty() })
    }
}
