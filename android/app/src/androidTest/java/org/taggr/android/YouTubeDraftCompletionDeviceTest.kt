package org.taggr.android

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

/** Real Keystore records and atomic draft receipts; no Google or backend account action. */
@RunWith(AndroidJUnit4::class)
class YouTubeDraftCompletionDeviceTest {
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "reply/42")

    private fun metadata() =
        YouTubeUploadMetadata("Fixture", madeForKids = false, communityGuidelinesAccepted = true)

    private suspend fun complete(store: YouTubeUploadJobStore): YouTubeUploadJob {
        val old =
            store.create(
                ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                target,
                metadata(),
                "video/mp4",
                googleAccountEmail = "test@example.test",
            )
        val done =
            old.copy(
                phase = YouTubeJobPhase.COMPLETED,
                sessionUrl =
                    "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=fixture",
                acknowledgedBytes = 3,
                videoId = "M7lc1UVf-VE",
            )
        store.save(done, old)
        return done
    }

    @Test
    fun automaticConsumptionCommitsOriginalDraftThenAcknowledgesAndNeverDuplicates() = runBlocking {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val done = complete(store)
        val prefsName = "completion-draft-" + UUID.randomUUID()
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val key = "canister/owner/42"
        prefs
            .edit()
            .putString(key, "Latest saved reply")
            .putString("other-draft", "Unchanged")
            .commit()
        var visibleBody = "stale UI"
        try {
            val consumer = YouTubeDraftCompletion(store) { "owner" }
            assertTrue(
                consumer.consume(target, "test@example.test") {
                    visibleBody = YouTubeDraftInsertion.insert(prefs, key, it, target, visibleBody)
                    assertEquals(it, runBlocking { store.load(target) })
                }
            )
            assertEquals(
                "Latest saved reply\n\nhttps://www.youtube.com/watch?v=M7lc1UVf-VE",
                visibleBody,
            )
            assertEquals(visibleBody, prefs.getString(key, null))
            assertEquals("Unchanged", prefs.getString("other-draft", null))
            assertNull(store.load(target))
            assertFalse(
                YouTubeDraftCompletion(YouTubeUploadJobStore(context, namespace)) { "owner" }
                    .consume(target, "test@example.test") { fail("Duplicate insertion") }
            )
            assertEquals(
                visibleBody,
                YouTubeDraftInsertion.insert(prefs, key, done, target, "fallback"),
            )
        } finally {
            store.clear(target)
            context.deleteSharedPreferences(prefsName)
        }
    }

    @Test
    fun failedInsertionAndForeignScopesPreserveCompletedReceipt() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val done = complete(store)
        try {
            val consumer = YouTubeDraftCompletion(store) { "owner" }
            try {
                consumer.consume(target, "test@example.test") { error("fixture draft failure") }
                fail("Expected failure")
            } catch (_: IllegalStateException) {}
            assertEquals(done, store.load(target))
            assertFalse(
                consumer.consume(target, "other@example.test") { fail("Wrong Google account") }
            )
            assertFalse(
                consumer.consume(target.copy(draftSlot = "new"), "test@example.test") {
                    fail("Wrong draft")
                }
            )
            var ownerChecks = 0
            assertFalse(
                YouTubeDraftCompletion(store) { if (ownerChecks++ == 0) "owner" else "other-owner" }
                    .consume(target, "test@example.test") { fail("Owner changed during read") }
            )
            assertEquals(done, store.load(target))
        } finally {
            store.clear(target)
        }
    }

    @Test
    fun acknowledgmentSnapshotCannotEraseReplacementUpload() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val done = complete(store)
        store.clear(target)
        val replacement =
            store.create(
                ByteArrayInputStream(byteArrayOf(4, 5, 6)),
                target,
                metadata(),
                "video/mp4",
                googleAccountEmail = "test@example.test",
            )
        try {
            try {
                store.clear(target, done)
                fail("Expected changed receipt refusal")
            } catch (_: IllegalArgumentException) {}
            assertEquals(replacement, store.load(target))
            assertTrue(store.source(replacement).exists())
        } finally {
            store.clear(target)
        }
    }
}
