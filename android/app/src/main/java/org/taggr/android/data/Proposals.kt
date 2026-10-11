package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import java.math.BigDecimal
import java.math.BigInteger

data class ProposalPayload(
    val kind: String,
    val recipient: String? = null,
    val amount: ULong? = null,
    val commit: String? = null,
    val hash: String? = null,
    val realm: String? = null,
    val user: Long? = null,
) {
    val title
        get() =
            when (kind) {
                "Release" -> "RELEASE"
                "Rewards" -> "REWARDS"
                "Funding" -> "FUNDING"
                "ICPTransfer" -> "ICP TRANSFER"
                "AddRealmController" -> "REALM CONTROLLER"
                else -> "UNSUPPORTED PROPOSAL TYPE"
            }
}

data class ProposalBulletin(val user: Long, val adopted: Boolean, val power: ULong)

data class TaggrProposal(
    val id: Long,
    val proposer: Long,
    val timestamp: ULong,
    val postId: Long,
    val status: String,
    val payload: ProposalPayload,
    val bulletins: List<ProposalBulletin>,
    val votingPower: ULong,
) {
    fun power(adopted: Boolean) =
        bulletins
            .filter { it.adopted == adopted }
            .fold(BigInteger.ZERO) { sum, vote -> sum + BigInteger(vote.power.toString()) }

    fun percentage(adopted: Boolean): String {
        if (votingPower == 0uL) return "0%"
        val total = BigInteger(votingPower.toString())
        val hundredths =
            (power(adopted) * BigInteger.valueOf(10000) + total - BigInteger.ONE) / total
        return BigDecimal(hundredths, 2).stripTrailingZeros().toPlainString() + "%"
    }

    fun executionDays(threshold: Int): BigInteger? {
        if (status != "Open" || votingPower == 0uL || threshold !in 1..99) return null
        val accepted = power(true)
        val rejected = power(false)
        val divisor =
            BigInteger(votingPower.toString()) *
                BigInteger.valueOf(
                    (if (accepted > rejected) threshold else 100 - threshold).toLong()
                )
        val numerator =
            divisor * BigInteger.valueOf(100) -
                (if (accepted > rejected) accepted else rejected) * BigInteger.valueOf(10000)
        val parts = numerator.divideAndRemainder(divisor)
        return parts[0] + if (parts[1].signum() > 0) BigInteger.ONE else BigInteger.ZERO
    }

    companion object {
        val filters =
            listOf("ALL", "RELEASE", "FUNDING", "REWARDS", "REALM CONTROLLER", "ICP TRANSFER")

        fun displayedPower(power: BigInteger, decimals: Int): BigInteger {
            require(power.signum() >= 0 && decimals in 0..255)
            val base = BigInteger.TEN.pow(decimals)
            return (power + base - BigInteger.ONE) / base
        }

        fun decode(reply: JsonNode, requested: Long): TaggrProposal {
            require(reply.isObject && reply.size() == 1)
            reply["Err"]?.let {
                require(it.isTextual)
                error(it.asText())
            }
            val row = reply.required("Ok")
            require(row.isObject)
            fun id(value: JsonNode): Long {
                require(
                    value.isIntegralNumber &&
                        value.bigIntegerValue().signum() >= 0 &&
                        value.bigIntegerValue().bitLength() <= 63
                )
                return value.asLong()
            }
            fun text(value: JsonNode): String {
                require(value.isTextual)
                return value.asText()
            }
            fun uint(value: JsonNode): ULong {
                require(
                    value.isIntegralNumber &&
                        value.bigIntegerValue().signum() >= 0 &&
                        value.bigIntegerValue().bitLength() <= 64
                )
                return value.asText().toULong()
            }
            val payload = row.required("payload")
            val kind =
                if (payload.isObject && payload.size() == 1) payload.fieldNames().next()
                else "Unsupported"
            val body = payload[kind]
            fun pair() {
                require(body != null && body.isArray && body.size() == 2)
            }
            val decoded =
                when (kind) {
                    "Release" ->
                        ProposalPayload(
                            kind,
                            commit = text(body.required("commit")),
                            hash = text(body.required("hash")),
                        )
                    "Rewards" ->
                        ProposalPayload(
                            kind,
                            recipient = text(body.required("receiver")),
                            amount = uint(body.required("minted")),
                        )
                    "Funding" -> {
                        pair()
                        ProposalPayload(kind, recipient = text(body[0]), amount = uint(body[1]))
                    }
                    "AddRealmController" -> {
                        pair()
                        ProposalPayload(kind, realm = text(body[0]), user = id(body[1]))
                    }
                    "ICPTransfer" -> {
                        pair()
                        require(body[0].isArray && body[0].size() == 32)
                        val address =
                            body[0]
                                .map { uint(it).also { value -> require(value <= 255uL) }.toByte() }
                                .toByteArray()
                        org.ic4j.agent.android.ICPAccountIdentifier.parse(DraftImages.hex(address))
                        ProposalPayload(
                            kind,
                            recipient = DraftImages.hex(address),
                            amount = uint(body[1].required("e8s")),
                        )
                    }
                    else -> ProposalPayload("Unsupported")
                }
            val bulletin = row.required("bulletins")
            require(bulletin.isArray)
            val votes = bulletin.map {
                require(it.isArray && it.size() == 3 && it[1].isBoolean)
                ProposalBulletin(id(it[0]), it[1].asBoolean(), uint(it[2]))
            }
            require(votes.map { it.user }.distinct().size == votes.size)
            return TaggrProposal(
                    id(row.required("id")),
                    id(row.required("proposer")),
                    uint(row.required("timestamp")),
                    id(row.required("post_id")),
                    text(row.required("status")),
                    decoded,
                    votes,
                    uint(row.required("voting_power")),
                )
                .also { require(it.id == requested && requested in 0..0xffff_ffffL) }
        }
    }
}
