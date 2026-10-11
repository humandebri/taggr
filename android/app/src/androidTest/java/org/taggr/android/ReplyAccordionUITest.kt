package org.taggr.android

import android.app.Application
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ReplyAccordionUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun guestExpandsNestedRepliesAndCollapseKeepsTimelineRoute() {
        val parent = TaggrPost(8001, "Alice", "Accordion parent", null, 0, listOf(8002), 1, 0, null)
        val child =
            parent.copy(id = 8002, body = "Accordion child", parent = 8001, children = listOf(8003))
        val grandchild =
            parent.copy(
                id = 8003,
                body = "Accordion grandchild",
                parent = 8002,
                children = emptyList(),
                replyCount = 0,
            )
        val posts = listOf(parent, child, grandchild)
        val calls = mutableListOf<List<Long>>()
        val model =
            FeedViewModel(
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        listOf(parent)

                    override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                        calls.add(ids)
                        return posts.filter { it.id in ids }
                    }
                }
            )
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        compose.setContent { TaggrTheme { FeedScreen(model, account) } }
        compose.onNodeWithText("Accordion parent", useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, calls.size) }
        compose.onNodeWithContentDescription("Show replies").performClick()
        compose
            .onNodeWithText("Accordion child", useUnmergedTree = true)
            .performScrollTo()
            .assertIsDisplayed()
        compose.onNodeWithContentDescription("Show replies").performScrollTo().performClick()
        compose
            .onNodeWithText("Accordion grandchild", useUnmergedTree = true)
            .performScrollTo()
            .assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(null, model.detail.value)
            assertEquals(2, calls.size)
        }
        compose.onAllNodesWithContentDescription("Hide replies")[0].performScrollTo().performClick()
        compose.onNodeWithText("Accordion child", useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithText("Accordion grandchild", useUnmergedTree = true).assertDoesNotExist()
        compose.runOnIdle { assertEquals(emptyMap<Long, PostRepliesState>(), model.replies.value) }
        compose.onNodeWithText("Accordion parent", useUnmergedTree = true).performClick()
        compose.waitUntil(5000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
    }
}
