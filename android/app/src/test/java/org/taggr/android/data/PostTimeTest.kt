package org.taggr.android.data

import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class PostTimeTest {
    private val now = Instant.parse("2026-10-08T12:00:00Z").toEpochMilli()

    private fun label(age: Long) = PostTime.label(now - age, now, Locale.US, ZoneId.of("UTC"))

    @Test
    fun relativeThresholdsMatchSwiftRounding() {
        assertEquals("1s ago", label(-5000))
        assertEquals("1s ago", label(0))
        assertEquals("2s ago", label(1500))
        assertEquals("60s ago", label(59999))
        assertEquals("1m ago", label(60000))
        assertEquals("2m ago", label(90000))
        assertEquals("60m ago", label(3599999))
        assertEquals("1h ago", label(3600000))
        assertEquals("24h ago", label(86399999))
        assertEquals("Oct 7", label(86400000))
    }

    @Test
    fun olderDatesAndRefreshCadenceMatchSwift() {
        assertEquals("Jul 11", label(89L * 86400000))
        assertEquals("Jul 10, 26", label(90L * 86400000))
        assertEquals(30000L, PostTime.refreshMillis(now, now))
        assertEquals(3600000L, PostTime.refreshMillis(now - 86400000, now))
        assertEquals(
            "Oct 8",
            PostTime.label(
                now - 86400000,
                now,
                Locale.US,
                ZoneId.of("Pacific/Kiritimati"),
            ),
        )
    }
}
