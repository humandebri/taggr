package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import java.net.URI

data class ProposalVote(
    val owner: String,
    val userId: Long,
    val network: String,
    val proposalId: Long,
    val postId: Long,
    val payload: ProposalPayload,
    val adopted: Boolean,
    val data: String,
    val preparedAtMillis: Long,
) {
    init {
        require(
            owner.isNotBlank() &&
                userId >= 0 &&
                proposalId in 0..0xffff_ffffL &&
                postId >= 0 &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                data.length <= 1024
        )
    }

    fun arguments(): ByteArray = ObjectMapper().writeValueAsBytes(listOf(proposalId, adopted, data))

    fun validate(
        proposal: TaggrProposal,
        user: JsonNode,
        owner: String,
        network: String,
        canonical: Boolean,
        now: Long,
        decimals: Int,
        maximum: ULong,
    ) {
        require(now >= preparedAtMillis && now - preparedAtMillis <= 120000) {
            "This vote confirmation expired. Review your vote again."
        }
        require(
            this.owner == owner &&
                this.network == network &&
                user.path("id").asLong(-1) == userId &&
                proposal.id == proposalId &&
                proposal.postId == postId &&
                proposal.payload == payload
        ) {
            "The account or proposal changed. Review your vote again."
        }
        require(ProposalVotes.canVote(proposal, userId, owner, canonical)) {
            "This proposal can no longer be voted on by this account."
        }
        require(ProposalVotes.data(proposal, adopted, data, decimals, maximum) == data)
    }
}

object ProposalVotes {
    fun canonical(api: URI, domain: String, canister: String) =
        api != URI("https://ic0.app") || domain == "$canister.icp0.io"

    fun canVote(proposal: TaggrProposal, userId: Long?, owner: String?, canonical: Boolean) =
        canonical &&
            userId != null &&
            owner != null &&
            proposal.status == "Open" &&
            proposal.payload.kind != "Unsupported" &&
            proposal.bulletins.none { it.user == userId } &&
            !(proposal.payload.kind in listOf("Funding", "Rewards") &&
                proposal.payload.recipient == owner)

    fun data(
        proposal: TaggrProposal,
        adopted: Boolean,
        input: String,
        decimals: Int,
        maximum: ULong,
    ): String {
        require(proposal.payload.kind != "Unsupported")
        if (!adopted) return ""
        return when (proposal.payload.kind) {
            "Release" ->
                input.also {
                    require(it.isNotEmpty() && it.length <= 1024) {
                        "Enter the reproducible build hash."
                    }
                }
            "Rewards" ->
                input.also {
                    require(decimals in 0..255 && it.matches(Regex("[0-9]+"))) {
                        "Enter a whole-token reward amount."
                    }
                    val scaled = BigInteger(it) * BigInteger.TEN.pow(decimals)
                    require(scaled <= BigInteger(maximum.toString())) {
                        "Reward exceeds the configured maximum."
                    }
                }
            else -> ""
        }
    }

    fun validArguments(method: String, bytes: ByteArray): Boolean =
        try {
            require(bytes.size <= 4096)
            val row = ObjectMapper().readTree(bytes)
            if (method == "toggle_following_post")
                require(
                    row.isIntegralNumber &&
                        row.bigIntegerValue().signum() >= 0 &&
                        row.bigIntegerValue().bitLength() <= 63
                )
            else {
                require(method == "vote_on_proposal" && row.isArray && row.size() == 3)
                require(
                    row[0].isIntegralNumber &&
                        row[0].bigIntegerValue().signum() >= 0 &&
                        row[0].bigIntegerValue().bitLength() <= 32 &&
                        row[1].isBoolean &&
                        row[2].isTextual &&
                        row[2].asText().length <= 1024
                )
            }
            true
        } catch (_: Exception) {
            false
        }
}
