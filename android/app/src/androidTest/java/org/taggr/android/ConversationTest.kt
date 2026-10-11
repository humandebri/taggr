package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ConversationTest {
    @get:Rule val compose = createComposeRule()

    private fun post(id: Long, body: String, parent: Long? = null) =
        TaggrPost(id, "Alice", body, null, 0, emptyList(), 0, 0, null, parent = parent)

    @Test
    fun opensReplyInContextAndCanScrollBackToAncestor() {
        val root = post(10, "Root context")
        val reply = post(20, "Focused reply", 10)
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(reply)

                override suspend fun thread(id: Long) =
                    if (id == 20L) listOf(root, reply) else listOf(root)

                override suspend fun posts(ids: List<Long>) =
                    listOf(root, reply).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model) } }
        compose.onNodeWithText("Focused reply").performClick()
        compose.waitUntil(5000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Focused reply").assertIsDisplayed()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Root context"))
        compose.onNodeWithText("Root context").assertIsDisplayed().performClick()
        compose.waitUntil(5000) {
            model.detail.value?.post?.id == 10L && model.detail.value?.loading == false
        }
        compose.onNodeWithText("Root context").assertIsDisplayed()
    }

    @Test
    fun readsActualMainnetAncestorChain() = runBlocking {
        TaggrApi().use { api ->
            val root =
                api.feed(FeedMode.HOT, 0, 0).firstOrNull { it.children.isNotEmpty() }
                    ?: error("No public conversation in feed")
            val reply =
                api.posts(root.children).firstOrNull { it.parent != null && it.restriction == null }
                    ?: error("No public reply")
            val chain = api.thread(reply.id)
            check(chain.lastOrNull()?.id == reply.id)
            check(chain.any { it.id == reply.parent })
        }
    }
}
