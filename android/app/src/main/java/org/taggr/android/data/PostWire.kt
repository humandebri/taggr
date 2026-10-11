package org.taggr.android.data

import org.ic4j.agent.android.*

data class PostFileRef(val id: String, val offset: Long, val length: Long)

/** Exact add_post tuple from the shared ios/TAGGR/Candid/taggr.did. */
object PostWire {
    fun deleteArguments(post: TaggrPost): ByteArray {
        require(post.id >= 0)
        return com.fasterxml.jackson.databind
            .ObjectMapper()
            .writeValueAsBytes(listOf(post.id, post.deletionVersions()))
    }

    fun decodeDeleteResult(bytes: ByteArray) {
        val reply =
            com.fasterxml.jackson.databind
                .ObjectMapper()
                .enable(
                    com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS
                )
                .readTree(bytes)
        require(reply != null && reply.isObject && reply.size() == 1) { "Invalid deletion reply" }
        reply.get("Err")?.let {
            require(it.isTextual) { "Invalid deletion reply" }
            throw PostRejectedException(it.asText())
        }
        require(reply.has("Ok") && reply.get("Ok").isNull) { "Invalid deletion reply" }
    }

    private fun files(refs: List<PostFileRef>): CandidValue {
        require(refs.map { it.id }.distinct().size == refs.size) { "Duplicate image reference" }
        refs.forEach {
            require(it.id.isNotBlank() && it.offset >= 0 && it.length > 0) {
                "Invalid image reference"
            }
        }
        val type =
            CandidType.Vector(
                CandidType.Record(
                    listOf(
                        CandidField(0, Candid.text.type),
                        CandidField(1, Candid.nat64.type),
                        CandidField(2, Candid.nat64.type),
                    )
                )
            )
        return CandidValue(
            type,
            refs.map {
                mapOf(0L to it.id, 1L to it.offset.toBigInteger(), 2L to it.length.toBigInteger())
            },
        )
    }

    fun encode(
        text: String,
        parent: Long?,
        realm: String?,
        refs: List<PostFileRef> = emptyList(),
        repostId: Long? = null,
    ): ByteArray {
        require(text.isNotBlank() || repostId != null) { "Write something before posting." }
        require(parent == null || parent >= 0)
        require(repostId == null || (repostId >= 0 && parent == null && refs.isEmpty())) {
            "A repost cannot be a reply or attach new images."
        }
        return CandidArguments(
                Candid.text.encode(text),
                files(refs),
                Candid.optional(Candid.nat64).encode(parent?.toULong()),
                Candid.optional(Candid.text).encode(realm?.trim()?.takeIf { it.isNotEmpty() }),
                Candid.optional(Candid.blob)
                    .encode(repostId?.let { "{\"Repost\":$it}".toByteArray(Charsets.UTF_8) }),
            )
            .encode()
    }

    fun encodeEdit(
        id: Long,
        text: String,
        previousText: String,
        realm: String?,
        refs: List<PostFileRef> = emptyList(),
    ): ByteArray {
        require(id >= 0 && text.isNotBlank())
        return CandidArguments(
                Candid.nat64.encode(id.toULong()),
                Candid.text.encode(text),
                files(refs),
                Candid.text.encode(EditPatch.fullReplacement(text, previousText)),
                Candid.optional(Candid.text).encode(realm?.trim()?.takeIf { it.isNotEmpty() }),
            )
            .encode()
    }

    fun decodeEditResult(bytes: ByteArray) {
        val variant =
            Candid.decode(bytes).values.single().value as? CandidVariant
                ?: error("Invalid edit reply")
        if (variant.tag == Candid.fieldID("Err"))
            throw PostRejectedException(variant.value as String)
        require(variant.tag == Candid.fieldID("Ok") && variant.value == null) {
            "Invalid edit reply"
        }
    }

    fun decodeResult(bytes: ByteArray): Long {
        val value = Candid.decode(bytes).values.single()
        val variant = value.value as? CandidVariant ?: error("Invalid post reply")
        if (variant.tag == Candid.fieldID("Err"))
            throw PostRejectedException(variant.value as String)
        require(variant.tag == Candid.fieldID("Ok")) { "Invalid post reply" }
        val id = variant.value as java.math.BigInteger
        require(id.signum() >= 0 && id.bitLength() <= 63) { "Post id is outside supported range" }
        return id.toLong()
    }
}
