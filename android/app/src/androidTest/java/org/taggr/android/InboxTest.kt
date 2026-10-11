package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class InboxTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun archiveIsSeparateAndMarkAllUsesOnlyUnreadIds() {
        var marked = emptyList<Long>()
        val list =
            NotificationList(
                listOf(
                    NotificationEntry(2, false, "New notice"),
                    NotificationEntry(1, true, "Archived notice"),
                ),
                0,
            )
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    list,
                    false,
                    refresh = {},
                    markRead = { marked = it },
                    loadPost = { null },
                    openPost = {},
                    openProfile = {},
                )
            }
        }
        compose.onNodeWithText("New notice").assertIsDisplayed()
        compose.onNodeWithText("Archived notice").assertDoesNotExist()
        assertTrue(marked.isEmpty())
        compose.onNodeWithText("Mark all read").performClick()
        assertEquals(listOf(2L), marked)
        compose.onNodeWithText("Show archive").performClick()
        compose.onNodeWithText("Archived notice").assertIsDisplayed()
    }

    @Test
    fun welcomeNotificationRendersMarkdownLikeIOS() {
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    NotificationList(
                        listOf(
                            NotificationEntry(
                                1,
                                false,
                                "**Welcome!** Read [the rules](/#/whitepaper).",
                            )
                        ),
                        0,
                    ),
                    false,
                    refresh = {},
                    markRead = {},
                    loadPost = { null },
                    openPost = {},
                    openProfile = {},
                )
            }
        }
        compose.onNodeWithText("Welcome! Read the rules.").assertIsDisplayed()
        compose.onNodeWithText("**Welcome!**", substring = true).assertDoesNotExist()
        compose.onNodeWithText("[the rules]", substring = true).assertDoesNotExist()
    }

    @Test
    fun unavailablePostNeverLeaksNotificationMessage() {
        val list =
            NotificationList(listOf(NotificationEntry(2, false, "PRIVATE NOTIFICATION", 99)), 0)
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    list,
                    false,
                    refresh = {},
                    markRead = {},
                    loadPost = { null },
                    openPost = {},
                    openProfile = {},
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Post unavailable").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("PRIVATE NOTIFICATION").assertDoesNotExist()
        compose.onNodeWithText("Open conversation").assertDoesNotExist()
        compose.onNodeWithText("Mark as read").assertIsDisplayed()
    }

    @Test
    fun conditionalUserReportOpensProfile() {
        var opened: String? = null
        val list =
            NotificationList(listOf(NotificationEntry(2, false, "User report", userId = 7)), 0)
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    list,
                    false,
                    refresh = {},
                    markRead = {},
                    loadPost = { null },
                    openPost = {},
                    openProfile = { opened = it },
                )
            }
        }
        compose.onNodeWithText("Open profile").performClick()
        assertEquals("7", opened)
    }

    @Test
    fun watchedReplyAndUnwatchRequireExplicitActions() {
        var reply: Long? = null
        var unwatched = false
        val post = TaggrPost(99, "Alice", "Visible post", null, 0, emptyList(), 0, 0, null)
        val entry = NotificationEntry(2, false, "Thread update", 99, watchedEntries = listOf(100))
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    NotificationList(listOf(entry), 0),
                    false,
                    refresh = {},
                    markRead = {},
                    loadPost = { post },
                    openPost = { reply = it },
                    openProfile = {},
                    unwatch = { unwatched = true },
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Visible post").fetchSemanticsNodes().isNotEmpty()
        }
        assertFalse(unwatched)
        compose.onNodeWithText("Reply #100").performClick()
        assertEquals(100L, reply)
        compose.onNodeWithText("Unwatch post").performClick()
        assertTrue(unwatched)
    }
}
