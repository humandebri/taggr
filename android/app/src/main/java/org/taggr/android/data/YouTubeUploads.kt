package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink

internal enum class YouTubePrivacy {
    UNLISTED,
    PUBLIC,
    PRIVATE,
}

internal data class YouTubeChannel(val id: String, val title: String)

internal class YouTubeUploadHttpException(val status: Int, val retryAfterSeconds: Long?) :
    Exception("YouTube could not start the upload (HTTP $status).")

internal data class YouTubeUploadMetadata(
    val title: String,
    val description: String = "",
    val privacy: YouTubePrivacy = YouTubePrivacy.UNLISTED,
    val madeForKids: Boolean? = null,
    val containsSyntheticMedia: Boolean = false,
    val communityGuidelinesAccepted: Boolean = false,
) {
    fun validationMessage(): String? =
        when {
            title.isBlank() -> "Enter a YouTube title."
            Regex("\\X").findAll(title).take(101).count() > 100 ->
                "The YouTube title must be 100 characters or fewer."
            '<' in title || '>' in title -> "The YouTube title cannot contain < or >."
            description.toByteArray(Charsets.UTF_8).size > 5_000 ->
                "The YouTube description must be 5,000 bytes or fewer."
            '<' in description || '>' in description ->
                "The YouTube description cannot contain < or >."
            madeForKids == null -> "Choose whether the video is made for kids."
            !communityGuidelinesAccepted -> "Confirm that the video follows YouTube's rules."
            else -> null
        }

    fun json(): ByteArray {
        require(validationMessage() == null) { validationMessage()!! }
        return ObjectMapper()
            .writeValueAsBytes(
                mapOf(
                    "snippet" to mapOf("title" to title.trim(), "description" to description),
                    "status" to
                        mapOf(
                            "privacyStatus" to privacy.name.lowercase(java.util.Locale.ROOT),
                            "embeddable" to true,
                            "selfDeclaredMadeForKids" to madeForKids,
                            "containsSyntheticMedia" to containsSyntheticMedia,
                        ),
                )
            )
    }
}

/** A session URL authorizes uploading. Never show it in messages or logs. */
internal class YouTubeUploadSession private constructor(internal val url: HttpUrl) {
    override fun toString() = "YouTubeUploadSession(redacted)"

    companion object {
        fun parse(value: String): YouTubeUploadSession {
            val url = value.toHttpUrl()
            require(
                url.scheme == "https" &&
                    url.host == "www.googleapis.com" &&
                    url.port == 443 &&
                    url.username.isEmpty() &&
                    url.password.isEmpty() &&
                    url.fragment == null &&
                    url.encodedPath == "/upload/youtube/v3/videos" &&
                    url.queryParameterValues("upload_id").size == 1 &&
                    !url.queryParameter("upload_id").isNullOrBlank()
            ) {
                "YouTube returned an invalid upload session."
            }
            return YouTubeUploadSession(url)
        }
    }
}

internal sealed interface YouTubeUploadStatus {
    data class Incomplete(val acknowledgedBytes: Long, val retryAfterSeconds: Long?) :
        YouTubeUploadStatus

    data class Complete(val videoId: String) : YouTubeUploadStatus {
        val watchUrl
            get() = "https://www.youtube.com/watch?v=$videoId"
    }

    data object AuthorizationRequired : YouTubeUploadStatus

    data object SessionExpired : YouTubeUploadStatus

    data class Retry(val retryAfterSeconds: Long?) : YouTubeUploadStatus

    data class Failed(val httpStatus: Int) : YouTubeUploadStatus
}

/**
 * HTTP primitives only. A persisted, owner-bound job must coordinate retries and draft insertion.
 */
internal class YouTubeUploadTransport(client: OkHttpClient = OkHttpClient()) {
    private val client =
        client
            .newBuilder()
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()

    private fun request(url: HttpUrl, token: String): Request.Builder {
        require(token.isNotBlank() && token.all { it.code in 33..126 }) {
            "Connect a YouTube account first."
        }
        return Request.Builder().url(url).header("Authorization", "Bearer $token")
    }

    suspend fun channel(token: String, expectedId: String? = null): YouTubeChannel {
        val reply =
            exchange(
                request(
                        "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true"
                            .toHttpUrl(),
                        token,
                    )
                    .get()
                    .build()
            )
        require(reply.code == 200) { "YouTube channel access failed (HTTP ${reply.code})." }
        val row =
            ObjectMapper()
                .readTree(reply.bytes)
                ?.path("items")
                ?.takeIf { it.isArray }
                ?.firstOrNull()
        require(row != null) { "This Google account does not have a YouTube channel." }
        val id = row.path("id")
        val title = row.path("snippet").path("title")
        require(
            id.isTextual && id.asText().isNotBlank() && id.asText().length <= 128 && title.isTextual
        ) {
            "YouTube returned an invalid channel."
        }
        require(expectedId == null || id.asText() == expectedId) {
            "Connect the YouTube channel selected for this upload."
        }
        return YouTubeChannel(id.asText(), title.asText())
    }

    suspend fun googleAccountEmail(token: String): String {
        val reply =
            exchange(
                request("https://www.googleapis.com/oauth2/v3/userinfo".toHttpUrl(), token)
                    .get()
                    .build()
            )
        require(reply.code == 200) { "Google account access failed (HTTP ${reply.code})." }
        val row = ObjectMapper().readTree(reply.bytes)
        val email = row?.path("email")
        val verified = row?.path("email_verified")
        require(email?.isTextual == true && verified?.isBoolean == true && verified.asBoolean()) {
            "Google did not return a verified account email."
        }
        val name = email.asText()
        require(
            name.length in 3..320 &&
                name.count { it == '@' } == 1 &&
                name.none { it.isWhitespace() || it.code < 32 }
        ) {
            "Google returned an invalid account email."
        }
        return name
    }

