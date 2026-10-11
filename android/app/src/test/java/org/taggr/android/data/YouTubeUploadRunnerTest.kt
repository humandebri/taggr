package org.taggr.android.data

import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class YouTubeUploadRunnerTest {
    @get:Rule val files = TemporaryFolder()
    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "new")

    private fun job(session: Boolean = true) =
        YouTubeUploadJob(
            "d2fce75f-04dd-4d19-bc89-4b7d30a0a5e4",
            target,
            3,
            MessageDigest.getInstance("SHA-256").digest(byteArrayOf(1, 2, 3)).joinToString("") {
                "%02x".format(it)
            },
            "video/mp4",
            YouTubeUploadMetadata("Video", madeForKids = false, communityGuidelinesAccepted = true),
            1700000000000,
            phase = if (session) YouTubeJobPhase.UPLOADING else YouTubeJobPhase.PREPARING,
            sessionUrl =
                if (session) "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"
                else null,
        )

    private fun response(request: Request, code: Int, body: String = "", range: String? = null) =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("fixture")
            .body(body.toResponseBody())
            .apply { range?.let { header("Range", it) } }
            .build()

    private fun transport(block: (Request) -> Response) =
        YouTubeUploadTransport(
            OkHttpClient.Builder().addInterceptor { block(it.request()) }.build()
        )

    @Test
    fun restartAfterLostFinalReplyQueriesOriginalSessionWithoutUploadingAgain() = runBlocking {
        var record = job()
        val source = files.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
        var calls = 0
        val api = transport { request ->
            assertEquals(YouTubeJobPhase.CHECKING, record.phase)
            if (calls++ == 0) {
                assertEquals("bytes 0-2/3", request.header("Content-Range"))
                val b = Buffer()
                request.body!!.writeTo(b)
                assertArrayEquals(byteArrayOf(1, 2, 3), b.readByteArray())
                throw IOException("accepted; reply lost")
            }
            assertEquals("bytes */3", request.header("Content-Range"))
            response(request, 200, "{\"id\":\"M7lc1UVf-VE\"}")
        }
        val save: suspend (YouTubeUploadJob, YouTubeUploadJob) -> Unit = { old, new ->
            assertEquals(record, old)
            record = YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(new), target)
        }
        val interrupted =
            YouTubeUploadRunner(api, save, { source }).step(record, "test-token", target, "channel")
        assertEquals(YouTubeJobPhase.CHECKING, interrupted.job.phase)
        assertEquals(1, record.retryCount)
        val done =
            YouTubeUploadRunner(api, save, { source }).step(record, "test-token", target, "channel")
        assertEquals(YouTubeJobPhase.COMPLETED, done.job.phase)
        assertEquals("M7lc1UVf-VE", record.videoId)
        assertEquals(2, calls)
    }

    @Test
    fun saveFailureAndWrongTargetPreventAnyDispatch() = runBlocking {
        var calls = 0
        val api = transport {
            calls++
            response(it, 308)
        }
        val runner =
            YouTubeUploadRunner(
                api,
                { _, _ -> throw IOException("disk failure") },
                { files.newFile() },
            )
        try {
            runner.step(job(), "test-token", target, "channel")
            fail("Dispatch after save failure")
        } catch (_: IOException) {}
        try {
            runner.step(job(), "test-token", target.copy(owner = "other"), "channel")
            fail("Wrong owner")
        } catch (_: IllegalArgumentException) {}
        try {
            runner.step(job(), "test-token", target, "other")
            fail("Wrong channel")
        } catch (_: IllegalArgumentException) {}
        assertEquals(0, calls)
    }

    @Test
    fun cancellationKeepsCheckingSnapshotForLaterRecovery() = runBlocking {
        var record = job()
        val entered = CompletableDeferred<Unit>()
        val release = java.util.concurrent.CountDownLatch(1)
        val api = transport { request ->
            entered.complete(Unit)
            check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
            response(request, 308)
        }
        val source = files.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val runner =
            YouTubeUploadRunner(
                api,
                { old, new ->
                    assertEquals(record, old)
                    record = new
                },
                { source },
            )
        val work = launch { runner.step(record, "test-token", target, "channel") }
        try {
            withTimeout(5000) { entered.await() }
            work.cancelAndJoin()
            assertEquals(YouTubeJobPhase.CHECKING, record.phase)
            assertEquals(0, record.retryCount)
        } finally {
            release.countDown()
            work.cancelAndJoin()
        }
    }

    @Test
    fun noProgressRetriesAreBoundedAndQueryBeforeResending() = runBlocking {
        var record = job()
        val source = files.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val ranges = mutableListOf<String>()
        val api = transport {
            ranges += it.header("Content-Range")!!
            response(it, 308)
        }
        val runner =
            YouTubeUploadRunner(
                api,
                { old, new ->
                    assertEquals(record, old)
                    record = new
                },
                { source },
            )
        repeat(9) { runner.step(record, "test-token", target, "channel") }
        assertEquals(YouTubeJobPhase.FAILED, record.phase)
        assertEquals(5, record.retryCount)
        assertEquals(List(9) { if (it % 2 == 0) "bytes 0-2/3" else "bytes */3" }, ranges)
        runner.step(record, "test-token", target, "channel")
        assertEquals(9, ranges.size)
    }

    @Test
    fun creationAuthExpiryAndSessionExpiryPreserveSafeResumeState() = runBlocking {
        var record = job(false)
        var code = 401
        val api = transport { response(it, code) }
        val runner =
            YouTubeUploadRunner(
                api,
                { old, new ->
                    assertEquals(record, old)
                    record = new
                },
                { files.newFile() },
            )
        runner.step(record, "test-token", target, "channel")
        assertEquals(YouTubeJobPhase.AUTHORIZATION_REQUIRED, record.phase)
        runner.resume(record, target)
        assertEquals(YouTubeJobPhase.PREPARING, record.phase)
        record = job().copy(phase = YouTubeJobPhase.CHECKING, acknowledgedBytes = 2)
        code = 404
        runner.step(record, "test-token", target, "channel")
        assertEquals(YouTubeJobPhase.PREPARING, record.phase)
        assertNull(record.sessionUrl)
        assertEquals(0L, record.acknowledgedBytes)
    }
}
