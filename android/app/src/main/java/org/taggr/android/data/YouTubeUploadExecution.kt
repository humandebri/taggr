package org.taggr.android.data

import kotlinx.coroutines.delay

internal class YouTubeUploadCredentials(
    val token: String,
    val accountEmail: String,
    val channelId: String,
) {
    override fun toString() = "YouTubeUploadCredentials(redacted)"
}

/** Shared foreground/background loop. Auth/OS scheduling belong to the caller. */
internal class YouTubeUploadExecution(
    private val runner: YouTubeUploadRunner,
    private val currentOwner: suspend () -> String?,
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val dispatch: suspend (suspend () -> YouTubeUploadStep) -> YouTubeUploadStep = { it() },
) {
    suspend fun run(
        initial: YouTubeUploadJob,
        target: YouTubeDraftTarget,
        access: YouTubeUploadCredentials,
        changed: suspend (YouTubeUploadStep) -> Unit,
    ): YouTubeUploadJob {
        require(
            initial.target == target &&
                initial.googleAccountEmail != null &&
                initial.googleAccountEmail == access.accountEmail &&
                target.channelId == access.channelId
        ) {
            "Reconnect the Google account and channel selected for this upload."
        }
        var saved = initial
        while (
            saved.phase in
                listOf(
                    YouTubeJobPhase.PREPARING,
                    YouTubeJobPhase.CHECKING,
                    YouTubeJobPhase.UPLOADING,
                )
        ) {
            val step = dispatch {
                require(currentOwner() == target.owner) {
                    "Return to the TAGGR account that started this upload."
                }
                runner.step(saved, access.token, target, access.channelId)
            }
            saved = step.job
            changed(step)
            if (
                saved.phase in
                    listOf(
                        YouTubeJobPhase.PREPARING,
                        YouTubeJobPhase.CHECKING,
                        YouTubeJobPhase.UPLOADING,
                    )
            )
                step.retryAfterSeconds?.let { wait(it * 1000L) }
        }
        return saved
    }
}
