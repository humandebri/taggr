package org.taggr.android

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.os.LocaleList
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Locale
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.FeedMode
import org.taggr.android.data.PostRepository
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.TaggrTheme

/** Actual ML Kit language detection, Wi-Fi model download and on-device translation. */
@RunWith(AndroidJUnit4::class)
class RealPostTranslationUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun normalTranslateButtonProducesJapaneseAndPreservesCode() {
        val body =
            "Welcome to the TAGGR community. Thank you for reading this post.\n\n" +
                "- We hope you have a wonderful day.\n\n```kotlin\nval x = 42\n```"
        val post = TaggrPost(9230, "Alice", body, null, 0, emptyList(), 0, 0, null)
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        compose.setContent {
            val config =
                Configuration(LocalConfiguration.current).apply {
                    setLocales(LocaleList(Locale.JAPANESE))
                }
            CompositionLocalProvider(LocalConfiguration provides config) {
                TaggrTheme { TaggrApp(model, account) }
            }
        }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        compose.onNodeWithText("Translate with Google").performScrollTo().performClick()
        compose.waitUntil(170_000) {
            compose
                .onAllNodesWithTag("post-translation-9230", useUnmergedTree = true)
                .fetchSemanticsNodes()
                .isNotEmpty() ||
                compose
                    .onAllNodesWithText("Translation unavailable.", substring = true)
                    .fetchSemanticsNodes()
                    .isNotEmpty() ||
                compose
                    .onAllNodesWithText("Translation timed out.", substring = true)
                    .fetchSemanticsNodes()
                    .isNotEmpty()
        }
        val result =
            compose.onNodeWithTag("post-translation-9230", useUnmergedTree = true).performScrollTo()
        val text =
            result.fetchSemanticsNode().config[SemanticsProperties.Text].joinToString("") {
                it.text
            }
        assertTrue(
            "Expected Japanese output, received: $text",
            text.any { it in '\u3040'..'\u30ff' || it in '\u4e00'..'\u9fff' },
        )
        assertTrue(text.contains("val x = 42"))
        assertTrue(text.contains("• "))
        assertFalse(text.contains("```"))
        capture()
        compose.onNodeWithText("Hide translation").performScrollTo().performClick()
        compose.onNodeWithTag("post-translation-9230", useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithTag("post-body-9230-0", useUnmergedTree = true).assertExists()
        // With the cached models, the same real engine must work without any active network.
        val wifi = shell("settings get global wifi_on").trim() == "1"
        val mobile = shell("settings get global mobile_data").trim() == "1"
        val connectivity =
            InstrumentationRegistry.getInstrumentation()
                .targetContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            shell("svc wifi disable")
            shell("svc data disable")
            compose.waitUntil(10_000) { connectivity.activeNetwork == null }
            compose.onNodeWithText("Translate with Google").performScrollTo().performClick()
            compose.waitUntil(30_000) {
                compose
                    .onAllNodesWithTag("post-translation-9230", useUnmergedTree = true)
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            compose
                .onNodeWithTag("post-translation-9230", useUnmergedTree = true)
                .assertTextEquals(text)
            compose.onNodeWithContentDescription("Powered by Google Translate").assertExists()
            compose.onNodeWithText("Hide translation").performScrollTo().performClick()
        } finally {
            shell("svc wifi ${if (wifi) "enable" else "disable"}")
            shell("svc data ${if (mobile) "enable" else "disable"}")
        }
        compose.runOnIdle { assertNull(model.detail.value) }
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(
                InstrumentationRegistry.getInstrumentation()
                    .uiAutomation
                    .executeShellCommand(command)
            )
            .bufferedReader()
            .use { it.readText() }

    private fun capture() {
        val run = InstrumentationRegistry.getArguments().getString("ui_capture_run") ?: return
        require(run.matches(Regex("[0-9]{8}-[0-9]{6}")))
        val instrument = InstrumentationRegistry.getInstrumentation()
        val dir =
            File(
                requireNotNull(instrument.targetContext.getExternalFilesDir(null)),
                "ui-checks/$run",
            )
        check(dir.isDirectory || dir.mkdirs())
        val bitmap = requireNotNull(instrument.uiAutomation.takeScreenshot())
        try {
            File(dir, "post-real-translation.png").outputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally {
            bitmap.recycle()
        }
    }
}
