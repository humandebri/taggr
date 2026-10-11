package org.taggr.android.data

import kotlinx.coroutines.delay

class SessionExpiredException :
    IllegalStateException(
        "Your session expired. Sign in again to continue. Drafts and pending requests have been kept."
    )

/** Check wall time again after each wait: suspension and clock changes can cross the deadline. */
internal fun sessionRemainingMillis(expirationNanos: Long, nowMillis: Long): Long =
    (expirationNanos / 1_000_000L - nowMillis).coerceAtLeast(0)

internal suspend fun watchSessionExpiry(
    expirationNanos: Long,
    nowMillis: () -> Long = System::currentTimeMillis,
    canExpire: () -> Boolean,
    expired: suspend () -> Unit,
) {
    while (true) {
        val remaining = sessionRemainingMillis(expirationNanos, nowMillis())
        if (remaining == 0L && canExpire()) {
            expired()
            return
        }
        // One cancellable timer per session, without network requests or accumulating jobs.
        delay(if (remaining == 0L) 250L else remaining.coerceAtMost(30_000L))
    }
}
