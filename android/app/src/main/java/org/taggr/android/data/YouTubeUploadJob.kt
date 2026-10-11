package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.util.UUID

internal data class YouTubeDraftTarget(
    val owner: String,
    val network: String,
    val canister: String,
    val channelId: String,
    val draftSlot: String,
) {
    init {
        require(
            listOf(owner, network, canister, channelId).all { it.isNotBlank() && it.length <= 512 }
        )
        require(Regex("new|reply/[0-9]+|edit/[0-9]+|repost/[0-9]+").matches(draftSlot))
    }
}

internal enum class YouTubeJobPhase {
    PREPARING,
    CHECKING,
    UPLOADING,
    AUTHORIZATION_REQUIRED,
    FAILED,
    COMPLETED,
    CANCELLED,
}

internal data class YouTubeUploadJob(
    val id: String,
    val target: YouTubeDraftTarget,
    val byteCount: Long,
    val sourceSha256: String,
    val mimeType: String,
    val metadata: YouTubeUploadMetadata,
    val createdAtMillis: Long,
    val phase: YouTubeJobPhase = YouTubeJobPhase.PREPARING,
    val sessionUrl: String? = null,
    val acknowledgedBytes: Long = 0,
    val retryCount: Int = 0,
    val videoId: String? = null,
    val googleAccountEmail: String? = null,
) {
    init {
        require(UUID.fromString(id).toString() == id)
        require(byteCount > 0 && acknowledgedBytes in 0..byteCount && retryCount in 0..5)
        require(Regex("[a-f0-9]{64}").matches(sourceSha256))
        require(Regex("video/[A-Za-z0-9.+-]+").matches(mimeType))
        require(createdAtMillis > 0 && metadata.validationMessage() == null)
        googleAccountEmail?.let {
            require(
                it.length in 3..320 &&
                    it.count { c -> c == '@' } == 1 &&
                    it.first() != '@' &&
                    it.last() != '@' &&
                    it.none { c -> c.isWhitespace() || c.isISOControl() }
            )
        }
        sessionUrl?.let { YouTubeUploadSession.parse(it) }
        require(
            phase !in listOf(YouTubeJobPhase.CHECKING, YouTubeJobPhase.UPLOADING) ||
                sessionUrl != null
        )
        require(sessionUrl != null || acknowledgedBytes == 0L)
        require((phase == YouTubeJobPhase.COMPLETED) == (videoId != null))
        if (videoId != null) {
            require(Regex("[A-Za-z0-9_-]{11}").matches(videoId) && acknowledgedBytes == byteCount)
        }
    }

    val sourceFileName
        get() = "$id.video"

    override fun toString() = "YouTubeUploadJob(id=$id, phase=$phase)"
}

internal object YouTubeUploadJobCodec {
    private val mapper = ObjectMapper()
    const val MAX_BYTES = 64 * 1024
    const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000

    fun encode(job: YouTubeUploadJob): ByteArray =
        mapper
            .writeValueAsBytes(
                mapOf(
                    "schema" to 2,
                    "id" to job.id,
                    "target" to
                        mapOf(
                            "owner" to job.target.owner,
                            "network" to job.target.network,
                            "canister" to job.target.canister,
                            "channelId" to job.target.channelId,
                            "draftSlot" to job.target.draftSlot,
                        ),
                    "byteCount" to job.byteCount,
                    "sourceSha256" to job.sourceSha256,
                    "mimeType" to job.mimeType,
                    "metadata" to
                        mapOf(
                            "title" to job.metadata.title,
                            "description" to job.metadata.description,
                            "privacyStatus" to job.metadata.privacy.name,
                            "madeForKids" to job.metadata.madeForKids,
                            "containsSyntheticMedia" to job.metadata.containsSyntheticMedia,
                            "communityGuidelinesAccepted" to
                                job.metadata.communityGuidelinesAccepted,
                        ),
                    "createdAtMillis" to job.createdAtMillis,
                    "phase" to job.phase.name,
                    "sessionUrl" to job.sessionUrl,
                    "acknowledgedBytes" to job.acknowledgedBytes,
                    "retryCount" to job.retryCount,
                    "videoId" to job.videoId,
                    "googleAccountEmail" to job.googleAccountEmail,
                )
            )
            .also { require(it.size <= MAX_BYTES) }

    fun decode(bytes: ByteArray, expected: YouTubeDraftTarget): YouTubeUploadJob {
        require(bytes.size <= MAX_BYTES)
        val row = mapper.readTree(bytes)
        fun text(node: com.fasterxml.jackson.databind.JsonNode, key: String): String {
            val value = node.required(key)
            require(value.isTextual)
            return value.asText()
        }
        fun number(key: String): Long {
            val value = row.required(key)
            require(value.isIntegralNumber && value.canConvertToLong())
            return value.asLong()
        }
        val schema = number("schema")
        require(schema in 1L..2L)
        require(schema != 1L || !row.has("googleAccountEmail"))
        val t = row.required("target")
        val target =
            YouTubeDraftTarget(
                text(t, "owner"),
                text(t, "network"),
                text(t, "canister"),
                text(t, "channelId"),
                text(t, "draftSlot"),
            )
        require(target == expected) { "Upload belongs to a different account, channel or draft." }
        val m = row.required("metadata")
        val kids = m.required("madeForKids")
        require(kids.isBoolean)
        val synthetic = m.required("containsSyntheticMedia")
        require(synthetic.isBoolean)
        val consent = m.required("communityGuidelinesAccepted")
        require(consent.isBoolean)
        fun optional(key: String): String? {
            val v = row.required(key)
            require(v.isNull || v.isTextual)
            return if (v.isNull) null else v.asText()
        }
        val retry = number("retryCount")
        require(retry in 0..5)
        return YouTubeUploadJob(
            text(row, "id"),
            target,
            number("byteCount"),
            text(row, "sourceSha256"),
            text(row, "mimeType"),
            YouTubeUploadMetadata(
                text(m, "title"),
                text(m, "description"),
                YouTubePrivacy.valueOf(text(m, "privacyStatus")),
                kids.asBoolean(),
                synthetic.asBoolean(),
                consent.asBoolean(),
            ),
            number("createdAtMillis"),
            YouTubeJobPhase.valueOf(text(row, "phase")),
            optional("sessionUrl"),
            number("acknowledgedBytes"),
            retry.toInt(),
            optional("videoId"),
            if (schema == 2L) optional("googleAccountEmail") else null,
        )
    }
}
