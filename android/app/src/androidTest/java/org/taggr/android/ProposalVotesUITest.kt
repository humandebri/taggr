package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ProposalVotesUITest {
    @get:Rule val compose = createComposeRule()
    private val proposal =
        TaggrProposal(
            7,
            1,
            1000uL,
            8,
            "Open",
            ProposalPayload("Release", commit = "commit", hash = "expected"),
            emptyList(),
            100uL,
        )

    @Test
    fun confirmationShowsFrozenHashAndRequiresExplicitVote() {
        val vote =
            ProposalVote(
                "voter",
                1,
                "a".repeat(64),
                7,
                8,
                proposal.payload,
                true,
                "reproduced",
                1000,
            )
        var confirmed = 0
        compose.setContent {
            TaggrTheme { ProposalVoteConfirmation(vote, false, {}) { confirmed++ } }
        }
        compose.onNodeWithText("Proposal #7").assertExists()
        compose.onNodeWithText("Vote data: reproduced").assertExists()
        compose.runOnIdle { assertEquals(0, confirmed) }
        compose.onNodeWithText("ACCEPT").performClick()
        compose.runOnIdle { assertEquals(1, confirmed) }
    }

    @Test
    fun customHostCannotPrepareVote() {
        compose.setContent {
            TaggrTheme {
                ProposalVoteControls(proposal, "voter", 1, false, 2, 500000uL, true, "", {}, {})
            }
        }
        compose.onNodeWithText("Voting is unavailable on custom domains.").assertExists()
        compose.onNodeWithText("ACCEPT").assertDoesNotExist()
    }

    @Test
    fun unknownResultDisablesBothVotingActions() {
        compose.setContent {
            TaggrTheme {
                ProposalVoteControls(
                    proposal,
                    "voter",
                    1,
                    true,
                    2,
                    500000uL,
                    false,
                    "reproduced",
                    {},
                    { error("Duplicate vote") },
                )
            }
        }
        compose.onNodeWithText("ACCEPT").assertIsNotEnabled()
        compose.onNodeWithText("REJECT").assertIsNotEnabled()
    }

    @Test
    fun voteAndFollowingRequestRecordsRestoreWithoutChangingArguments() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val dir = File(base.cacheDir, "vote-test-${UUID.randomUUID()}")
        val context =
            object : ContextWrapper(base) {
                override fun getNoBackupFilesDir() = dir
            }
        try {
            val store = FinancialCallStore(context)
            val args =
                ProposalVote(
                        "voter",
                        1,
                        "a".repeat(64),
                        7,
                        8,
                        proposal.payload,
                        true,
                        "reproduced",
                        1000,
                    )
                    .arguments()
            val call =
                FinancialCall(
                    "voter",
                    "canister",
                    "a".repeat(64),
                    "vote_on_proposal",
                    ByteArray(32),
                    args,
                )
            store.save(call)
            assertTrue(FinancialCallStore(context).load("voter", "a".repeat(64))!!.matches(call))
            assertThrows(IllegalArgumentException::class.java) {
                store.save(call.copy(requestId = ByteArray(32) { 1 }))
            }
            store.clear(call)
            val follow =
                call.copy(
                    method = "toggle_following_post",
                    requestId = ByteArray(32) { 2 },
                    arguments = "8".toByteArray(),
                )
            store.save(follow)
            assertTrue(FinancialCallStore(context).load("voter", "a".repeat(64))!!.matches(follow))
        } finally {
            dir.deleteRecursively()
        }
    }
}
