package org.taggr.android

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostHeaderUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun realmNameOpensItsRouteWithoutOpeningThePost() {
        val post =
            TaggrPost(91, "Alice", "Realm header fixture", "日本語Realm", 0, emptyList(), 0, 0, null)
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        var realm: String? = null
        compose.setContent {
            CompositionLocalProvider(LocalRealmOpen provides { realm = it }) {
                TaggrTheme { TaggrApp(model) }
            }
        }
        compose
            .onNodeWithContentDescription("Open realm 日本語Realm")
            .assertHasClickAction()
            .performClick()
        compose.runOnIdle {
            assertEquals("日本語Realm", realm)
            assertNull(model.detail.value)
        }
        compose.onNodeWithText("TAGGR").assertIsDisplayed()
    }

    @Test
    fun timelineShowsAuthorTimeAndBackendBadgesAndStillOpensConversation() {
        val post =
            TaggrPost(
                90,
                "Alice",
                "Header fixture",
                "testrealm",
                System.currentTimeMillis() - 3600000,
                emptyList(),
                0,
                0,
                null,
                authorBadges = listOf(UserBadge.Og, UserBadge.Stalwart),
            )
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model) } }
        compose.onNodeWithText("Alice").assertIsDisplayed()
        compose.onNodeWithContentDescription("Posted 1h ago").assertIsDisplayed()
        compose.onNodeWithContentDescription("OG account").assertIsDisplayed()
        compose
            .onAllNodesWithContentDescription("OG account", useUnmergedTree = true)
            .assertCountEquals(1)
        compose.onNodeWithContentDescription("Stalwart").assertIsDisplayed()
        compose.onNodeWithText("testrealm").assertIsDisplayed()
        compose.onNodeWithText("Header fixture").performClick()
        compose.waitUntil(5000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose
            .onAllNodesWithContentDescription("OG account", useUnmergedTree = true)
            .assertCountEquals(1)
        compose.onNodeWithContentDescription("Posted 1h ago").assertIsDisplayed()
    }
}
