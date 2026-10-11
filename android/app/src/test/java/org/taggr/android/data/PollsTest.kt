package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Test

class PollsTest {
    private val hour = 3_600_000L
    private val mapper = ObjectMapper()

    private fun poll(votes: String = "{}", voters: String = "[]", weighted: String = "{}") =
        TaggrPoll.decode(
            mapper.readTree(
                """{"options":["A","B","C"],"votes":$votes,"voters":$voters,"deadline":24,"weighted_by_tokens":$weighted}"""
            )
        )

    private fun presentation(
        poll: TaggrPoll,
        user: Long? = null,
        hours: Long = 0,
        changing: Boolean = false,
    ) = PollPresentation(poll, 0, user, BigInteger.valueOf(4), changing, hours * hour)

    @Test
    fun distinguishesGuestNewPublicAndAnonymousVoters() {
        val poll = poll("""{"0":[7,9007199254740988]}""", "[7,8]")
        assertFalse(presentation(poll).voting)
        assertTrue(presentation(poll, 9).voting)
        assertTrue(presentation(poll, 7).canChange)
        assertFalse(presentation(poll, 7).voting)
        assertTrue(presentation(poll, 8).anonymousVote)
        assertFalse(presentation(poll, 8).canChange)
        assertFalse(presentation(poll, 8).voting)
        assertFalse(TaggrPoll.resolvableUser(BigInteger("9007199254740988")))
        assertTrue(TaggrPoll.resolvableUser(BigInteger("9007199254739990")))
        assertFalse(TaggrPoll.resolvableUser(BigInteger("9007199254739991")))
    }

    @Test
    fun expiryAndRevoteBoundaryUseBackendHoursWithoutOverflow() {
        val poll = poll("""{"0":[7]}""", "[7]")
        assertTrue(presentation(poll, 7, 19).canChange)
        assertFalse(presentation(poll, 7, 20).canChange)
        assertFalse(presentation(poll, 9, 24).voting)
        assertTrue(presentation(poll, hours = 24).expired)
        val almost = PollPresentation(poll, 0, 7, BigInteger.valueOf(4), false, 20 * hour - 1)
        assertTrue(almost.canChange)
        assertEquals("EXPIRES IN 5H", almost.expirationText)
        assertEquals(
            BigInteger.valueOf(25),
            PollPresentation(poll, 1, null, BigInteger.ZERO, false, 0).remainingHours,
        )
        val huge = poll.copy(deadlineHours = BigInteger("18446744073709551615"))
        assertFalse(presentation(huge, hours = Long.MAX_VALUE / hour).expired)
    }

    @Test
    fun resultRoundingChangingVoteAndExactTokenPower() {
        val poll =
            poll(
                """{"0":[1],"1":[2,3]}""",
                "[1,2,3]",
                """{"0":18446744073709551615,"1":100000001}""",
            )
        assertEquals(34, presentation(poll).percentage(0))
        assertEquals(67, presentation(poll).percentage(1))
        assertEquals(0, presentation(poll).percentage(2))
        assertEquals(listOf<BigInteger>(), presentation(poll, 1, changing = true).displayedVotes[0])
        assertEquals(BigInteger("184467440738"), presentation(poll).votingPower(0, 8))
        assertEquals(BigInteger.valueOf(2), presentation(poll).votingPower(1, 8))
        assertEquals(0, presentation(poll()).percentage(0))
    }

    @Test
    fun stalePollOrAnonymousAndLateRevotesAreRejected() {
        val poll = poll("""{"0":[7]}""", "[7,8]")
        PollVotes.validate(poll, poll, 0, 9, BigInteger.valueOf(4), 1, false, hour)
        PollVotes.validate(poll, poll, 0, 7, BigInteger.valueOf(4), 1, true, hour)
        listOf<() -> Unit>(
                { PollVotes.validate(poll, poll, 0, 7, BigInteger.valueOf(4), 1, false, hour) },
                { PollVotes.validate(poll, poll, 0, 8, BigInteger.valueOf(4), 1, true, hour) },
                { PollVotes.validate(poll, poll, 0, 7, BigInteger.valueOf(4), 1, true, 20 * hour) },
                {
                    PollVotes.validate(
                        poll,
                        poll.copy(options = listOf("changed")),
                        0,
                        9,
                        BigInteger.ZERO,
                        0,
                        false,
                        hour,
                    )
                },
                { PollVotes.validate(poll, poll, 0, -1, BigInteger.ZERO, 0, false, hour) },
            )
            .forEach { assertTrue(runCatching(it).isFailure) }
    }

    @Test
    fun canonicalVoteWireAndCertifiedResultArePersistable() {
        val bytes = PollVotes.arguments(42, 2, true)
        assertEquals("[42,2,true]", String(bytes))
        assertTrue(PollVotes.validArguments(bytes))
        listOf("[42,2,true]null", "[42,2,1]", "[-1,2,true]", "[42,65536,true]", "[42,2.0,true]")
            .forEach { assertFalse(PollVotes.validArguments(it.toByteArray())) }
        val call =
            FinancialCall("owner", "canister", "a".repeat(64), "vote_on_poll", ByteArray(32), bytes)
        assertEquals("vote_on_poll", call.method)
        assertTrue(FinancialReply.decode("vote_on_poll", "{\"Ok\":null}".toByteArray()).isNull)
        assertTrue(
            runCatching { FinancialReply.decode("vote_on_poll", "{\"Ok\":true}".toByteArray()) }
                .isFailure
        )
        assertTrue(
            runCatching {
                    FinancialReply.decode(
                        "vote_on_poll",
                        "{\"Err\":\"poll expired\"}".toByteArray(),
                    )
                }
                .exceptionOrNull() is FinancialRejected
        )
    }

    @Test
    fun decodingRetainsPollOriginalDeadlineAndDoesNotDropMalformedPostBody() {
        val rows =
            """[[{"id":42,"user":7,"body":"Poll body","timestamp":7200000000000,"patches":[[0,"patch"]],"extension":{"Poll":{"options":["A"],"votes":{},"voters":[],"deadline":1}}},{}]]"""
        val post = TaggrPost.decodeEnvelopes(rows.toByteArray()).single()
        assertNotNull(post.poll)
        assertEquals(0, post.pollTimestampMillis)
        assertTrue(
            PollPresentation(
                    post.poll!!,
                    post.pollTimestampMillis,
                    null,
                    BigInteger.ZERO,
                    false,
                    hour,
                )
                .expired
        )
        val malformed =
            TaggrPost.decodeEnvelopes(
                    rows.replace("\"options\":[\"A\"]", "\"options\":[7]").toByteArray()
                )
                .single()
        assertTrue(malformed.pollUnavailable)
        assertEquals("Poll body", malformed.body)
        assertNull(malformed.poll)
    }
}
