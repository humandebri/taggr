package org.taggr.android.data

import kotlinx.coroutines.CancellationException

/** Commit the original draft before acknowledging its completed upload. */
internal class YouTubeDraftCompletion(
    private val store: YouTubeUploadJobStore,
    private val currentOwner: () -> String?,
) {
    suspend fun consume(
        target: YouTubeDraftTarget,
        googleEmail: String,
        insert: (YouTubeUploadJob) -> Unit,
    ): Boolean {
        if (currentOwner() != target.owner || !YouTubeBackground.dispatch.tryLock()) return false
        try {
            val job =
                try {
                    store.progress(target)
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (_: Exception) {
                    return false
                } ?: return false
            if (
                job.phase != YouTubeJobPhase.COMPLETED ||
                    (job.googleAccountEmail != null && job.googleAccountEmail != googleEmail) ||
                    currentOwner() != target.owner
            )
                return false
            insert(job)
            store.clear(target, job)
            return true
        } finally {
            YouTubeBackground.dispatch.unlock()
        }
    }
}
