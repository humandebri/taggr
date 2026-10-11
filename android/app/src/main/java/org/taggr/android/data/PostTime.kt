package org.taggr.android.data

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.floor

internal object PostTime {
    private const val DAY = 86_400_000.0

    fun label(
        timestampMillis: Long,
        nowMillis: Long,
        locale: Locale = Locale.getDefault(),
        zone: ZoneId = ZoneId.systemDefault(),
        datePattern: String = "MMM d",
        oldDatePattern: String = "MMM d, yy",
    ): String {
        val age = (nowMillis.toDouble() - timestampMillis.toDouble()).coerceAtLeast(0.0)
        fun rounded(unit: Double) = floor(age / unit + 0.5).toLong()
        return when {
            age < 60_000 -> "${rounded(1_000.0).coerceAtLeast(1)}s ago"
            age < 3_600_000 -> "${rounded(60_000.0)}m ago"
            age < DAY -> "${rounded(3_600_000.0)}h ago"
            else ->
                DateTimeFormatter.ofPattern(
                        if (age < 90 * DAY) datePattern else oldDatePattern,
                        locale,
                    )
                    .withZone(zone)
                    .format(Instant.ofEpochMilli(timestampMillis))
        }
    }

    fun refreshMillis(timestampMillis: Long, nowMillis: Long): Long =
        if (nowMillis.toDouble() - timestampMillis.toDouble() < DAY) 30_000 else 3_600_000
}
