package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class NotificationsTest {
    private val mapper = ObjectMapper()

    @Test
    fun parsesAllVariantsSortsAndRoutesConditionalTargets() {
        val value =
            mapper.readTree(
                """{
          "1":[{"Generic":"Hello"},true],
          "2":[{"NewPost":["Mention",99]},false],
          "3":[{"WatchedPostEntries":[99,[100,101,100]]},false],
          "4":[{"Conditional":["Proposal",{"Proposal":42}]},false],
          "5":[{"Conditional":["Report",{"UserReportOpen":7}]},false],
          "6":[{"Conditional":["Old report",{"ReportOpen":88}]},false]
        }"""
            )
        val decoded = Notifications.decode(value)
        assertEquals(0, decoded.invalidCount)
        assertEquals(listOf(6L, 5L, 4L, 3L, 2L, 1L), decoded.entries.map { it.id })
        assertEquals(7L, decoded.entries.first { it.id == 5L }.userId)
        assertEquals(42L, decoded.entries.first { it.id == 4L }.postId)
        assertEquals(listOf(100L, 101L), decoded.entries.first { it.id == 3L }.watchedEntries)
        assertTrue(decoded.entries.last().read)
    }

    @Test
    fun malformedRowsCannotCreateWrappedIdsAndValidRowsSurvive() {
        val decoded =
            Notifications.decode(
                mapper.readTree(
                    """{
          "1":[{"NewPost":["Bad",18446744073709551615]},false],
          "2":[{"Generic":"Bad"},"false"],
          "3":[{"Generic":"Good"},false],
          "4":[{"Future":{}},false],
          "-1":[{"Generic":"Bad"},false]
        }"""
                )
            )
        assertEquals(3, decoded.invalidCount)
        assertEquals(listOf(4L, 3L), decoded.entries.map { it.id })
        assertEquals("Notification unavailable", decoded.entries.first().message)
    }

    @Test
    fun followerBiographiesAndRestrictedTagsAreNotDisplayed() {
        val decoded =
            Notifications.decode(
                mapper.readTree(
                    """{
          "1":[{"Generic":"@Alice followed you (PRIVATE BIO)"},false],
          "2":[{"Generic":"Hello #NSFW details"},false]
        }"""
                )
            )
        assertEquals("@Alice followed you.", decoded.entries.last().message)
        assertEquals(
            "This notification contains restricted content.",
            decoded.entries.first().message,
        )
    }
}
