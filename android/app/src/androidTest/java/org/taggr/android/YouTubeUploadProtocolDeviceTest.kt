package org.taggr.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

/** Android ICU and file/HTTP primitives; scripted server responses, no real upload. */
@RunWith(AndroidJUnit4::class)
class YouTubeUploadProtocolDeviceTest {
    @Test
    fun androidUnicodeMetadataAndResumedFileTail() = runBlocking {
        val metadata =
            YouTubeUploadMetadata(
                "👨‍👩‍👧‍👦".repeat(100),
                madeForKids = false,
                communityGuidelinesAccepted = true,
            )
        assertNull(metadata.validationMessage())
        assertNotNull(metadata.copy(title = metadata.title + "x").validationMessage())
        assertNotNull(metadata.copy(description = "あ".repeat(1667)).validationMessage())
        val file =
            File.createTempFile(
                "youtube-protocol-",
                ".mp4",
                InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
            )
        try {
            file.writeBytes(byteArrayOf(1, 2, 3, 4, 5))
            val session =
                YouTubeUploadSession.parse(
                    "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"
                )
            var step = 0
            val client =
                OkHttpClient.Builder()
                    .addInterceptor { chain ->
                        val request = chain.request()
                        val content = Buffer()
                        request.body!!.writeTo(content)
                        val response =
                            Response.Builder()
                                .request(request)
                                .protocol(Protocol.HTTP_1_1)
                                .message("scripted fixture")
                        when (step++) {
                            0 -> {
                                assertEquals("bytes */5", request.header("Content-Range"))
                                assertEquals(0L, content.size)
                                response
                                    .code(308)
                                    .header("Range", "bytes=0-1")
                                    .body("".toResponseBody())
                            }
                            1 -> {
                                assertEquals("bytes 2-4/5", request.header("Content-Range"))
                                assertArrayEquals(byteArrayOf(3, 4, 5), content.readByteArray())
                                response.code(201).body("{\"id\":\"M7lc1UVf-VE\"}".toResponseBody())
                            }
                            else -> error("Unexpected duplicate request")
                        }.build()
                    }
                    .build()
            val api = YouTubeUploadTransport(client)
            val status = api.status(session, 5, "test-token") as YouTubeUploadStatus.Incomplete
            assertEquals(2L, status.acknowledgedBytes)
            assertEquals(
                YouTubeUploadStatus.Complete("M7lc1UVf-VE"),
                api.uploadChunk(
                    session,
                    file,
                    5,
                    "video/mp4",
                    status.acknowledgedBytes,
                    "test-token",
                ),
            )
            assertEquals(2, step)
        } finally {
            assertTrue(file.delete())
        }
    }
}
