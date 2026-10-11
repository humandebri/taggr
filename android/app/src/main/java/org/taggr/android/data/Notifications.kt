package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode

data class NotificationEntry(
    val id: Long,
    val read: Boolean,
    val message: String,
    val postId: Long? = null,
    val userId: Long? = null,
    val watchedEntries: List<Long> = emptyList(),
)

data class NotificationList(val entries: List<NotificationEntry>, val invalidCount: Int)

object Notifications {
    private val follower = Regex("^(@[A-Za-z][A-Za-z0-9]{1,15}) followed you \\(")

    private fun id(value: JsonNode): Long {
        require(
            value.isIntegralNumber &&
                value.bigIntegerValue().signum() >= 0 &&
                value.bigIntegerValue().bitLength() <= 63
        )
        return value.asLong()
    }

    fun decode(value: JsonNode?): NotificationList {
        if (value == null || value.isNull) return NotificationList(emptyList(), 0)
        require(value.isObject) { "Invalid notification list" }
        var invalid = 0
        val entries =
            value
                .properties()
                .mapNotNull { (key, tuple) ->
                    try {
                        val number =
                            key.toLongOrNull()?.takeIf { it >= 0 }
                                ?: error("Invalid notification ID")
                        require(
                            tuple.isArray &&
                                tuple.size() == 2 &&
                                tuple[1].isBoolean &&
                                tuple[0].isObject &&
                                tuple[0].size() == 1
                        )
                        val payload = tuple[0]
                        var post: Long? = null
                        var user: Long? = null
                        var watched = emptyList<Long>()
                        val text =
                            when {
                                payload.has("Generic") ->
                                    payload["Generic"].also { require(it.isTextual) }.asText()
                                payload.has("NewPost") -> {
                                    val row = payload["NewPost"]
                                    require(row.isArray && row.size() == 2 && row[0].isTextual)
                                    post = id(row[1])
                                    row[0].asText()
                                }
                                payload.has("WatchedPostEntries") -> {
                                    val row = payload["WatchedPostEntries"]
                                    require(row.isArray && row.size() == 2 && row[1].isArray)
                                    post = id(row[0])
                                    watched = row[1].map(::id).distinct()
                                    "${watched.size} new thread update(s) on a watched post."
                                }
                                payload.has("Conditional") -> {
                                    val row = payload["Conditional"]
                                    require(
                                        row.isArray &&
                                            row.size() == 2 &&
                                            row[0].isTextual &&
                                            row[1].isObject &&
                                            row[1].size() == 1
                                    )
                                    val predicate = row[1]
                                    when {
                                        predicate.has("Proposal") ->
                                            post = id(predicate["Proposal"])
                                        predicate.has("ReportOpen") ->
                                            post = id(predicate["ReportOpen"])
                                        predicate.has("UserReportOpen") ->
                                            user = id(predicate["UserReportOpen"])
                                    }
                                    row[0].asText()
                                }
                                else -> "Notification unavailable"
                            }
                        val safe =
                            follower.find(text)?.let { "${it.groupValues[1]} followed you." }
                                ?: if (text.contains("#nsfw", true))
                                    "This notification contains restricted content."
                                else text
                        NotificationEntry(number, tuple[1].asBoolean(), safe, post, user, watched)
                    } catch (_: Exception) {
                        invalid++
                        null
                    }
                }
                .sortedByDescending { it.id }
        return NotificationList(entries, invalid)
    }
}
