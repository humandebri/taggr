package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger

private val hourMillis = BigInteger.valueOf(3_600_000)
private val maximumPollUser = BigInteger("9007199254739991")

data class TaggrPoll(
    val options: List<String>,
    val votes: Map<Int, List<BigInteger>>,
    val voters: Set<BigInteger>,
    val deadlineHours: BigInteger,
    val weightedByTokens: Map<Int, BigInteger>,
) {
    companion object {
        fun unsigned(value: JsonNode): BigInteger {
            require(
                value.isIntegralNumber &&
                    value.bigIntegerValue().signum() >= 0 &&
                    value.bigIntegerValue().bitLength() <= 64
            )
            return value.bigIntegerValue()
        }

        fun decode(value: JsonNode): TaggrPoll {
            require(value.isObject)
            val options = value.required("options")
            require(
                options.isArray &&
                    options.size() in 1..65535 &&
                    options.all { it.isTextual } &&
                    options.sumOf { it.asText().length.toLong() } <= 200000
            )
            fun index(key: String): Int =
                key.toInt().also { require(it in 0 until options.size() && key == it.toString()) }
            val voteNode = value.required("votes")
            require(voteNode.isObject)
            val votes =
                voteNode.fields().asSequence().associate { row ->
                    require(row.value.isArray)
                    index(row.key) to
                        row.value.map(::unsigned).also { require(it.distinct().size == it.size) }
                }
            val voters =
                value
                    .get("voters")
                    ?.let {
                        require(it.isArray)
                        it.map(::unsigned).toSet()
                    }
                    .orEmpty()
            val weighted =
                value
                    .get("weighted_by_tokens")
                    ?.let {
                        require(it.isObject)
                        it.fields().asSequence().associate { row ->
                            index(row.key) to unsigned(row.value)
                        }
                    }
                    .orEmpty()
            return TaggrPoll(
                options.map(JsonNode::asText),
                votes,
                voters,
                unsigned(value.required("deadline")),
                weighted,
            )
        }

        fun resolvableUser(id: BigInteger) = id.signum() >= 0 && id < maximumPollUser
    }
}

data class PollPresentation(
    val poll: TaggrPoll,
    val timestampMillis: Long,
    val userId: Long?,
    val revoteHours: BigInteger,
    val changing: Boolean,
    val nowMillis: Long,
) {
    private val user = userId?.let(BigInteger::valueOf)
    private val age = BigInteger.valueOf(nowMillis) - BigInteger.valueOf(timestampMillis)
    private val elapsed =
        age.divideAndRemainder(hourMillis).let { (whole, rest) ->
            if (age.signum() < 0 && rest.signum() != 0) whole - BigInteger.ONE else whole
        }
    val remainingHours
        get() = poll.deadlineHours - elapsed

    val expired
        get() = remainingHours.signum() <= 0

    val visibleVote
        get() = user != null && poll.votes.values.any { user in it }

    val anonymousVote
        get() = user != null && user in poll.voters && !visibleVote

    val hasVoted
        get() = user != null && (user in poll.voters || visibleVote)

    val voting
        get() = user != null && (!hasVoted || changing) && !expired

    val canChange
        get() = !changing && visibleVote && !anonymousVote && remainingHours > revoteHours

    val displayedVotes
        get() =
            if (changing && user != null)
                poll.votes.mapValues { (_, ids) -> ids.filter { it != user } }
            else poll.votes

    fun percentage(option: Int): Int {
        val votes = displayedVotes
        val total = votes.values.sumOf { it.size.toLong() }
        return if (total == 0L) 0
        else ((votes[option].orEmpty().size.toLong() * 100 + total - 1) / total).toInt()
    }

    val expirationText: String
        get() {
            val days = remainingHours / BigInteger.valueOf(24)
            return if (days.signum() > 0)
                "EXPIRES IN $days DAY${if (days == BigInteger.ONE) "" else "S"}"
            else "EXPIRES IN ${remainingHours.max(BigInteger.ONE)}H"
        }

    fun votingPower(option: Int, decimals: Int): BigInteger? {
        require(decimals in 0..18)
        val amount = poll.weightedByTokens[option] ?: return null
        val base = BigInteger.TEN.pow(decimals)
        return (amount + base - BigInteger.ONE) / base
    }
}

object PollVotes {
    fun arguments(postId: Long, option: Int, anonymous: Boolean): ByteArray {
        require(postId >= 0 && option in 0..65535)
        return ObjectMapper().writeValueAsBytes(listOf(postId, option, anonymous))
    }

    fun validArguments(bytes: ByteArray): Boolean = runCatching {
        val row =
            ObjectMapper()
                .enable(
                    com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS
                )
                .readTree(bytes)
        require(
            row.isArray &&
                row.size() == 3 &&
                row[0].isIntegralNumber &&
                row[0].canConvertToLong() &&
                row[0].asLong() >= 0 &&
                row[1].isIntegralNumber &&
                row[1].canConvertToInt() &&
                row[1].asInt() in 0..65535 &&
                row[2].isBoolean
        )
        bytes.contentEquals(arguments(row[0].asLong(), row[1].asInt(), row[2].asBoolean()))
    }
        .getOrDefault(false)

    fun validate(
        original: TaggrPoll,
        current: TaggrPoll,
        timestampMillis: Long,
        userId: Long,
        revoteHours: BigInteger,
        option: Int,
        changing: Boolean,
        nowMillis: Long,
    ) {
        require(userId >= 0 && revoteHours.signum() >= 0)
        require(
            original.options == current.options && original.deadlineHours == current.deadlineHours
        ) {
            "The poll changed. Review your vote again."
        }
        require(option in current.options.indices)
        val presentation =
            PollPresentation(current, timestampMillis, userId, revoteHours, false, nowMillis)
        require(
            !presentation.expired &&
                (!presentation.hasVoted || (changing && presentation.canChange))
        ) {
            "This vote can no longer be submitted or changed."
        }
    }
}
