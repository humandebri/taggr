package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class YouTubeUploadFormUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun ordinarySheetOpensWithoutConsentOrUploadAndCloses() {
        val open = mutableStateOf(true)
        compose.setContent {
            TaggrTheme {
                if (open.value)
                    YouTubeUploadScreen(
                        "owner",
                        "network",
                        "canister",
                        "new",
                        { "owner" },
                        { error("Unexpected insertion") },
                        { open.value = false },
                    )
            }
        }
        compose.onNodeWithText("YouTube Upload").assertIsDisplayed()
        compose.onNodeWithText("Connect YouTube").assertIsDisplayed()
        compose.onNodeWithText("Choose video").assertIsDisplayed()
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val stamp = InstrumentationRegistry.getArguments().getString("ui_capture_run")
        if (stamp != null) {
            val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            val directory =
                File(instrumentation.targetContext.getExternalFilesDir(null), "ui-checks/$stamp")
                    .apply { mkdirs() }
            File(directory, "youtube-upload-sheet.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("YouTube Upload").assertDoesNotExist()
        compose.runOnIdle { Assert.assertFalse(open.value) }
    }

    @Test
    fun explicitAudienceAndConsentAreRequiredAndDefaultPrivacyIsUnlisted() {
        var submitted: YouTubeUploadMetadata? = null
        val connected = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val video = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    YouTubeUploadForm(
                        video.value,
                        busy.value,
                        connected.value,
                        choose = { video.value = true },
                        upload = { submitted = it },
                    )
                }
            }
        }
        compose.onNodeWithText("Choose video").performScrollTo().performClick()
        compose.onNodeWithText("Title").performScrollTo().performTextInput("Example video")
        compose.onNodeWithText("Upload to YouTube").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("No").performScrollTo().performClick()
        compose
            .onNodeWithContentDescription("Accept YouTube terms and community guidelines")
            .performScrollTo()
            .performClick()
        compose.onNodeWithText("Upload to YouTube").performScrollTo().assertIsNotEnabled()
        compose.runOnIdle { connected.value = true }
        compose.onNodeWithText("Upload to YouTube").assertIsEnabled()
        compose.runOnIdle { busy.value = true }
        compose.onNodeWithText("Upload to YouTube").assertIsNotEnabled()
        compose.runOnIdle { busy.value = false }
        compose.onNodeWithText("Upload to YouTube").performClick()
        compose.runOnIdle {
            Assert.assertEquals("Example video", submitted!!.title)
            Assert.assertEquals(YouTubePrivacy.UNLISTED, submitted!!.privacy)
            Assert.assertEquals(false, submitted!!.madeForKids)
            Assert.assertTrue(submitted!!.communityGuidelinesAccepted)
            Assert.assertFalse(submitted!!.containsSyntheticMedia)
        }
    }

    @Test
    fun invalidUnicodeTitleAndUtf8DescriptionPreventDispatch() {
        var submissions = 0
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    YouTubeUploadForm(true, false, true, {}, { submissions++ })
                }
            }
        }
        compose.onNodeWithText("No").performScrollTo().performClick()
        compose
            .onNodeWithContentDescription("Accept YouTube terms and community guidelines")
            .performScrollTo()
            .performClick()
        compose
            .onNodeWithText("Title")
            .performScrollTo()
            .performTextInput("👨‍👩‍👧‍👦".repeat(101))
        compose.onNodeWithText("Upload to YouTube").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Title").performScrollTo().performTextReplacement("Valid")
        compose.onNodeWithText("Description").performScrollTo().performTextInput("界".repeat(1667))
        compose.onNodeWithText("Upload to YouTube").performScrollTo().assertIsNotEnabled()
        compose.runOnIdle { Assert.assertEquals(0, submissions) }
    }
}