    suspend fun createSession(
        metadata: YouTubeUploadMetadata,
        byteCount: Long,
        mimeType: String,
        token: String,
    ): YouTubeUploadSession {
        validateSource(byteCount, mimeType)
        val url =
            "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status"
                .toHttpUrl()
        val response =
            exchange(
                request(url, token)
                    .header("X-Upload-Content-Length", byteCount.toString())
                    .header("X-Upload-Content-Type", mimeType)
                    .post(
                        metadata
                            .json()
                            .toRequestBody("application/json; charset=utf-8".toMediaType())
                    )
                    .build()
            )
        if (response.code != 200)
            throw YouTubeUploadHttpException(
                response.code,
                response.retry?.toLongOrNull()?.takeIf { it in 0..86_400 },
            )
        return YouTubeUploadSession.parse(
            requireNotNull(response.location) { "YouTube returned no upload session." }
        )
    }

    suspend fun status(
        session: YouTubeUploadSession,
        byteCount: Long,
        token: String,
    ): YouTubeUploadStatus {
        require(byteCount > 0)
        return decode(
            exchange(
                request(session.url, token)
                    .header("Content-Range", "bytes */$byteCount")
                    .put(ByteArray(0).toRequestBody())
                    .build()
            ),
            byteCount,
        )
    }

    /** Reads at most 64 KiB at a time; the source is never loaded as a complete byte array. */
    suspend fun uploadChunk(
        session: YouTubeUploadSession,
        source: File,
        byteCount: Long,
        mimeType: String,
        offset: Long,
        token: String,
    ): YouTubeUploadStatus {
        validateSource(byteCount, mimeType)
        require(source.isFile && source.length() == byteCount) {
            "The selected video changed or is unavailable."
        }
        require(offset in 0 until byteCount)
        val length = minOf(CHUNK_BYTES, byteCount - offset)
        val body =
            object : RequestBody() {
                override fun contentType() = mimeType.toMediaType()

                override fun contentLength() = length

                override fun isOneShot() = true

                override fun writeTo(sink: BufferedSink) {
                    RandomAccessFile(source, "r").use { file ->
                        require(file.length() == byteCount) { "The selected video changed." }
                        file.seek(offset)
                        var remaining = length
                        val buffer = ByteArray(64 * 1024)
                        while (remaining > 0) {
                            val read =
                                file.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                            if (read < 0) throw IOException("The selected video is incomplete.")
                            sink.write(buffer, 0, read)
                            remaining -= read
                        }
                    }
                }
            }
        return decode(
            exchange(
                request(session.url, token)
                    .header("Content-Range", "bytes $offset-${offset + length - 1}/$byteCount")
                    .put(body)
                    .build()
            ),
            byteCount,
        )
    }

    private data class Reply(
        val code: Int,
        val location: String?,
        val range: String?,
        val retry: String?,
        val bytes: ByteArray,
    )

    private suspend fun exchange(request: Request): Reply =
        suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        if (continuation.isActive)
                            continuation.resumeWithException(
                                IOException(
                                    "YouTube connection interrupted. Check upload status before retrying.",
                                    e,
                                )
                            )
                    }

                    override fun onResponse(call: Call, response: Response) {
                        try {
                            val result = response.use {
                                val source = it.body?.source()
                                require(source?.request(MAX_REPLY_BYTES + 1L) != true) {
                                    "YouTube response is too large."
                                }
                                Reply(
                                    it.code,
                                    it.header("Location"),
                                    it.header("Range"),
                                    it.header("Retry-After"),
                                    source?.readByteArray() ?: ByteArray(0),
                                )
                            }
                            if (continuation.isActive) continuation.resume(result)
                        } catch (e: Exception) {
                            if (continuation.isActive) continuation.resumeWithException(e)
                        }
                    }
                }
            )
        }

    private fun decode(reply: Reply, total: Long): YouTubeUploadStatus {
        val retry = reply.retry?.toLongOrNull()?.takeIf { it in 0..86_400 }
        return when (reply.code) {
            200,
            201 -> {
                val id = ObjectMapper().readTree(reply.bytes)?.path("id")?.asText().orEmpty()
                require(Regex("[A-Za-z0-9_-]{11}").matches(id)) {
                    "YouTube returned an invalid video ID."
                }
                YouTubeUploadStatus.Complete(id)
            }
            308 -> {
                val acknowledged =
                    if (reply.range == null) 0L
                    else {
                        val match = Regex("bytes=0-([0-9]+)").matchEntire(reply.range)
                        val last = match?.groupValues?.get(1)?.toLongOrNull()
                        require(last != null && last in 0 until total) {
                            "YouTube returned an invalid upload range."
                        }
                        last + 1
                    }
                YouTubeUploadStatus.Incomplete(acknowledged, retry)
            }
            401 -> YouTubeUploadStatus.AuthorizationRequired
            404,
            410 -> YouTubeUploadStatus.SessionExpired
            429,
            in 500..599 -> YouTubeUploadStatus.Retry(retry)
            else -> YouTubeUploadStatus.Failed(reply.code)
        }
    }

    private fun validateSource(byteCount: Long, mimeType: String) {
        require(byteCount > 0 && Regex("video/[A-Za-z0-9.+-]+").matches(mimeType)) {
            "Select a supported video."
        }
    }

    companion object {
        const val CHUNK_BYTES = 4L * 1024 * 1024
        private const val MAX_REPLY_BYTES = 1024 * 1024
    }
}
