package org.taggr.android.data

import java.math.BigInteger
import org.ic4j.agent.android.*
import org.junit.Assert.*
import org.junit.Test

class PostWireTest {
    @Test
    fun repostUsesSwiftExtensionWithEmptyCommentAndSeparateRecoverySlot() {
        val args =
            Candid.decode(PostWire.encode("", null, " TECH ", repostId = Long.MAX_VALUE)).values
        assertEquals("", args[0].value)
        assertEquals(CandidOption.None, args[2].value)
        assertEquals(CandidOption.Some("TECH"), args[3].value)
        val blob = (args[4].value as CandidOption.Some).value as ByteArray
        assertEquals("{\"Repost\":9223372036854775807}", blob.toString(Charsets.UTF_8))
        PendingPost("principal", "canister", ByteArray(32), draftSlot = "repost/42")
        assertTrue(runCatching { PostWire.encode("", null, null) }.isFailure)
        assertTrue(runCatching { PostWire.encode("quote", 2, null, repostId = 42) }.isFailure)
        assertTrue(runCatching { PostWire.encode("quote", null, null, repostId = -1) }.isFailure)
        assertTrue(
            runCatching { PostWire.encode("quote", null, null, listOf(PostFileRef("x", 0, 1)), 42) }
                .isFailure
        )
    }

    @Test
    fun editsDecodeUnitSuccessAndTextRejection() {
        val type =
            CandidType.Variant(
                listOf(
                    CandidField("Ok", CandidType.Primitive.NULL),
                    CandidField("Err", Candid.text.type),
                )
            )
        fun reply(tag: String, payload: Any?) =
            CandidArguments(CandidValue(type, CandidVariant(Candid.fieldID(tag), payload))).encode()
        PostWire.decodeEditResult(reply("Ok", null))
        try {
            PostWire.decodeEditResult(reply("Err", "unauthorized"))
            fail("Expected a backend rejection")
        } catch (error: PostRejectedException) {
            assertEquals("unauthorized", error.message)
        }
    }

    @Test
    fun recoveryMetadataRejectsAmbiguousEditsAndInvalidDraftSlots() {
        PendingPost("principal", "canister", ByteArray(32), "edit_post", 42, "edit/42")
        for (construct in
            listOf<() -> PendingPost>(
                { PendingPost("principal", "canister", ByteArray(32), "edit_post") },
                { PendingPost("principal", "canister", ByteArray(32), draftSlot = "../../other") },
                { PendingPost("principal", "canister", ByteArray(31)) },
            )) {
            try {
                construct()
                fail("Expected invalid recovery metadata to be rejected")
            } catch (_: IllegalArgumentException) {}
        }
    }

    @Test
    fun attachmentAndEditTuplesMatchSharedCandidAndSwiftHistoryPatch() {
        val refs = listOf(PostFileRef("ab12cd34", 9_000_000_001, 1234))
        val added =
            Candid.decode(PostWire.encode("![image](/blob/ab12cd34)", null, null, refs)).values
        val reference = (added[1].value as List<*>).single() as Map<*, *>
        assertEquals("ab12cd34", reference[0L])
        assertEquals(BigInteger.valueOf(9_000_000_001), reference[1L])
        assertEquals(BigInteger.valueOf(1234), reference[2L])
        val edited = Candid.decode(PostWire.encodeEdit(42, "new 😀\n%", "old", null, refs)).values
        assertEquals(BigInteger.valueOf(42), edited[0].value)
        assertEquals("@@ -1,8 +1,3 @@\n-new %F0%9F%98%80%0A%25\n+old\n", edited[3].value)
        assertEquals(CandidOption.None, edited[4].value)
    }

    @Test
    fun matchesSwiftAddPostCandidTuple() {
        val args = Candid.decode(PostWire.encode("Hello", 42, "TECH")).values
        assertEquals(5, args.size)
        assertEquals("Hello", args[0].value)
        assertEquals(
            CandidType.Vector(
                CandidType.Record(
                    listOf(
                        CandidField(0, Candid.text.type),
                        CandidField(1, Candid.nat64.type),
                        CandidField(2, Candid.nat64.type),
                    )
                )
            ),
            args[1].type,
        )
        assertEquals(emptyList<Any>(), args[1].value)
        assertEquals(CandidOption.Some(BigInteger.valueOf(42)), args[2].value)
        assertEquals(CandidOption.Some("TECH"), args[3].value)
        assertEquals(CandidOption.None, args[4].value)
    }

    @Test
    fun replySupportsLargePostIdsAndRejectsBackendErrors() {
        val type =
            CandidType.Variant(
                listOf(CandidField("Ok", Candid.nat64.type), CandidField("Err", Candid.text.type))
            )
        val id = 9_000_000_001L
        assertEquals(
            id,
            PostWire.decodeResult(
                CandidArguments(
                        CandidValue(
                            type,
                            CandidVariant(Candid.fieldID("Ok"), BigInteger.valueOf(id)),
                        )
                    )
                    .encode()
            ),
        )
        try {
            PostWire.decodeResult(
                CandidArguments(
                        CandidValue(
                            type,
                            CandidVariant(Candid.fieldID("Err"), "Not enough credits"),
                        )
                    )
                    .encode()
            )
            fail("Expected rejection")
        } catch (error: PostRejectedException) {
            assertEquals("Not enough credits", error.message)
        }
    }
}
