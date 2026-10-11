package org.taggr.android.data

import android.content.SharedPreferences

/** The URL and its insertion receipt are committed together in the existing draft store. */
internal object YouTubeDraftInsertion {
    fun clear(drafts: SharedPreferences, key: String) {
        val edit = drafts.edit().remove(key).remove("$key/realm")
        drafts.all.keys.filter { it.startsWith("$key/youtube/") }.forEach { edit.remove(it) }
        check(edit.commit()) { "The saved draft could not be removed. Try again." }
    }

    fun insert(
        drafts: SharedPreferences,
        key: String,
        job: YouTubeUploadJob,
        currentTarget: YouTubeDraftTarget,
        fallbackBody: String,
    ): String {
        require(job.phase == YouTubeJobPhase.COMPLETED && job.target == currentTarget) {
            "Return to the account and draft that started this upload."
        }
        val body = drafts.getString(key, null) ?: fallbackBody
        val receiptKey = "$key/youtube/${job.id}"
        if (drafts.getBoolean(receiptKey, false)) return body
        val next =
            body +
                (if (body.isBlank()) "" else "\n\n") +
                "https://www.youtube.com/watch?v=${job.videoId}"
        check(drafts.edit().putString(key, next).putBoolean(receiptKey, true).commit()) {
            "The uploaded video could not be saved to this draft. Try again."
        }
        return next
    }
}
