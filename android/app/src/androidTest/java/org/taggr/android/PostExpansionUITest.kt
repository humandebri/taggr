package org.taggr.android

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.LocalPostViewer
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostExpansionUITest {
    @get:Rule val compose = createComposeRule()

    private fun post(id: Long, body: String) =
        TaggrPost(
            id,
            "Alice",
            body,
            null,
            System.currentTimeMillis() - 3600000,
            emptyList(),
            0,
            0,
            null,
        )

    private fun layout(id: Long): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        compose.onNodeWithTag("post-body-$id-0", useUnmergedTree = true).performSemanticsAction(
            SemanticsActions.GetTextLayoutResult
        ) {
            it(results)
        }
        return results.single()
    }

    private fun capture(name: String) {
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
            File(dir, "$name.png").outputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally {
            bitmap.recycle()
        }
    }

    @Test
    fun restoredExpansionBelongsToTheSameBodyPostAndViewer() {
        var source = post(9110, "Summary\n\n\n\nRestored tail")
        var viewer: Long? = 7
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            CompositionLocalProvider(LocalPostViewer provides viewer) {
                TaggrTheme { Column { PostContent(source, false) } }
            }
        }
        compose.onNodeWithTag("show-full-post-9110").performClick()
        restoration.emulateSavedInstanceStateRestore()
        compose
            .onNodeWithText("Restored tail", substring = true, useUnmergedTree = true)
            .assertIsDisplayed()

        // Plain variables deliberately change only when the composition is recreated.
        compose.runOnIdle { source = source.copy(body = "New summary\n\n\n\nChanged tail") }
        restoration.emulateSavedInstanceStateRestore()
        compose
            .onNodeWithText("Changed tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9110").performClick()
        compose.runOnIdle { viewer = 8 }
        restoration.emulateSavedInstanceStateRestore()
        compose
            .onNodeWithText("Changed tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9110").performClick()
        compose.runOnIdle { source = source.copy(id = 9111) }
        restoration.emulateSavedInstanceStateRestore()
        compose
            .onNodeWithText("Changed tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9111").assertIsDisplayed()
    }

    @Test
    fun actualTimelineExpandsFourteenLinesInPlaceAndBodyStillOpensConversation() {
        val source = post(9101, (1..14).joinToString("\n") { "A longer TAGGR post · line $it" })
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(source)

                override suspend fun posts(ids: List<Long>) = listOf(source).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        compose.setContent { TaggrTheme { TaggrApp(model, account) } }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        compose.onNodeWithTag("show-full-post-9101").performScrollTo().assertIsDisplayed()
        assertEquals(10, layout(9101).lineCount)
        assertTrue(layout(9101).hasVisualOverflow)
        capture("post-preview")
        compose.onNodeWithTag("show-full-post-9101").performClick()
        compose.onNodeWithTag("show-full-post-9101").assertDoesNotExist()
        assertEquals(14, layout(9101).lineCount)
        assertFalse(layout(9101).hasVisualOverflow)
        compose.runOnIdle { assertNull(model.detail.value) }
        capture("post-full")
        compose.onNodeWithTag("post-body-9101-0", useUnmergedTree = true).performClick()
        compose.waitUntil(5000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.onNodeWithTag("show-full-post-9101").assertDoesNotExist()
        assertEquals(14, layout(9101).lineCount)
    }

    @Test
    fun cutMarkerTailIsRevealedAndNewBodyOrPostResetsExpansion() {
        val value = mutableStateOf(post(9102, "Summary\n\n\n\nHidden tail @Reader"))
        compose.setContent { TaggrTheme { Column { PostContent(value.value, false) } } }
        compose
            .onNodeWithText("Hidden tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9102").performClick()
        compose
            .onNodeWithText("Hidden tail", substring = true, useUnmergedTree = true)
            .assertIsDisplayed()
        compose.runOnIdle { value.value = value.value.copy(body = "New summary\n\n\n\nNew tail") }
        compose
            .onNodeWithText("New tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9102").performClick()
        compose
            .onNodeWithText("New tail", substring = true, useUnmergedTree = true)
            .assertIsDisplayed()
        compose.runOnIdle { value.value = value.value.copy(id = 9103) }
        compose
            .onNodeWithText("New tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9103").assertIsDisplayed()
    }

    @Test
    fun actualFontScaleOverflowControlsTheButtonAndShortBodiesNeedNone() {
        val scale = mutableStateOf(1f)
        val source = post(9104, "A readable paragraph with several words. ".repeat(7))
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, scale.value)) {
                TaggrTheme {
                    Column(Modifier.width(320.dp).verticalScroll(rememberScrollState())) {
                        PostContent(source, false)
                    }
                }
            }
        }
        assertFalse(layout(9104).hasVisualOverflow)
        compose.onNodeWithTag("show-full-post-9104").assertDoesNotExist()
        compose.runOnIdle { scale.value = 2f }
        compose.onNodeWithTag("show-full-post-9104").performScrollTo().assertIsDisplayed()
        assertTrue(layout(9104).hasVisualOverflow)
        compose.onNodeWithTag("show-full-post-9104").performClick()
        assertFalse(layout(9104).hasVisualOverflow)
        assertTrue(layout(9104).lineCount > 10)
        compose.onNodeWithTag("show-full-post-9104").assertDoesNotExist()
    }

    @Test
    fun hiddenAndRestrictedBodiesStayGatedAndViewerChangeResetsFullText() {
        val value =
            mutableStateOf(
                post(9105, "Visible summary\n\n\n\nProtected tail").copy(hiddenFor = setOf(7))
            )
        val viewer = mutableStateOf<Long?>(7)
        compose.setContent {
            CompositionLocalProvider(LocalPostViewer provides viewer.value) {
                TaggrTheme { Column { PostContent(value.value, false) } }
            }
        }
        compose.onNodeWithTag("show-full-post-9105").assertDoesNotExist()
        compose
            .onNodeWithText("Protected tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithText("Show", substring = false).performClick()
        compose.onNodeWithTag("show-full-post-9105").performClick()
        compose
            .onNodeWithText("Protected tail", substring = true, useUnmergedTree = true)
            .assertIsDisplayed()
        compose.runOnIdle { viewer.value = 8 }
        compose
            .onNodeWithText("Protected tail", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
        compose.onNodeWithTag("show-full-post-9105").assertIsDisplayed()
        compose.runOnIdle { value.value = value.value.copy(restriction = "Post unavailable") }
        compose.onNodeWithText("Post unavailable").assertIsDisplayed()
        compose.onNodeWithTag("show-full-post-9105").assertDoesNotExist()
        compose
            .onNodeWithText("Visible summary", substring = true, useUnmergedTree = true)
            .assertDoesNotExist()
    }
}
