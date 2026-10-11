package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.io.IOException
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class YouTubeUploadsTest {
    @get:Rule val files = TemporaryFolder()

    @Test
    fun channelLookupBindsReturnedOwnerAndRejectsMissingChannel() = runBlocking {
        val api = transport { request ->
            assertEquals("/youtube/v3/channels", request.url.encodedPath)
            assertEquals("true", request.url.queryParameter("mine"))
            response(
                request,
                200,
                "{\"items\":[{\"id\":\"channel-1\",\"snippet\":{\"title\":\"Test channel\"}}]}",
            )
        }
        assertEquals(
            YouTubeChannel("channel-1", "Test channel"),
            api.channel("test-token", "channel-1"),
        )
        try {
            api.channel("test-token", "other")
            fail("Wrong channel accepted")
        } catch (_: IllegalArgumentException) {}
        try {
            transport { response(it, 200, "{\"items\":[]}") }.channel("test-token")
            fail("Missing channel accepted")
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun accountLookupRequiresVerifiedEmailAndNeverFollowsRedirect() = runBlocking {
        assertEquals(
            "test@example.test",
            transport {
                    response(it, 200, "{\"email\":\"test@example.test\",\"email_verified\":true}")
                }
                .googleAccountEmail("test-token"),
        )
        for (body in
            listOf(
                "{}",
                "{\"email\":\"test@example.test\",\"email_verified\":false}",
                "{\"email\":\"a@b@c\",\"email_verified\":true}",
            )) {
            try {
                transport { response(it, 200, body) }.googleAccountEmail("test-token")
                fail("Invalid account accepted")
            } catch (_: IllegalArgumentException) {}
        }
        var calls = 0
        try {
            transport {
                    calls++
                    response(it, 302, headers = mapOf("Location" to "https://other.example.test/"))
                }
                .googleAccountEmail("test-token")
            fail("Redirect accepted")
        } catch (_: IllegalArgumentException) {}
        assertEquals(1, calls)
    }

    private val session =
        YouTubeUploadSession.parse(
            "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"
        )

    private fun response(
        request: Request,
        code: Int,
        body: String = "",
        headers: Map<String, String> = emptyMap(),
    ) =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .message("fixture")
            .code(code)
            .body(body.toResponseBody("application/json".toMediaType()))
            .apply {
                headers.forEach { (key, value) -> header(key, value) }
            }
            .build()

    private fun transport(block: (Request) -> Response) =
        YouTubeUploadTransport(
            OkHttpClient.Builder().addInterceptor { block(it.request()) }.build()
        )

    @Test
    fun cancellingSuspendedRequestCancelsOwnedHttpCall() = runBlocking {
        val entered = CompletableDeferred<Call>()
        val release = java.util.concurrent.CountDownLatch(1)
        val client =
            OkHttpClient.Builder()
                .addInterceptor { chain ->
                    entered.complete(chain.call())
                    check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                    response(chain.request(), 308)
                }
                .build()
        val work = launch { YouTubeUploadTransport(client).status(session, 10, "test-token") }
        try {
            val call = withTimeout(5_000) { entered.await() }
            work.cancelAndJoin()
            assertTrue(call.isCanceled())
        } finally {
            release.countDown()
            work.cancelAndJoin()
        }
    }

    @Test
    fun swiftMetadataLimitsCountGraphemesAndUtf8AndRequireExplicitAudience() {
        val valid =
            YouTubeUploadMetadata(
                "👨‍👩‍👧‍👦".repeat(100),
                "あ".repeat(1666),
                madeForKids = false,
                communityGuidelinesAccepted = true,
            )
        assertNull(valid.validationMessage())
        assertNotNull(valid.copy(title = valid.title + "x").validationMessage())
        assertNotNull(valid.copy(description = "あ".repeat(1667)).validationMessage())
        assertNotNull(valid.copy(madeForKids = null).validationMessage())
        assertNotNull(valid.copy(communityGuidelinesAccepted = false).validationMessage())
        assertNotNull(valid.copy(title = "<title>").validationMessage())
        assertNotNull(valid.copy(description = "<description>").validationMessage())
        val json = ObjectMapper().readTree(valid.json())
        assertEquals("unlisted", json["status"]["privacyStatus"].asText())
        assertFalse(json["status"]["selfDeclaredMadeForKids"].asBoolean())
    }

    @Test
    fun sessionCannotRedirectBearerCredentialsToOtherOrigins() {
        for (url in
            listOf(
                "http://www.googleapis.com/upload/youtube/v3/videos?upload_id=x",
                "https://www.googleapis.com.evil.test/upload/youtube/v3/videos?upload_id=x",
                "https://user@www.googleapis.com/upload/youtube/v3/videos?upload_id=x",
                "https://www.googleapis.com:444/upload/youtube/v3/videos?upload_id=x",
                "https://www.googleapis.com/youtube/v3/videos?upload_id=x",
                "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=x#fragment",
                "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=x&upload_id=y",
                "https://www.googleapis.com/upload/youtube/v3/videos",
            )) assertThrows(IllegalArgumentException::class.java) {
            YouTubeUploadSession.parse(url)
        }
        assertEquals("YouTubeUploadSession(redacted)", session.toString())
    }

    @Test
    fun createSessionSendsActualPrivacyAudienceAndLength() = runBlocking {
        val metadata =
            YouTubeUploadMetadata(
                " Video ",
                "description",
                YouTubePrivacy.PRIVATE,
                true,
                true,
                true,
            )
        val api = transport { request ->
            assertEquals("POST", request.method)
            assertEquals("Bearer test-token", request.header("Authorization"))
            assertEquals("123", request.header("X-Upload-Content-Length"))
            assertEquals("video/mp4", request.header("X-Upload-Content-Type"))
            val buffer = Buffer()
            request.body!!.writeTo(buffer)
            val json = ObjectMapper().readTree(buffer.readUtf8())
            assertEquals("Video", json["snippet"]["title"].asText())
            assertEquals("private", json["status"]["privacyStatus"].asText())
            assertTrue(json["status"]["selfDeclaredMadeForKids"].asBoolean())
            assertTrue(json["status"]["containsSyntheticMedia"].asBoolean())
            response(request, 200, headers = mapOf("Location" to session.url.toString()))
        }
        assertEquals(session.url, api.createSession(metadata, 123, "video/mp4", "test-token").url)
    }

    @Test
    fun lostChunkReplyIsQueriedBeforeResumingAtServersAcknowledgedOffset() = runBlocking {
        val file = files.newFile("video.mp4")
        val firstLength = YouTubeUploadTransport.CHUNK_BYTES.toInt()
        file.writeBytes(ByteArray(firstLength) { (it % 251).toByte() } + byteArrayOf(11, 22, 33))
        var step = 0
        val api = transport { request ->
            assertEquals("PUT", request.method)
            val buffer = Buffer()
            request.body!!.writeTo(buffer)
            when (step++) {
                0 -> {
                    assertEquals(
                        "bytes 0-${firstLength - 1}/${file.length()}",
                        request.header("Content-Range"),
                    )
                    assertEquals(firstLength.toLong(), buffer.size)
                    assertEquals((0 % 251).toByte(), buffer.readByte())
                    throw IOException("fixture: accepted bytes, reply lost")
                }
                1 -> {
                    assertEquals("bytes */${file.length()}", request.header("Content-Range"))
                    assertEquals(0, buffer.size)
                    response(request, 308, headers = mapOf("Range" to "bytes=0-${firstLength - 1}"))
                }
                2 -> {
                    assertEquals(
                        "bytes $firstLength-${file.length() - 1}/${file.length()}",
                        request.header("Content-Range"),
                    )
                    assertArrayEquals(byteArrayOf(11, 22, 33), buffer.readByteArray())
                    response(request, 201, "{\"id\":\"M7lc1UVf-VE\"}")
                }
                else -> error("Unexpected retry or duplicate request")
            }
        }
        try {
            api.uploadChunk(session, file, file.length(), "video/mp4", 0, "test-token")
            fail("Reply should be lost")
        } catch (_: IOException) {}
        assertEquals(1, step)
        val status =
            api.status(session, file.length(), "test-token") as YouTubeUploadStatus.Incomplete
        assertEquals(firstLength.toLong(), status.acknowledgedBytes)
        val complete =
            api.uploadChunk(
                session,
                file,
                file.length(),
                "video/mp4",
                status.acknowledgedBytes,
                "test-token",
            ) as YouTubeUploadStatus.Complete
        assertEquals("https://www.youtube.com/watch?v=M7lc1UVf-VE", complete.watchUrl)
        assertEquals(3, step)
    }

    @Test
    fun emptyStatusRangeMeansZeroAndCompletedStatusReturnsOriginalVideo() = runBlocking {
        assertEquals(
            YouTubeUploadStatus.Incomplete(0, 12),
            transport { response(it, 308, headers = mapOf("Retry-After" to "12")) }
                .status(session, 10, "test-token"),
        )
        assertEquals(
            YouTubeUploadStatus.Complete("M7lc1UVf-VE"),
            transport { response(it, 200, "{\"id\":\"M7lc1UVf-VE\"}") }
                .status(session, 10, "test-token"),
        )
    }

    @Test
    fun invalidAcknowledgementIsRejectedRatherThanSkippingVideoBytes() = runBlocking {
        for (range in
            listOf(
                "bytes=1-3",
                "bytes=0-10",
                "bytes=0--1",
                "bytes=0-9223372036854775807",
                "garbage",
            )) {
            try {
                transport { response(it, 308, headers = mapOf("Range" to range)) }
                    .status(session, 10, "test-token")
                fail(range)
            } catch (_: IllegalArgumentException) {}
        }
    }

    @Test
    fun authExpiredSessionRetryAndPermanentFailuresRemainDistinct() = runBlocking {
        for ((code, status) in
            mapOf(
                401 to YouTubeUploadStatus.AuthorizationRequired,
                404 to YouTubeUploadStatus.SessionExpired,
                410 to YouTubeUploadStatus.SessionExpired,
                429 to YouTubeUploadStatus.Retry(2),
                503 to YouTubeUploadStatus.Retry(2),
                403 to YouTubeUploadStatus.Failed(403),
            )) assertEquals(
            status,
            transport { response(it, code, headers = mapOf("Retry-After" to "2")) }
                .status(session, 10, "test-token"),
        )
    }
}
