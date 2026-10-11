package org.taggr.android.data

import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException

internal data class YouTubeUploadStep(
    val job: YouTubeUploadJob,
    val retryAfterSeconds: Long? = null,
    val errorMessage: String? = null,
)

/** One dispatch per step. Persist CHECKING before bytes leave, then recover by status query. */
internal class YouTubeUploadRunner(
    private val transport: YouTubeUploadTransport,
    private val save: suspend (expected: YouTubeUploadJob, updated: YouTubeUploadJob) -> Unit,
    private val source: (YouTubeUploadJob) -> File,
) {
    suspend fun resume(job: YouTubeUploadJob, actualTarget: YouTubeDraftTarget): YouTubeUploadJob {
        require(job.target == actualTarget)
        require(job.phase in listOf(YouTubeJobPhase.FAILED, YouTubeJobPhase.AUTHORIZATION_REQUIRED))
        val next =
            job.copy(
                phase =
                    if (job.sessionUrl == null) YouTubeJobPhase.PREPARING
                    else YouTubeJobPhase.CHECKING,
                retryCount = 0,
            )
        save(job, next)
        return next
    }

    suspend fun step(
        job: YouTubeUploadJob,
        token: String,
        actualTarget: YouTubeDraftTarget,
        authorizedChannel: String,
    ): YouTubeUploadStep {
        require(job.target == actualTarget && job.target.channelId == authorizedChannel) {
            "The upload account, channel or draft changed."
        }
        if (
            job.phase in
                listOf(
                    YouTubeJobPhase.COMPLETED,
                    YouTubeJobPhase.CANCELLED,
                    YouTubeJobPhase.FAILED,
                    YouTubeJobPhase.AUTHORIZATION_REQUIRED,
                )
        )
            return YouTubeUploadStep(job)
        val pending =
            if (job.phase == YouTubeJobPhase.UPLOADING) job.copy(phase = YouTubeJobPhase.CHECKING)
            else job
        // This also rejects a stale snapshot before making any remote request.
        save(job, pending)
        val response: YouTubeUploadStatus
        if (pending.sessionUrl == null) {
            val session =
                try {
                    transport.createSession(job.metadata, job.byteCount, job.mimeType, token)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: YouTubeUploadHttpException) {
                    return when {
                        e.status == 401 ->
                            commit(
                                pending,
                                pending.copy(phase = YouTubeJobPhase.AUTHORIZATION_REQUIRED),
                                error = "Reconnect YouTube to continue this upload.",
                            )
                        e.status == 429 || e.status in 500..599 ->
                            interrupted(pending, e.retryAfterSeconds)
                        else ->
                            commit(
                                pending,
                                pending.copy(phase = YouTubeJobPhase.FAILED),
                                error = e.message,
                            )
                    }
                } catch (_: IOException) {
                    return interrupted(pending)
                } catch (_: IllegalArgumentException) {
                    return invalid(pending)
                }
            val next =
                pending.copy(
                    sessionUrl = session.url.toString(),
                    phase = YouTubeJobPhase.UPLOADING,
                    retryCount = 0,
                )
            save(pending, next)
            return YouTubeUploadStep(next)
        }
        val session = YouTubeUploadSession.parse(pending.sessionUrl)
        response =
            try {
                if (job.phase == YouTubeJobPhase.UPLOADING && job.acknowledgedBytes < job.byteCount)
                    transport.uploadChunk(
                        session,
                        source(job),
                        job.byteCount,
                        job.mimeType,
                        job.acknowledgedBytes,
                        token,
                    )
                else transport.status(session, job.byteCount, token)
            } catch (e: CancellationException) {
                throw e
            } catch (_: IOException) {
                return interrupted(pending)
            } catch (_: IllegalArgumentException) {
                return invalid(pending)
            }
        return when (response) {
            is YouTubeUploadStatus.Complete ->
                commit(
                    pending,
                    pending.copy(
                        phase = YouTubeJobPhase.COMPLETED,
                        acknowledgedBytes = job.byteCount,
                        videoId = response.videoId,
                        retryCount = 0,
                    ),
                )
            is YouTubeUploadStatus.Incomplete -> {
                val progress = response.acknowledgedBytes > job.acknowledgedBytes
                val stalled =
                    !progress &&
                        (job.phase == YouTubeJobPhase.UPLOADING ||
                            response.acknowledgedBytes == job.byteCount)
                val retries =
                    if (progress) 0
                    else if (stalled) minOf(5, pending.retryCount + 1) else pending.retryCount
                commit(
                    pending,
                    pending.copy(
                        phase =
                            if (retries == 5) YouTubeJobPhase.FAILED
                            else if (stalled || response.acknowledgedBytes == job.byteCount)
                                YouTubeJobPhase.CHECKING
                            else YouTubeJobPhase.UPLOADING,
                        acknowledgedBytes = response.acknowledgedBytes,
                        retryCount = retries,
                    ),
                    if (retries == 5) null
                    else
                        response.retryAfterSeconds
                            ?: if (stalled) minOf(60L, 1L shl retries)
                            else if (response.acknowledgedBytes == job.byteCount) 1L else null,
                    if (stalled)
                        "YouTube has not acknowledged new progress. Check status before sending again."
                    else null,
                )
            }
            YouTubeUploadStatus.AuthorizationRequired ->
                commit(
                    pending,
                    pending.copy(phase = YouTubeJobPhase.AUTHORIZATION_REQUIRED),
                    error = "Reconnect YouTube to continue this upload.",
                )
            YouTubeUploadStatus.SessionExpired ->
                commit(
                    pending,
                    pending.copy(
                        phase = YouTubeJobPhase.PREPARING,
                        sessionUrl = null,
                        acknowledgedBytes = 0,
                        retryCount = 0,
                    ),
                    error = "The YouTube session expired. A new upload session is needed.",
                )
            is YouTubeUploadStatus.Retry -> interrupted(pending, response.retryAfterSeconds)
            is YouTubeUploadStatus.Failed ->
                commit(
                    pending,
                    pending.copy(phase = YouTubeJobPhase.FAILED),
                    error = "YouTube rejected the upload (HTTP ${response.httpStatus}).",
                )
        }
    }

    private suspend fun interrupted(
        pending: YouTubeUploadJob,
        delay: Long? = null,
    ): YouTubeUploadStep {
        val retries = minOf(5, pending.retryCount + 1)
        return commit(
            pending,
            pending.copy(
                retryCount = retries,
                phase = if (retries == 5) YouTubeJobPhase.FAILED else pending.phase,
            ),
            if (retries == 5) null else delay ?: minOf(60L, 1L shl retries),
            "Upload interrupted. Its server status will be checked before sending again.",
        )
    }

    private suspend fun invalid(pending: YouTubeUploadJob) =
        commit(
            pending,
            pending.copy(phase = YouTubeJobPhase.FAILED),
            error =
                "The upload response or source was invalid. Check the saved upload before retrying.",
        )

    private suspend fun commit(
        expected: YouTubeUploadJob,
        next: YouTubeUploadJob,
        delay: Long? = null,
        error: String? = null,
    ): YouTubeUploadStep {
        save(expected, next)
        return YouTubeUploadStep(next, delay, error)
    }
}
