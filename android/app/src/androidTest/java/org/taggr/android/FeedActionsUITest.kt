package org.taggr.android

import android.app.Application
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.FeedComposeButton
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class FeedActionsUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun composerAndAccountSetupUseAccessibleCircularAction() {
        val hasUser = mutableStateOf(true)
        val signedIn = mutableStateOf(true)
        var opens = 0
        compose.setContent {
            TaggrTheme { FeedComposeButton(signedIn.value, hasUser.value, true) { opens++ } }
        }
        compose.onNodeWithContentDescription("Post").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertEquals(1, opens)
            hasUser.value = false
        }
        compose.onNodeWithContentDescription("Post").assertDoesNotExist()
        compose.onNodeWithContentDescription("Create TAGGR user").performClick()
        compose.runOnIdle {
            assertEquals(2, opens)
            signedIn.value = false
        }
        compose.onNodeWithContentDescription("Create TAGGR user").assertDoesNotExist()
    }

    @Test
    fun restoringOrBusyAccountCannotOpenComposer() {
        var opens = 0
        compose.setContent { TaggrTheme { FeedComposeButton(true, true, false) { opens++ } } }
        compose.onNodeWithContentDescription("Post").assertIsNotEnabled().performClick()
        compose.runOnIdle { assertEquals(0, opens) }
    }

    @Test
    fun guestTimelineMenusAreIndependentAndDoNotOpenTheConversation() {
        val posts =
            (1L..2L).map { id ->
                TaggrPost(id, "Alice$id", "Timeline fixture $id", null, 0, emptyList(), 0, 0, null)
            }
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = posts

                override suspend fun posts(ids: List<Long>) = posts.filter { it.id in ids }
            }
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model, account) } }
        compose.onNodeWithContentDescription("Post").assertDoesNotExist()
        compose.onNodeWithContentDescription("Create TAGGR user").assertDoesNotExist()
        val first = hasAnyAncestor(hasTestTag("post-engagement-1"))
        val second = hasAnyAncestor(hasTestTag("post-engagement-2"))
        compose
            .onNode(first and hasContentDescription("Show post actions"))
            .performScrollTo()
            .performClick()
        compose.onNode(first and hasText("Report")).assertIsDisplayed()
        compose.onNode(first and hasText("Share")).assertIsDisplayed()
        compose.onNode(second and hasContentDescription("Show post actions")).assertExists()
        compose.onNode(first and hasText("Reply")).assertDoesNotExist()
        compose.onNode(first and hasContentDescription("Show replies")).assertDoesNotExist()
        compose.onNodeWithText("Conversation").assertDoesNotExist()
        compose.onNode(first and hasText("Report")).performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNode(first and hasContentDescription("Hide post actions")).performClick()
        compose.onNode(first and hasText("Report")).assertDoesNotExist()
        compose
            .onNodeWithText("Timeline fixture 1", useUnmergedTree = true)
            .performScrollTo()
            .performClick()
        compose.waitUntil(5_000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
    }
}
