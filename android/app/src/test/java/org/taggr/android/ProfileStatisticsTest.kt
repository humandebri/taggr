package org.taggr.android

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class ProfileStatisticsTest {
    @Test
    fun positiveStatisticsKeepSwiftOrderAndExactUnsignedBalance() {
        val profile =
            ObjectMapper()
                .readTree(
                    """{"id":7,"num_posts":12,"followees":[7,8,8],"followers":[9,10],"realms":["A","B"],"controlled_realms":["C"],"bookmarks":[42],"pinned_posts":[43],"active_weeks":4,"cycles":200,"balance":18446744073709551615}"""
                )
        val stats = profileStatistics(profile, 8)
        assertEquals(
            listOf(
                "posts",
                "follows",
                "followers",
                "joined-realms",
                "controls-realms",
                "bookmarks",
                "pinned",
                "active-weeks",
                "credits",
                "balance",
            ),
            stats.map { it.key },
        )
        assertEquals("1", stats.first { it.key == "follows" }.value)
        assertEquals(ProfileUserList.Followers, stats.first { it.key == "followers" }.users)
        assertEquals(listOf("A", "B"), stats.first { it.key == "joined-realms" }.realms)
        assertEquals("184467440737.09551615", stats.last().value.replace(",", ""))
    }

    @Test
    fun zeroMalformedAndUnknownDenominationNeverBecomePositiveStats() {
        val profile =
            ObjectMapper()
                .readTree(
                    """{"id":7,"num_posts":0,"followees":[7],"followers":[],"realms":[null,12,""],"controlled_realms":{},"bookmarks":[-1,"42",null],"pinned_posts":["42"],"active_weeks":-1,"cycles":"100","balance":123}"""
                )
        assertTrue(profileStatistics(profile, null).isEmpty())
        assertEquals("1.23", profileStatistics(profile, 2).single().value)
        assertTrue(profileStatistics(profile, -1).isEmpty())
    }
}
