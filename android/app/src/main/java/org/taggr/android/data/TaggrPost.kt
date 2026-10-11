package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper

data class TaggrPost(
    val id: Long,
    val author: String,
    val body: String,
    val realm: String?,
    val timestampMillis: Long,
    val children: List<Long>,
    val replyCount: Int,
    val reactionCount: Int,
    val restriction: String?,
    val authorId: Long = 0,
    val files: Map<String, Pair<Long, Int>> = emptyMap(),
    val parent: Long? = null,
    val watchers: Set<Long> = emptySet(),
    val proposalId: Long? = null,
    val poll: TaggrPoll? = null,
    val pollUnavailable: Boolean = false,
    val pollTimestampMillis: Long = timestampMillis,
    val reactions: Map<Int, List<Long>> = emptyMap(),
    internal val authorBadges: List<UserBadge> = emptyList(),
    val hiddenFor: Set<Long> = emptySet(),
    val repostId: Long? = null,
    val reposts: Set<Long> = emptySet(),
    val storedBody: String = body,
    val historyPatches: List<String>? = emptyList(),
    val deleted: Boolean = false,
    val viewerBlocked: Boolean = false,
    val tipCount: Int = 0,
    val deletionHashes: List<String> = emptyList(),
) {
    fun canReact(viewerId: Long?): Boolean =
        !viewerBlocked &&
            (viewerId == null || (viewerId != authorId && reactions.values.none { viewerId in it }))

    fun deletionVersions(): List<String> {
        require(!deleted) { "This post has already been deleted." }
        val patches = historyPatches ?: error("The post edit history could not be decoded.")
        var text = storedBody
        val versions = mutableListOf(text)
        patches.asReversed().forEach {
            text = EditPatch.apply(it, text)
            versions.add(text)
        }
        return versions.asReversed()
    }

    fun hiddenForViewer(viewerId: Long?): Boolean = viewerId != null && viewerId in hiddenFor

    val timelineBody: String
        get() = body.substringBefore("\n\n\n\n")

    companion object {
        fun decodeEnvelopes(bytes: ByteArray): List<TaggrPost> {
            val root = ObjectMapper().readTree(bytes)
            require(root.isArray) { "TAGGR returned an invalid post list." }
            return root.map { row ->
                require(row.isArray && row.size() == 2 && row[0].isObject && row[1].isObject) {
                    "TAGGR returned an invalid post."
                }
                val post = row[0]
                val meta = row[1]
                val body =
                    post["eff_body"]?.takeUnless(JsonNode::isNull)?.asText()
                        ?: post.path("body").asText()
                val children = post.path("children").map(JsonNode::asLong)
                val restriction =
                    when {
                        post.path("encrypted").asBoolean() -> "This post is encrypted."
                        meta.path("max_downvotes_reached").asBoolean() ->
                            "This post has been moderated."
                        post.path("hashes").size() > 0 -> "This post has been deleted."
                        meta.path("nsfw").asBoolean() ||
                            body.contains("#nsfw", ignoreCase = true) -> "Adult content is hidden."
                        else -> null
                    }
                val pollValue = post.path("extension").get("Poll")
                val poll = pollValue?.let { runCatching { TaggrPoll.decode(it) }.getOrNull() }
                TaggrPost(
                    storedBody = post.path("body").asText(),
                    historyPatches =
                        post.get("patches")?.let { patches ->
                            if (
                                !patches.isArray ||
                                    patches.any { !it.isArray || it.size() < 2 || !it[1].isTextual }
                            )
                                null
                            else patches.map { it[1].asText() }
                        } ?: if (post.has("patches")) null else emptyList(),
                    viewerBlocked =
                        meta.get("viewer_blocked")?.takeUnless(JsonNode::isNull)?.let {
                            require(it.isBoolean) {
                                "TAGGR returned an invalid viewer block status."
                            }
                            it.booleanValue()
                        } ?: false,
                    deleted = post.path("hashes").size() > 0,
                    deletionHashes =
                        post
                            .path("hashes")
                            .takeIf { it.isArray }
                            ?.filter { it.isTextual }
                            ?.map { it.textValue() } ?: emptyList(),
                    poll = poll,
                    reactions = ReactionGroup.decode(post.path("reactions")),
                    tipCount =
                        post
                            .path("tips")
                            .takeIf { it.isArray }
                            ?.count { row ->
                                row.isArray &&
                                    row.size() == 2 &&
                                    row.all { value ->
                                        val number =
                                            if (value.isIntegralNumber || value.isTextual)
                                                value
                                                    .asText()
                                                    .takeIf { it.matches(Regex("[0-9]+")) }
                                                    ?.toBigIntegerOrNull()
                                            else null
                                        number != null &&
                                            number.signum() >= 0 &&
                                            number.bitLength() <= 64
                                    }
                            } ?: 0,
                    authorBadges = UserBadge.decode(meta.path("author_badges")),
                    reposts =
                        post
                            .path("reposts")
                            .takeIf { it.isArray }
                            ?.mapNotNull {
                                it.takeIf { value ->
                                        value.isIntegralNumber && value.canConvertToLong()
                                    }
                                    ?.longValue()
                                    ?.takeIf { value -> value >= 0 }
                            }
                            ?.toSet() ?: emptySet(),
                    repostId =
                        post
                            .path("extension")
                            .get("Repost")
                            ?.takeIf {
                                it.isIntegralNumber && it.canConvertToLong() && it.longValue() >= 0
                            }
                            ?.longValue(),
                    hiddenFor =
                        post
                            .path("hidden_for")
                            .takeIf { it.isArray }
                            ?.mapNotNull {
                                it.takeIf { value ->
                                        value.isIntegralNumber && value.canConvertToLong()
                                    }
                                    ?.longValue()
                                    ?.takeIf { value -> value >= 0 }
                            }
                            ?.toSet() ?: emptySet(),
                    pollTimestampMillis =
                        (post
                                .path("patches")
                                .mapNotNull { row ->
                                    row.get(0)
                                        ?.takeIf {
                                            it.isIntegralNumber &&
                                                it.bigIntegerValue().signum() >= 0 &&
                                                it.bigIntegerValue().bitLength() <= 64
                                        }
                                        ?.bigIntegerValue()
                                }
                                .minOrNull() ?: post.path("timestamp").asText("0").toBigInteger())
                            .divide(1_000_000.toBigInteger())
                            .also { require(it.signum() >= 0 && it.bitLength() <= 63) }
                            .toLong(),
                    pollUnavailable = pollValue != null && poll == null,
                    id = post.required("id").asLong(),
                    author = meta.path("author_name").asText("User ${post.path("user").asLong()}"),
                    body = body,
                    realm = post["realm"]?.takeUnless(JsonNode::isNull)?.asText(),
                    timestampMillis =
                        post
                            .path("timestamp")
                            .asText("0")
                            .toBigInteger()
                            .divide(1_000_000.toBigInteger())
                            .toLong(),
                    children = children,
                    replyCount =
                        if (children.isEmpty()) 0 else post.path("tree_size").asInt(children.size),
                    reactionCount = post.path("reactions").sumOf { it.size() },
                    restriction = restriction,
                    authorId = post.path("user").asLong(),
                    parent = post["parent"]?.takeIf { it.isIntegralNumber }?.asLong(),
                    watchers = post.path("watchers").map { it.asLong() }.toSet(),
                    proposalId =
                        post
                            .path("extension")
                            .get("Proposal")
                            ?.takeIf {
                                it.isIntegralNumber &&
                                    it.bigIntegerValue().signum() >= 0 &&
                                    it.bigIntegerValue().bitLength() <= 32
                            }
                            ?.asLong(),
                    files =
                        post.path("files").fields().asSequence().associate { entry ->
                            entry.key to (entry.value[0].asLong() to entry.value[1].asInt())
                        },
                )
            }
        }
    }
}
