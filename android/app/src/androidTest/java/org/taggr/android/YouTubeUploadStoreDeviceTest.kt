package org.taggr.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class YouTubeUploadStoreDeviceTest {
    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "edit/42")
    private val metadata =
        YouTubeUploadMetadata(
            " Private title ",
            madeForKids = false,
            communityGuidelinesAccepted = true,
        )
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun encryptedGoogleAccountBindingSurvivesReopenAndCannotBeRemovedOrReplaced() = runBlocking {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val legacy =
            store.create(ByteArrayInputStream(byteArrayOf(1, 2, 3)), target, metadata, "video/mp4")
        try {
            val bound = legacy.copy(googleAccountEmail = "test@example.test")
            store.save(bound, legacy)
            val reopened = YouTubeUploadJobStore(context, namespace)
            assertEquals(bound, reopened.load(target))
            val encrypted =
                java.io
                    .File(store.source(bound).parentFile, "job.bin")
                    .readBytes()
                    .toString(Charsets.ISO_8859_1)
            assertFalse(encrypted.contains("test@example.test"))
            for (email in listOf(null, "other@example.test")) {
                try {
                    reopened.save(bound.copy(googleAccountEmail = email), bound)
                    fail("Google account rebound")
                } catch (_: IllegalArgumentException) {}
                assertEquals(bound, reopened.load(target))
            }
        } finally {
            store.clear(target)
        }
    }

    @Test
    fun corruptedRecordCanBeExplicitlyDiscardedAndNewEncryptedJobCreated() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val job =
            store.create(ByteArrayInputStream(byteArrayOf(1, 2, 3)), target, metadata, "video/mp4")
        val record = java.io.File(store.source(job).parentFile, "job.bin")
        try {
            val bytes = record.readBytes()
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            record.writeBytes(bytes)
            try {
                store.load(target)
                fail("Corrupt record restored")
            } catch (_: javax.crypto.AEADBadTagException) {}
            val snapshot = requireNotNull(store.discardSnapshot())
            assertEquals(record.length() + 3, snapshot.privateBytes)
            store.discardConfirmed(snapshot)
            assertFalse(record.exists())
            assertFalse(store.source(job).exists())
            assertNull(store.load(target))
            val fresh =
                store.create(
                    ByteArrayInputStream(byteArrayOf(4, 5, 6)),
                    target,
                    metadata,
                    "video/mp4",
                )
            assertEquals(fresh, store.load(target))
        } finally {
            store.discardSnapshot()?.let { store.discardConfirmed(it) }
        }
    }

    @Test
    fun changedRecordRejectsOldDiscardConfirmationAndOtherNamespaceIsPreserved() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val other = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val job = store.create(ByteArrayInputStream(byteArrayOf(1)), target, metadata, "video/mp4")
        val otherJob =
            other.create(ByteArrayInputStream(byteArrayOf(2)), target, metadata, "video/mp4")
        try {
            val old = requireNotNull(store.discardSnapshot())
            val updated =
                job.copy(
                    phase = YouTubeJobPhase.CHECKING,
                    sessionUrl =
                        "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=changed",
                )
            store.save(updated, job)
            try {
                store.discardConfirmed(old)
                fail("Stale confirmation deleted updated job")
            } catch (_: IllegalArgumentException) {}
            assertEquals(updated, store.load(target))
            store.discardConfirmed(requireNotNull(store.discardSnapshot()))
            assertEquals(otherJob, other.load(target))
            assertTrue(other.source(otherJob).exists())
        } finally {
            store.clear(target)
            other.clear(target)
        }
    }

    @Test
    fun expiredRecordIsPreservedUntilDiscardAndUnexpectedFilesPreventDeletion() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val now = System.currentTimeMillis()
        val job =
            store.create(ByteArrayInputStream(byteArrayOf(1)), target, metadata, "video/mp4", now)
        val unexpected = java.io.File(store.source(job).parentFile, "notes.txt")
        try {
            try {
                store.load(target, now + YouTubeUploadJobCodec.MAX_AGE_MILLIS + 1)
                fail("Expired job restored")
            } catch (_: IllegalArgumentException) {}
            val snapshot = requireNotNull(store.discardSnapshot())
            unexpected.writeText("Preserve")
            try {
                store.discardConfirmed(snapshot)
                fail("Unexpected file deleted")
            } catch (_: IllegalArgumentException) {}
            assertEquals("Preserve", unexpected.readText())
            assertTrue(store.source(job).exists())
            assertTrue(unexpected.delete())
            store.discardConfirmed(requireNotNull(store.discardSnapshot()))
            assertNull(store.load(target))
        } finally {
            unexpected.delete()
            store.clear(target)
        }
    }

    @Test
    fun lostCompletionReplyRecoversFromEncryptedRecordWithoutResendingVideo() = runBlocking {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val now = System.currentTimeMillis()
        val bytes = byteArrayOf(1, 2, 3)
        val original = store.create(ByteArrayInputStream(bytes), target, metadata, "video/mp4", now)
        val uploading =
            original.copy(
                phase = YouTubeJobPhase.UPLOADING,
                sessionUrl =
                    "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=recovery",
            )
        store.save(uploading, original)
        var calls = 0
        val api =
            YouTubeUploadTransport(
                OkHttpClient.Builder()
                    .addInterceptor { chain ->
                        val request = chain.request()
                        assertEquals(
                            YouTubeJobPhase.CHECKING,
                            runBlocking { store.load(target, now) }!!.phase,
                        )
                        if (calls++ == 0) {
                            assertEquals("bytes 0-2/3", request.header("Content-Range"))
                            val buffer = Buffer()
                            request.body!!.writeTo(buffer)
                            assertArrayEquals(bytes, buffer.readByteArray())
                            throw IOException("Accepted video; completion reply lost")
                        }
                        assertEquals("bytes */3", request.header("Content-Range"))
                        Response.Builder()
                            .request(request)
                            .protocol(Protocol.HTTP_1_1)
                            .code(200)
                            .message("fixture")
                            .body("{\"id\":\"M7lc1UVf-VE\"}".toResponseBody())
                            .build()
                    }
                    .build()
            )
        try {
            YouTubeUploadRunner(api, { old, new -> store.save(new, old) }, store::source)
                .step(uploading, "test-token", target, target.channelId)
            val restored = YouTubeUploadJobStore(context, namespace)
            val pending = restored.load(target, now)!!
            assertEquals(YouTubeJobPhase.CHECKING, pending.phase)
            assertEquals(1, pending.retryCount)
            try {
                restored.save(uploading, uploading)
                fail("Stale state overwrote recovery record")
            } catch (_: IllegalArgumentException) {}
            assertEquals(pending, restored.load(target, now))
            val done =
                YouTubeUploadRunner(api, { old, new -> restored.save(new, old) }, restored::source)
                    .step(pending, "test-token", target, target.channelId)
                    .job
            assertEquals(YouTubeJobPhase.COMPLETED, done.phase)
            assertEquals("M7lc1UVf-VE", done.videoId)
            assertEquals(done, YouTubeUploadJobStore(context, namespace).load(target, now))
            assertFalse(restored.source(original).exists())
            assertEquals(2, calls)
        } finally {
            store.clear(target)
        }
    }

    @Test
    fun keystoreEncryptedRecordRestoresAcrossStoreInstancesAndBindsEveryScope() = runBlocking {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val now = System.currentTimeMillis()
        val bytes = ByteArray(100000) { (it % 251).toByte() }
        val job = store.create(ByteArrayInputStream(bytes), target, metadata, "video/mp4", now)
        try {
            val pending =
                job.copy(
                    phase = YouTubeJobPhase.CHECKING,
                    sessionUrl =
                        "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=private-session",
                    acknowledgedBytes = 70000,
                )
            store.save(pending)
            val restored = YouTubeUploadJobStore(context, namespace)
            assertEquals(pending, restored.load(target, now))
            assertArrayEquals(bytes, restored.source(job).readBytes())
            val encrypted =
                java.io
                    .File(restored.source(job).parentFile, "job.bin")
                    .readBytes()
                    .toString(Charsets.ISO_8859_1)
            assertFalse(encrypted.contains("Private title"))
            assertFalse(encrypted.contains("private-session"))
            for (other in
                listOf(
                    target.copy(owner = "other"),
                    target.copy(network = "other"),
                    target.copy(channelId = "other"),
                    target.copy(draftSlot = "new"),
                )) {
                try {
                    restored.load(other, now)
                    fail("Wrong scope decrypted")
                } catch (_: javax.crypto.AEADBadTagException) {}
                try {
                    restored.clear(other)
                    fail("Wrong scope cleared")
                } catch (_: javax.crypto.AEADBadTagException) {}
            }
            assertEquals(pending, restored.load(target, now))
        } finally {
            store.clear(target)
        }
        assertNull(YouTubeUploadJobStore(context, namespace).load(target, now))
        assertFalse(store.source(job).exists())
    }

    @Test
    fun completedReceiptSurvivesWhileOwnedSourceIsRemoved() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val now = System.currentTimeMillis()
        val job =
            store.create(
                ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                target,
                metadata,
                "video/mp4",
                now,
            )
        try {
            val done =
                job.copy(
                    phase = YouTubeJobPhase.COMPLETED,
                    sessionUrl =
                        "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=session",
                    acknowledgedBytes = 3,
                    videoId = "M7lc1UVf-VE",
                )
            store.save(done)
            assertFalse(store.source(job).exists())
            assertEquals(done, store.load(target, now))
            try {
                store.save(job)
                fail("Completed job restarted")
            } catch (_: IllegalArgumentException) {}
        } finally {
            store.clear(target)
        }
    }

    @Test
    fun sameLengthSourceMutationAndExpiredJobAreRejectedWithoutDeletingRecord() = runBlocking {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val now = System.currentTimeMillis()
        val job =
            store.create(
                ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                target,
                metadata,
                "video/mp4",
                now,
            )
        try {
            try {
                store.load(target, now + YouTubeUploadJobCodec.MAX_AGE_MILLIS + 1)
                fail("Expired job loaded")
            } catch (_: IllegalArgumentException) {}
            store.source(job).writeBytes(byteArrayOf(3, 2, 1))
            try {
                store.load(target, now)
                fail("Changed source loaded")
            } catch (_: IllegalArgumentException) {}
            assertTrue(store.source(job).exists())
        } finally {
            store.clear(target)
        }
    }
}
