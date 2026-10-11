package org.taggr.android

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostTranslationUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun partialAndSameLanguageResultsAreLabelledHonestly() {
        val source = mutableStateOf(post("Hello\nWorld"))
        val engine = PostTranslator { _, _ ->
            if (source.value.body == "Hello\nWorld")
                PostTranslationResult("こんにちは\nWorld", retainedOriginalProse = true)
            else PostTranslationResult("Already English", alreadyInTargetLanguage = true)
        }
        compose.setContent {
            CompositionLocalProvider(LocalPostTranslator provides engine) {
                TaggrTheme { Column { PostContent(source.value, false) } }
            }
        }
        compose.onNodeWithText("Translate with Google").performClick()
        compose
            .onNodeWithText("Some original text was retained by Google Translate.")
            .assertIsDisplayed()
        compose.runOnIdle { source.value = post("Already English") }
        compose.onNodeWithText("Translate with Google").performClick()
        compose.onNodeWithText("Already in device language").assertIsDisplayed()
        compose.onNodeWithText("Translated", substring = false).assertDoesNotExist()
    }

    private fun post(body: String) =
        TaggrPost(9201, "Alice", body, null, 0, emptyList(), 0, 0, null)

    @Test
    fun inlineTranslationCanBeHiddenAndNeverSurvivesNewBodyOrViewer() {
        val source = mutableStateOf(post("A **hello** [label](https://example.com/private)"))
        val viewer = mutableStateOf<Long?>(7)
        val received = mutableListOf<String>()
        val engine = PostTranslator { batch, _ ->
            PostTranslationResult(
                batch.translatedBody {
                    received += it
                    "Translated fixture: $it"
                }
            )
        }
        compose.setContent {
            CompositionLocalProvider(
                LocalPostTranslator provides engine,
                LocalPostViewer provides viewer.value,
            ) {
                TaggrTheme { Column { PostContent(source.value, false) } }
            }
        }
        compose.onNodeWithText("Translate with Google").performClick()
        compose
            .onNodeWithTag("post-translation-9201")
            .assertTextEquals("Translated fixture: A hello label")
        compose.runOnIdle { assertEquals(listOf("A hello label"), received) }
        compose.onNodeWithContentDescription("Powered by Google Translate").assertIsDisplayed()
        compose.onNodeWithContentDescription("About translation").performClick()
        compose.onNodeWithText("THIS SERVICE MAY CONTAIN", substring = true).assertExists()
        compose.onNodeWithText("Google Translate information").assertExists()
        compose.onNodeWithText("Google receives ML Kit", substring = true).assertExists()
        compose.onNodeWithText("Translation privacy information").assertExists()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("Hide translation").performClick()
        compose.onNodeWithTag("post-translation-9201").assertDoesNotExist()
        compose.onNodeWithText("Translate with Google").performClick()
        compose.runOnIdle { source.value = post("A different body") }
        compose.onNodeWithTag("post-translation-9201").assertDoesNotExist()
        compose.onNodeWithText("Translate with Google").performClick()
        compose.onNodeWithTag("post-translation-9201").assertIsDisplayed()
        compose.runOnIdle { viewer.value = 8 }
        compose.onNodeWithTag("post-translation-9201").assertDoesNotExist()
    }

    @Test
    fun leavingOrCancellingReleasesActiveWorkAndHiddenContentStaysGated() {
        val source = mutableStateOf(post("Cancelable text"))
        val disposed = CompletableDeferred<Unit>()
        val engine = PostTranslator { _, _ ->
            try {
                awaitCancellation()
            } finally {
                disposed.complete(Unit)
            }
        }
        compose.setContent {
            CompositionLocalProvider(
                LocalPostTranslator provides engine,
                LocalPostViewer provides 7L,
            ) {
                TaggrTheme { Column { PostContent(source.value, false) } }
            }
        }
        compose.onNodeWithText("Translate with Google").performClick()
        compose.onNodeWithText("Cancel translation").performClick()
        compose.waitUntil(5000) { disposed.isCompleted }
        compose.onNodeWithTag("post-translation-9201").assertDoesNotExist()
        compose.runOnIdle { source.value = source.value.copy(hiddenFor = setOf(7)) }
        compose.onNodeWithText("Translate with Google").assertDoesNotExist()
        compose.onNodeWithText("Show", substring = false).performClick()
        compose.onNodeWithText("Translate with Google").assertIsDisplayed()
        compose.runOnIdle { source.value = source.value.copy(restriction = "Post unavailable") }
        compose.onNodeWithText("Translate with Google").assertDoesNotExist()
    }

    @Test
    fun failedTranslationOffersRetryWithoutShowingAPartialResult() {
        var attempts = 0
        val engine = PostTranslator { batch, _ ->
            if (++attempts == 1) error("fixture unavailable")
            PostTranslationResult(batch.translatedBody { "Recovered translation" })
        }
        compose.setContent {
            CompositionLocalProvider(LocalPostTranslator provides engine) {
                TaggrTheme { Column { PostContent(post("Retryable text"), false) } }
            }
        }
        compose.onNodeWithText("Translate with Google").performClick()
        compose.onNodeWithText("Translation unavailable.", substring = true).assertIsDisplayed()
        compose.onNodeWithTag("post-translation-9201").assertDoesNotExist()
        compose.onNodeWithText("Translate with Google").performClick()
        compose.onNodeWithTag("post-translation-9201").assertTextEquals("Recovered translation")
    }
}
