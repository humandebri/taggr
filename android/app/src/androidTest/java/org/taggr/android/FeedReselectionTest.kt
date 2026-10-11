package org.taggr.android

import android.app.Application
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class FeedReselectionTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun feedTabReturnsToTopAndKeepsChannelWithoutReloading() {
        val calls = AtomicInteger()
        val rows =
            (1L..40L).map {
                TaggrPost(it, "Alice", "Timeline entry $it", null, 0, emptyList(), 0, 0, null)
            }
        val repository =
            object : PostRepository {
                override suspend fun feed(
                    mode: FeedMode,
                    page: Int,
                    offset: Long,
                ): List<TaggrPost> {
                    calls.incrementAndGet()
                    return rows
                }

                override suspend fun posts(ids: List<Long>) = rows.filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        compose.setContent { TaggrTheme { TaggrApp(model, account) } }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        compose.onNodeWithText("#latest").performClick()
        compose.waitUntil(5_000) {
            !model.feed.value.loading && model.feed.value.mode == FeedMode.LATEST
        }
        compose.onNodeWithTag("home-feed").performScrollToIndex(25)
        compose.onNodeWithText("Timeline entry 1").assertDoesNotExist()
        val before = calls.get()
        compose.onNodeWithText("Feed", substring = false).performClick()
        compose.onNodeWithText("Timeline entry 1").assertIsDisplayed()
        assertEquals(FeedMode.LATEST, model.feed.value.mode)
        assertEquals(before, calls.get())
        compose.onNodeWithText("Timeline entry 1").performClick()
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.onNodeWithText("Feed", substring = false).performClick()
        compose.onNodeWithText("TAGGR", substring = false).assertIsDisplayed()
        compose.onNodeWithText("Timeline entry 1").assertIsDisplayed()
        assertEquals(before, calls.get())
    }
}
