package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostPagingTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun hiddenPageOffersLoadMoreAndErrorOffersRetry() {
        var clicks = 0
        val state = androidx.compose.runtime.mutableStateOf(PagedPostsState())
        compose.setContent { TaggrTheme { PagedPostsFooter(state.value) { clicks++ } } }
        compose.onNodeWithText("No posts yet.").assertDoesNotExist()
        compose.onNodeWithText("Load more").performClick()
        assertEquals(1, clicks)
        compose.runOnIdle { state.value = PagedPostsState(error = "Offline") }
        compose.onNodeWithText("Offline").assertIsDisplayed()
        compose.onNodeWithText("Retry").performClick()
        assertEquals(2, clicks)
        compose.runOnIdle { state.value = PagedPostsState(canLoadMore = false) }
        compose.onNodeWithText("No posts yet.").assertIsDisplayed()
        compose.onNodeWithText("Load more").assertDoesNotExist()
    }

    @Test
    fun readsRealRealmAndProfilePagesWithVerifiedQueries() = runBlocking {
        TaggrApi().use { api ->
            val profile = api.jsonQuery("user", listOf(TaggrRuntime.domain, listOf("JK")))
            check(!profile.isNull)
            val first = api.userPostPage(profile.path("id").asLong(), 0, 0)
            check(first.hasMore) { "Profile first page was empty" }
            val second = api.userPostPage(profile.path("id").asLong(), 1, first.anchor)
            check(second.posts.none { it.id > first.anchor })
            val realm = api.realmPostPage("DAO", 0, 0)
            val next = api.realmPostPage("DAO", 1, realm.anchor)
            check(next.posts.none { realm.anchor > 0 && it.id > realm.anchor })
        }
    }
}
