package org.taggr.android

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
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
class ProposalsUITest {
    @get:Rule val compose = createComposeRule()
    private val post = TaggrPost(8, "author", "Discussion", null, 1000, emptyList(), 0, 0, null)
    private val proposal =
        TaggrProposal(
            7,
            1,
            1000000000uL,
            8,
            "Open",
            ProposalPayload("Funding", recipient = "2vxsx-fae", amount = 12345uL),
            listOf(ProposalBulletin(1, true, 50uL)),
            100uL,
        )

    @Test
    fun detailShowsTokenDecimalsAndOpensMatchingDiscussion() {
        var opened: Long? = null
        compose.setContent {
            TaggrTheme { ProposalDetails(proposal, post, 2, 66, { opened = it }, {}, {}) }
        }
        compose.onNodeWithText("Funding: 123.45").assertExists()
        compose.onNodeWithText("ACCEPTED: 1 (50%)").assertExists()
        compose.onNodeWithText("Execution deadline: 25 DAYS").assertExists()
        compose.onNodeWithText("Open discussion").performClick()
        compose.runOnIdle { assertEquals(8L, opened) }
    }

    @Test
    fun restrictedDiscussionHidesProposalPayloadAndVoteIdentities() {
        compose.setContent {
            TaggrTheme {
                ProposalDetails(proposal, post.copy(restriction = "Hidden"), 2, 66, {}, {}, {})
            }
        }
        compose.onNodeWithText("Proposal unavailable.").assertExists()
        compose.onNodeWithText("Funding: 123.45").assertDoesNotExist()
        compose.onNodeWithText("User #1").assertDoesNotExist()
    }

    @Test
    fun participantNamesKeepNumericProfileNavigation() {
        var opened: Long? = null
        compose.setContent {
            TaggrTheme {
                ProposalDetails(
                    proposal,
                    post,
                    2,
                    66,
                    {},
                    { opened = it },
                    {},
                    name = { if (it == 1L) "localwriter" else "User #$it" },
                )
            }
        }
        compose.onNodeWithText("Proposer: localwriter").performClick()
        compose.runOnIdle { assertEquals(1L, opened) }
        compose.onNodeWithText("localwriter").performClick()
        compose.runOnIdle { assertEquals(1L, opened) }
        compose.onNodeWithText("User #1").assertDoesNotExist()
    }

    @Test
    fun releaseSourceLinkOpensTheDisplayedCommit() {
        var opened: String? = null
        val handler =
            object : UriHandler {
                override fun openUri(uri: String) {
                    opened = uri
                }
            }
        val commit = "0123456789abcdef0123456789abcdef01234567"
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides handler) {
                TaggrTheme {
                    ProposalDetails(
                        proposal.copy(
                            payload = ProposalPayload("Release", commit = commit, hash = "hash")
                        ),
                        post,
                        2,
                        66,
                        {},
                        {},
                        {},
                    )
                }
            }
        }
        compose.onNodeWithText("Source commit").performClick()
        compose.runOnIdle {
            assertEquals("https://github.com/TaggrNetwork/taggr/commit/$commit", opened)
        }
    }

    @Test
    fun readsActualMainnetProposalPageAndMatchingDetail() = runBlocking {
        TaggrApi().use { api ->
            val page = api.proposalPage("ALL", 0)
            val post = page.posts.first { it.proposalId != null }
            val detail = api.proposal(post.proposalId!!)
            check(detail.postId == post.id)
        }
    }
}
