package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Test

class UserBadgeTest {
    private val mapper = ObjectMapper()

    @Test
    fun knownServerBadgesDecodeWithoutUnknownOrDuplicateLabels() {
        assertEquals(
            listOf(UserBadge.Bot, UserBadge.Inactive),
            UserBadge.decode(mapper.readTree("""["BOT","future","INACTIVE","BOT",7]""")),
        )
        assertTrue(UserBadge.decode(mapper.readTree("""{"x":"BOT"}""")).isEmpty())
        val row =
            """[[{"id":1,"user":2,"timestamp":0,"body":"Body"},{"author_badges":["OG","STALWART"]}]]"""
        assertEquals(
            listOf(UserBadge.Og, UserBadge.Stalwart),
            TaggrPost.decodeEnvelopes(row.toByteArray()).single().authorBadges,
        )
    }

    @Test
    fun profileMatchesSwiftBotPrecedenceActivityAndViewerRules() {
        val user =
            mapper.readTree(
                """{"id":7,"controllers":[],"timestamp":0,"stalwart":true,"active_weeks":13,"followees":[9],"last_activity":0}"""
            )
        assertEquals(
            listOf(
                UserBadge.Og,
                UserBadge.Stalwart,
                UserBadge.Frequenter,
                UserBadge.FollowsYou,
                UserBadge.Inactive,
            ),
            UserBadge.profile(user, 9, BigInteger.ZERO, 1),
        )
        (user as com.fasterxml.jackson.databind.node.ObjectNode).set<
            com.fasterxml.jackson.databind.JsonNode
        >(
            "controllers",
            mapper.readTree("""["aaaaaaaaaaaaaaaaaaaaaaaaaaa"]"""),
        )
        assertEquals(UserBadge.Bot, UserBadge.profile(user, 7, null, 1).first())
        assertFalse(UserBadge.profile(user, 7, null, 1).contains(UserBadge.FollowsYou))
        assertFalse(UserBadge.profile(user, 7, null, 1).contains(UserBadge.Inactive))
    }

    @Test
    fun exactThresholdsAndLargeUnsignedActivityStayAccurate() {
        val user =
            mapper.readTree(
                """{"id":7,"timestamp":1672500000000000000,"active_weeks":12,"last_activity":0}"""
            )
        val weekMs = 604800000L
        assertTrue(UserBadge.profile(user, null, BigInteger.ONE, weekMs).isEmpty())
        assertEquals(
            listOf(UserBadge.Inactive),
            UserBadge.profile(user, null, BigInteger.ONE, weekMs + 1),
        )
        assertTrue(
            UserBadge.profile(user, null, BigInteger("18446744073709551615"), Long.MAX_VALUE)
                .isEmpty()
        )
        assertTrue(UserBadge.profile(mapper.readTree("{}"), null, null, 0).isEmpty())
    }
}
