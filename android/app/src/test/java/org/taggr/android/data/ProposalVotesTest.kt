package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.net.URI
import org.junit.Assert.*
import org.junit.Test

class ProposalVotesTest {
    private val proposal =
        TaggrProposal(
            7,
            1,
            1000uL,
            8,
            "Open",
            ProposalPayload("Rewards", recipient = "receiver", amount = 0uL),
            emptyList(),
            100uL,
        )

    @Test
    fun rewardAndBuildHashInputsRespectAcceptRejectAndLiveLimits() {
        assertEquals("5000", ProposalVotes.data(proposal, true, "5000", 2, 500000uL))
        assertThrows(IllegalArgumentException::class.java) {
            ProposalVotes.data(proposal, true, "5001", 2, 500000uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProposalVotes.data(proposal, true, "1.5", 2, 500000uL)
        }
        assertEquals("", ProposalVotes.data(proposal, false, "1.5", 2, 500000uL))
        val release =
            proposal.copy(
                payload = ProposalPayload("Release", commit = "commit", hash = "expected")
            )
        assertThrows(IllegalArgumentException::class.java) {
            ProposalVotes.data(release, true, "", 2, 500000uL)
        }
        assertEquals("reproduced", ProposalVotes.data(release, true, "reproduced", 2, 500000uL))
        assertFalse(ProposalVotes.canVote(proposal, 1, "receiver", true))
        assertFalse(
            ProposalVotes.canVote(
                proposal.copy(bulletins = listOf(ProposalBulletin(1, true, 10uL))),
                1,
                "voter",
                true,
            )
        )
    }

    @Test
    fun confirmationRejectsChangedPayloadAccountDeadlineAndCustomHost() {
        val user = ObjectMapper().readTree("""{"id":1}""")
        val vote =
            ProposalVote("voter", 1, "a".repeat(64), 7, 8, proposal.payload, true, "50", 1000)
        vote.validate(proposal, user, "voter", "a".repeat(64), true, 2000, 2, 500000uL)
        assertThrows(IllegalArgumentException::class.java) {
            vote.validate(
                proposal.copy(payload = proposal.payload.copy(recipient = "different")),
                user,
                "voter",
                "a".repeat(64),
                true,
                2000,
                2,
                500000uL,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            vote.validate(proposal, user, "other", "a".repeat(64), true, 2000, 2, 500000uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            vote.validate(proposal, user, "voter", "a".repeat(64), true, 121001, 2, 500000uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            vote.validate(proposal, user, "voter", "a".repeat(64), false, 2000, 2, 500000uL)
        }
        assertFalse(ProposalVotes.canonical(URI("https://ic0.app"), "custom.example", "canister"))
        assertTrue(ProposalVotes.canonical(URI("https://ic0.app"), "canister.icp0.io", "canister"))
        assertTrue(
            ProposalVotes.canonical(URI("http://localhost:18100"), "local.example", "canister")
        )
    }

    @Test
    fun signedVoteAndFollowRepliesRemainDistinctWithoutResending() {
        val vote = ProposalVote("voter", 1, "a".repeat(64), 7, 8, proposal.payload, false, "", 1000)
        val args = vote.arguments()
        assertTrue(ProposalVotes.validArguments("vote_on_proposal", args))
        assertFalse(
            ProposalVotes.validArguments("vote_on_proposal", "[4294967296,true,\"\"]".toByteArray())
        )
        assertFalse(ProposalVotes.validArguments("vote_on_proposal", "[7,1,\"\"]".toByteArray()))
        assertTrue(
            FinancialReply.decode("vote_on_proposal", """{"Ok":null}""".toByteArray()).isNull
        )
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode("vote_on_proposal", """{"Err":"double vote"}""".toByteArray())
        }
        assertTrue(FinancialReply.decode("toggle_following_post", "true".toByteArray()).asBoolean())
        assertFalse(
            FinancialReply.decode("toggle_following_post", "false".toByteArray()).asBoolean()
        )
        assertThrows(IllegalArgumentException::class.java) {
            FinancialReply.decode("toggle_following_post", """{"Ok":null}""".toByteArray())
        }
        FinancialCall("voter", "canister", "a".repeat(64), "vote_on_proposal", ByteArray(32), args)
        FinancialCall(
            "voter",
            "canister",
            "a".repeat(64),
            "toggle_following_post",
            ByteArray(32),
            "8".toByteArray(),
        )
    }
}
