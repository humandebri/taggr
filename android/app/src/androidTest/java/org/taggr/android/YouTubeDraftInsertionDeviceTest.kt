package org.taggr.android

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class YouTubeDraftInsertionDeviceTest {
    @Test
    fun discardingOneDraftRemovesItsInsertionReceiptsAndAllowsFreshInsertion() {
        val name = "youtube-draft-test-" + UUID.randomUUID()
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        try {
            val job = completed("reply/42")
            val key = "canister/owner/reply/42"
            assertTrue(
                prefs
                    .edit()
                    .putString("other", "Preserve")
                    .putBoolean("other/youtube/receipt", true)
                    .putString("$key/realm", "Realm")
                    .commit()
            )
            YouTubeDraftInsertion.insert(prefs, key, job, job.target, "Original")
            YouTubeDraftInsertion.clear(prefs, key)
            assertFalse(prefs.contains(key))
            assertFalse(prefs.contains("$key/realm"))
            assertFalse(prefs.all.keys.any { it.startsWith("$key/youtube/") })
            assertEquals("Preserve", prefs.getString("other", null))
            assertTrue(prefs.getBoolean("other/youtube/receipt", false))
            assertEquals(
                "Fresh draft\n\nhttps://www.youtube.com/watch?v=M7lc1UVf-VE",
                YouTubeDraftInsertion.insert(prefs, key, job, job.target, "Fresh draft"),
            )
        } finally {
            context.deleteSharedPreferences(name)
        }
    }

    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun completed(slot: String) =
        YouTubeUploadJob(
            UUID.randomUUID().toString(),
            YouTubeDraftTarget("owner", "network", "canister", "channel", slot),
            3,
            "a".repeat(64),
            "video/mp4",
            YouTubeUploadMetadata("Video", madeForKids = false, communityGuidelinesAccepted = true),
            System.currentTimeMillis(),
            YouTubeJobPhase.COMPLETED,
            "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=done",
            3,
            videoId = "M7lc1UVf-VE",
        )

    @Test
    fun eachDraftKeepsItsBodyRealmAndOneInsertionAfterReceiptRestoration() {
        val name = "youtube-draft-test-" + UUID.randomUUID()
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        try {
            for (slot in listOf("new", "reply/42", "edit/42", "repost/42")) {
                val key = "canister/owner/$slot"
                val job = completed(slot)
                assertTrue(
                    prefs
                        .edit()
                        .putString(key, "Original $slot")
                        .putString("$key/realm", "Realm")
                        .commit()
                )
                val inserted =
                    YouTubeDraftInsertion.insert(prefs, key, job, job.target, "stale fallback")
                assertEquals(
                    "Original $slot\n\nhttps://www.youtube.com/watch?v=M7lc1UVf-VE",
                    inserted,
                )
                val restoredJob =
                    YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(job), job.target)
                val restoredPrefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
                assertEquals(
                    inserted,
                    YouTubeDraftInsertion.insert(
                        restoredPrefs,
                        key,
                        restoredJob,
                        job.target,
                        "different fallback",
                    ),
                )
                assertEquals("Realm", restoredPrefs.getString("$key/realm", null))
            }
            for (slot in listOf("new", "reply/42", "edit/42", "repost/42")) assertEquals(
                1,
                "https://www.youtube.com"
                    .toRegex(RegexOption.LITERAL)
                    .findAll(prefs.getString("canister/owner/$slot", "")!!)
                    .count(),
            )
        } finally {
            context.deleteSharedPreferences(name)
        }
    }

    @Test
    fun changedScopeAndUnfinishedUploadDoNotChangeAnyDraft() {
        val name = "youtube-draft-test-" + UUID.randomUUID()
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val job = completed("reply/42")
        try {
            assertTrue(prefs.edit().putString("draft", "Original").commit())
            val before = prefs.all.toMap()
            for (target in
                listOf(
                    job.target.copy(owner = "other"),
                    job.target.copy(network = "other"),
                    job.target.copy(canister = "other"),
                    job.target.copy(channelId = "other"),
                    job.target.copy(draftSlot = "edit/42"),
                )) {
                try {
                    YouTubeDraftInsertion.insert(prefs, "draft", job, target, "fallback")
                    fail("Wrong target inserted")
                } catch (_: IllegalArgumentException) {}
                assertEquals(before, prefs.all)
            }
            try {
                YouTubeDraftInsertion.insert(
                    prefs,
                    "draft",
                    job.copy(phase = YouTubeJobPhase.CHECKING, videoId = null),
                    job.target,
                    "fallback",
                )
                fail("Unconfirmed video inserted")
            } catch (_: IllegalArgumentException) {}
            assertEquals(before, prefs.all)
        } finally {
            context.deleteSharedPreferences(name)
        }
    }
}
