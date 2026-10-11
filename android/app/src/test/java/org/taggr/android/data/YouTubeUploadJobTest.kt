package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ObjectNode
import org.junit.Assert.*
import org.junit.Test

class YouTubeUploadJobTest {
    @Test
    fun schemaTwoRetainsAccountAndLegacySchemaRequiresForegroundBinding() {
        val bound = job.copy(googleAccountEmail = "test@example.test")
        assertEquals(
            bound,
            YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(bound), target),
        )
        assertFalse(bound.toString().contains("test@example.test"))
        val mapper = ObjectMapper()
        val row = mapper.readTree(YouTubeUploadJobCodec.encode(job)) as ObjectNode
        row.put("schema", 1)
        row.remove("googleAccountEmail")
        assertEquals(job, YouTubeUploadJobCodec.decode(mapper.writeValueAsBytes(row), target))
        row.put("googleAccountEmail", "test@example.test")
        assertThrows(IllegalArgumentException::class.java) {
            YouTubeUploadJobCodec.decode(mapper.writeValueAsBytes(row), target)
        }
        for (email in
            listOf(
                "not-email",
                "@example.test",
                "test@",
                "test @example.test",
                "test\n@example.test",
            )) assertThrows(IllegalArgumentException::class.java) {
            job.copy(googleAccountEmail = email)
        }
    }

    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "reply/42")
    private val job =
        YouTubeUploadJob(
            "d2fce75f-04dd-4d19-bc89-4b7d30a0a5e4",
            target,
            10,
            "a".repeat(64),
            "video/mp4",
            YouTubeUploadMetadata(
                " Title ",
                madeForKids = false,
                communityGuidelinesAccepted = true,
            ),
            1700000000000,
        )

    @Test
    fun roundTripPreservesDraftMetadataAndPendingStatus() {
        val pending =
            job.copy(
                phase = YouTubeJobPhase.CHECKING,
                sessionUrl =
                    "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=private-session",
                acknowledgedBytes = 7,
            )
        assertEquals(
            pending,
            YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(pending), target),
        )
        assertFalse(pending.toString().contains("private-session"))
        assertFalse(pending.toString().contains("Title"))
    }

    @Test
    fun ownerNetworkCanisterChannelAndDraftMustAllMatch() {
        for (changed in
            listOf(
                target.copy(owner = "other"),
                target.copy(network = "other"),
                target.copy(canister = "other"),
                target.copy(channelId = "other"),
                target.copy(draftSlot = "new"),
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(job), changed)
            }
        }
    }

    @Test
    fun invalidPhaseProgressAndPathCannotBecomeSavedJob() {
        assertThrows(IllegalArgumentException::class.java) { job.copy(id = "../other") }
        assertThrows(IllegalArgumentException::class.java) { job.copy(acknowledgedBytes = -1) }
        assertThrows(IllegalArgumentException::class.java) { job.copy(acknowledgedBytes = 11) }
        assertThrows(IllegalArgumentException::class.java) { job.copy(acknowledgedBytes = 1) }
        assertThrows(IllegalArgumentException::class.java) {
            job.copy(phase = YouTubeJobPhase.UPLOADING)
        }
        assertThrows(IllegalArgumentException::class.java) {
            job.copy(phase = YouTubeJobPhase.COMPLETED)
        }
    }

    @Test
    fun unknownSchemaAndFractionalProgressAreRejected() {
        val mapper = ObjectMapper()
        for (mutate in
            listOf<(ObjectNode) -> Unit>(
                { it.put("schema", 3) },
                { it.put("acknowledgedBytes", 0.5) },
                { it.put("byteCount", "10") },
            )) {
            val row = mapper.readTree(YouTubeUploadJobCodec.encode(job)) as ObjectNode
            mutate(row)
            assertThrows(IllegalArgumentException::class.java) {
                YouTubeUploadJobCodec.decode(mapper.writeValueAsBytes(row), target)
            }
        }
    }

    @Test
    fun completedReceiptRequiresFullAcknowledgementAndValidVideo() {
        val done =
            job.copy(
                phase = YouTubeJobPhase.COMPLETED,
                sessionUrl =
                    "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=session",
                acknowledgedBytes = 10,
                videoId = "M7lc1UVf-VE",
            )
        assertEquals(done, YouTubeUploadJobCodec.decode(YouTubeUploadJobCodec.encode(done), target))
        assertThrows(IllegalArgumentException::class.java) { done.copy(acknowledgedBytes = 9) }
        assertThrows(IllegalArgumentException::class.java) { done.copy(videoId = "../bad") }
    }
}
