package org.taggr.android.data

import android.content.Context
import android.os.PowerManager
import kotlinx.coroutines.withTimeout

/** Only the pre-Android-14 foreground-service path needs a manually owned CPU lock. */
internal class YouTubeUploadWake(context: Context, private val timeoutMillis: Long = 180_000) {
    private val manager = context.getSystemService(PowerManager::class.java)

    suspend fun <T> run(block: suspend () -> T): T {
        val lock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TAGGR:YouTubeUpload")
        lock.setReferenceCounted(false)
        lock.acquire(timeoutMillis + 1_000)
        try {
            return withTimeout(timeoutMillis) { block() }
        } finally {
            if (lock.isHeld) lock.release()
        }
    }
}
