package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class PostDeletionTest {
    private fun post() = TaggrPost(42, "Alice", "Display text", null, 0, emptyList(), 0, 0, null)

    @Test
    fun backendEnvelopeRetainsRawBodyAndRejectsMalformedHistory() {
        val mapper = ObjectMapper()
        val raw = "終😀"
        val patch = EditPatch.fullReplacement(raw, "前🍊")
        val envelope =
            mapper.writeValueAsBytes(
                listOf(
                    listOf(
                        mapOf(
                            "id" to 42,
                            "body" to raw,
                            "eff_body" to "Display",
                            "patches" to listOf(listOf(100, patch)),
                        ),
                        mapOf("author_name" to "Alice"),
                    )
                )
            )
        val row = TaggrPost.decodeEnvelopes(envelope).single()
        assertEquals("Display", row.body)
        assertEquals(listOf("前🍊", raw), row.deletionVersions())
        val broken = mapper.readTree(envelope)
        (broken[0][0] as com.fasterxml.jackson.databind.node.ObjectNode).putNull("patches")
        assertTrue(
            runCatching {
                    TaggrPost.decodeEnvelopes(mapper.writeValueAsBytes(broken))
                        .single()
                        .deletionVersions()
                }
                .isFailure
        )
        assertTrue(runCatching { EditPatch.apply("@@ -1,0 +1,0 @@\n+x\n", "😀") }.isFailure)
        assertTrue(runCatching { EditPatch.apply("@@ -1 +1 @@\n-%４１\n+x\n", "A") }.isFailure)
    }

    @Test
    fun rawBodyAndReversePatchesProduceChronologicalUnicodeVersions() {
        val old = "始😀+\nold"
        val middle = "中🍊+middle"
        val current = "終😀+new"
        val row =
            post()
                .copy(
                    storedBody = current,
                    historyPatches =
                        listOf(
                            EditPatch.fullReplacement(middle, old),
                            EditPatch.fullReplacement(current, middle),
                        ),
                )
        assertEquals(listOf(old, middle, current), row.deletionVersions())
        val args = ObjectMapper().readTree(PostWire.deleteArguments(row))
        assertEquals(42L, args[0].longValue())
        assertEquals(listOf(old, middle, current), args[1].map { it.asText() })
    }

    @Test
    fun multipleHunksUseDestinationOffsetsAfterEarlierInsertions() {
        val patch = "@@ -2,1 +2,2 @@\n-b\n+BB\n@@ -4,1 +5,1 @@\n-d\n+D\n"
        assertEquals("aBBcDe", EditPatch.apply(patch, "abcde"))
        assertEquals("", EditPatch.apply(EditPatch.fullReplacement("😀", ""), "😀"))
        assertEquals("a+b", EditPatch.apply("@@ -0,0 +1,3 @@\n+a+b\n", ""))
    }

    @Test
    fun malformedOrMismatchedHistoryDoesNotCreateDeletionArguments() {
        for (patch in
            listOf(
                "",
                "@@ -1 +1 @@\n-%GG\n+x\n",
                "@@ -1 +1 @@\n-%FF\n+x\n",
                "@@ -1,2 +1 @@\n-a\n+x\n",
                "@@ -1 +1 @@\n-z\n+x\n",
                "@@ -1,0 +999999999999999999,0 @@\n+x\n",
            )) assertTrue(patch, runCatching { EditPatch.apply(patch, "a") }.isFailure)
        assertTrue(runCatching { post().copy(historyPatches = null).deletionVersions() }.isFailure)
        assertTrue(runCatching { post().copy(deleted = true).deletionVersions() }.isFailure)
    }

    @Test
    fun pendingDeletionRequiresTargetAndNoDraftSlotAndDecodesExactJsonResult() {
        PendingPost("p", "c", ByteArray(32), "delete_post", 42)
        assertTrue(runCatching { PendingPost("p", "c", ByteArray(32), "delete_post") }.isFailure)
        assertTrue(
            runCatching { PendingPost("p", "c", ByteArray(32), "delete_post", 42, "edit/42") }
                .isFailure
        )
        PostWire.decodeDeleteResult("{\"Ok\":null}".toByteArray())
        for (json in
            listOf(
                "{}",
                "{\"Ok\":42}",
                "{\"Ok\":null} {}",
                "{\"Err\":\"not authorized\"}",
            )) assertTrue(
            json,
            runCatching { PostWire.decodeDeleteResult(json.toByteArray()) }.isFailure,
        )
    }
}
