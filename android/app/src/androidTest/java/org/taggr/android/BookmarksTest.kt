package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class BookmarksTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun opensAndRemovesOnlyOnExplicitActions() {
        var opened: Long? = null
        var removed: Long? = null
        val post = TaggrPost(42, "Alice", "Saved post", null, 0, emptyList(), 0, 0, null)
        compose.setContent {
            TaggrTheme {
                BookmarksContent(
                    true,
                    PagedPostsState(listOf(post), canLoadMore = false),
                    false,
                    back = {},
                    refresh = {},
                    loadMore = {},
                    openPost = { opened = it },
                    remove = { removed = it },
                )
            }
        }
        compose.onNodeWithText("Saved post").assertIsDisplayed()
        assertNull(opened)
        assertNull(removed)
        compose.onNodeWithText("Open conversation").performClick()
        assertEquals(42L, opened)
        compose.onNodeWithText("Remove bookmark").performClick()
        assertEquals(42L, removed)
    }

    @Test
    fun errorsKeepLoadedBookmarksAndOfferRetry() {
        var retry = false
        val post = TaggrPost(42, "Alice", "Already loaded", null, 0, emptyList(), 0, 0, null)
        compose.setContent {
            TaggrTheme {
                BookmarksContent(
                    true,
                    PagedPostsState(listOf(post), error = "Offline"),
                    false,
                    back = {},
                    refresh = {},
                    loadMore = { retry = true },
                    openPost = {},
                    remove = {},
                )
            }
        }
        compose.onNodeWithText("Already loaded").assertIsDisplayed()
        compose.onNodeWithText("Retry").performClick()
        assertTrue(retry)
    }
}
