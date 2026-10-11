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
class ProposalLinksUITest {
    @get:Rule val compose = createComposeRule()
    private val post =
        TaggrPost(
            8,
            "author",
            "Proposal discussion",
            null,
            1000,
            emptyList(),
            0,
            0,
            null,
            proposalId = 7,
        )

    @Test
    fun postLinkOpensProposalIDInsteadOfDiscussionPostID() {
        var target: Long? = null
        compose.setContent { TaggrTheme { ProposalLink(post) { target = it } } }
        compose.onNodeWithText("Proposal #7").performClick()
        compose.runOnIdle { assertEquals(7L, target) }
    }

    @Test
    fun restrictedPostDoesNotExposeProposalNavigation() {
        compose.setContent {
            TaggrTheme {
                ProposalLink(post.copy(restriction = "Hidden")) {
                    error("Restricted proposal opened")
                }
            }
        }
        compose.onNodeWithText("Proposal #7").assertDoesNotExist()
    }

    @Test
    fun proposalNotificationRoutesFromLoadedPostExtensionWithoutAcknowledgingIt() {
        var target: Long? = null
        var marked = false
        val notifications =
            NotificationList(listOf(NotificationEntry(1, false, "New proposal", postId = 8)), 0)
        compose.setContent {
            TaggrTheme {
                InboxContent(
                    "owner",
                    true,
                    notifications,
                    false,
                    refresh = {},
                    markRead = { marked = true },
                    loadPost = { post },
                    openPost = {},
                    openProfile = {},
                    openProposal = { target = it },
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Proposal #7").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Proposal #7").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(7L, target)
            assertFalse(marked)
        }
    }
}
