package org.taggr.android.data

import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*
import org.junit.rules.TemporaryFolder

class YouTubeUploadExecutionTest {
    @get:Rule val files = TemporaryFolder()
    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "new")
    private val credentials =
        YouTubeUploadCredentials("fixture-token", "test@example.test", "channel")

    private fun job() =
        YouTubeUploadJob(
            "d2fce75f-04dd-4d19-bc89-4b7d30a0a5e4",
            target,
            3,
            "a".repeat(64),
            "video/mp4",
            YouTubeUploadMetadata("Video", madeForKids = false, communityGuidelinesAccepted = true),
            1700000000000,
            YouTubeJobPhase.UPLOADING,
            "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=execution",
            googleAccountEmail = credentials.accountEmail,
        )

    @Test
    fun lostCompletionReplyWaitsInSavedCheckingStateThenQueriesWithoutResending() = runBlocking {
        var record = job()
        var calls = 0
        var dispatching = false
        val waits = mutableListOf<Long>()
        val source = files.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val api =
            YouTubeUploadTransport(
                OkHttpClient.Builder()
                    .addInterceptor { chain ->
                        val request = chain.request()
                        assertTrue(dispatching)
                        assertEquals(YouTubeJobPhase.CHECKING, record.phase)
                        if (calls++ == 0) {
                            assertEquals("bytes 0-2/3", request.header("Content-Range"))
                            val buffer = Buffer()
                            request.body!!.writeTo(buffer)
                            assertArrayEquals(byteArrayOf(1, 2, 3), buffer.readByteArray())
                            throw IOException("accepted; reply lost")
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
        val runner =
            YouTubeUploadRunner(
                api,
                { old, new ->
                    assertEquals(record, old)
                    record = YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(new), target)
                },
                { source },
            )
        val done =
            YouTubeUploadExecution(
                    runner,
                    { "owner" },
                    {
                        assertFalse(dispatching)
                        assertEquals(YouTubeJobPhase.CHECKING, record.phase)
                        waits += it
                    },
                    dispatch = {
                        dispatching = true
                        try {
                            it()
                        } finally {
                            dispatching = false
                        }
                    },
                )
                .run(record, target, credentials, {})
        assertEquals(YouTubeJobPhase.COMPLETED, done.phase)
        assertEquals("M7lc1UVf-VE", done.videoId)
        assertEquals(listOf(2000L), waits)
        assertEquals(2, calls)
    }

    @Test
    fun accountSwitchAfterAcknowledgementStopsBeforeNextDispatchAndPreservesProgress() =
        runBlocking {
            var record = job()
            var owner = "owner"
            var calls = 0
            val source = files.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val api =
                YouTubeUploadTransport(
                    OkHttpClient.Builder()
                        .addInterceptor { chain ->
                            calls++
                            Response.Builder()
                                .request(chain.request())
                                .protocol(Protocol.HTTP_1_1)
                                .code(308)
                                .message("fixture")
                                .header("Range", "bytes=0-0")
                                .body("".toResponseBody())
                                .build()
                        }
                        .build()
                )
            val runner =
                YouTubeUploadRunner(
                    api,
                    { old, new ->
                        assertEquals(record, old)
                        record = new
                    },
                    { source },
                )
            try {
                YouTubeUploadExecution(runner, { owner }).run(record, target, credentials) {
                    owner = "other"
                }
                fail("Dispatch continued for a different TAGGR owner")
            } catch (_: IllegalArgumentException) {}
            assertEquals(1, calls)
            assertEquals(1L, record.acknowledgedBytes)
            assertEquals(YouTubeJobPhase.UPLOADING, record.phase)
        }

    @Test
    fun legacyOrMismatchedGoogleCredentialsNeverReachPersistenceOrNetwork() = runBlocking {
        var calls = 0
        val api =
            YouTubeUploadTransport(
                OkHttpClient.Builder()
                    .addInterceptor {
                        calls++
                        error("Unexpected dispatch")
                    }
                    .build()
            )
        val runner =
            YouTubeUploadRunner(
                api,
                { _, _ ->
                    calls++
                    error("Unexpected save")
                },
                { files.newFile() },
            )
        val execution = YouTubeUploadExecution(runner, { "owner" })
        for ((saved, access) in
            listOf(
                job().copy(googleAccountEmail = null) to credentials,
                job() to YouTubeUploadCredentials("token", "other@example.test", "channel"),
                job() to
                    YouTubeUploadCredentials("token", credentials.accountEmail, "other-channel"),
            )) {
            try {
                execution.run(saved, target, access, {})
                fail("Unbound credentials ran")
            } catch (_: IllegalArgumentException) {}
        }
        assertEquals(0, calls)
        assertFalse(credentials.toString().contains("fixture-token"))
        assertFalse(credentials.toString().contains(credentials.accountEmail))
    }
}
