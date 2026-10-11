package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ObjectNode
import java.math.BigInteger

private val realmMutableFields =
    listOf(
        "description",
        "label_color",
        "logo",
        "cleanup_penalty",
        "max_downvotes",
        "adult_content",
        "comments_filtering",
        "controllers",
        "whitelist",
        "filter",
        "theme",
        "last_setting_update",
    )

data class RealmEditContext(
    val owner: String,
    val network: String,
    val userId: Long,
    val name: String,
    val baseline: JsonNode,
    val maxPenalty: ULong,
    val maxLogoBytes: Int,
) {
    init {
        require(
            owner.isNotBlank() &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                userId >= 0 &&
                name.isNotBlank()
        )
        require(maxLogoBytes in 1..65536)
        RealmSettings.validateMetadata(baseline)
        require(
            baseline["controllers"].any { it.bigIntegerValue() == BigInteger.valueOf(userId) }
        ) {
            "Only a Realm controller can manage these settings."
        }
    }

    fun validate(current: JsonNode, user: JsonNode, livePenalty: ULong, liveLogo: Int) {
        RealmSettings.validateMetadata(current)
        require(
            user.path("id").asLong(-1) == userId &&
                current["controllers"].any { it.bigIntegerValue() == BigInteger.valueOf(userId) }
        ) {
            "Realm management permission changed. Reload the Realm."
        }
        require(maxPenalty == livePenalty && maxLogoBytes == liveLogo) {
            "Realm limits changed. Reload the editor."
        }
        require(realmMutableFields.all { baseline[it] == current[it] }) {
            "Another controller changed the Realm settings. Your draft was kept. Reload the editor before saving."
        }
    }
}

data class RealmSettingsDraft(
    val description: String,
    val labelColor: String,
    val cleanupPenalty: String,
    val maxDownvotes: String,
    val adultContent: Boolean,
    val commentsFiltering: Boolean,
    val logo: String? = null,
) {
    fun payload(current: JsonNode, maxPenalty: ULong, maxLogoBytes: Int): ObjectNode {
        RealmSettings.validateMetadata(current)
        val about = description.trim()
        require(about.isNotEmpty() && about.toByteArray().size <= 2000) {
            "Realm description must contain 1–2,000 UTF-8 bytes."
        }
        require(labelColor.matches(Regex("#[0-9A-Fa-f]{6}"))) {
            "Label color must use #RRGGBB format."
        }
        fun number(text: String, field: String): ULong {
            require(text.matches(Regex("[0-9]+"))) { "$field must be a non-negative integer." }
            return text.toULongOrNull() ?: error("$field is too large.")
        }
        val penalty = number(cleanupPenalty, "Cleanup penalty")
        val downvotes = number(maxDownvotes, "Maximum downvotes")
        require(penalty <= maxPenalty && penalty <= Long.MAX_VALUE.toULong()) {
            "Cleanup penalty cannot exceed $maxPenalty credits."
        }
        require(downvotes <= UInt.MAX_VALUE.toULong()) {
            "Maximum downvotes exceeds the supported limit."
        }
        logo?.let {
            require(it.toByteArray().size <= maxLogoBytes) { "The logo exceeds the Realm limit." }
            require(java.util.Base64.getDecoder().decode(it).isNotEmpty()) { "Invalid Realm logo." }
        }
        return current.deepCopy<ObjectNode>().apply {
            put("description", about)
            put("label_color", labelColor.uppercase(java.util.Locale.ROOT))
            put("cleanup_penalty", penalty.toLong())
            put("max_downvotes", downvotes.toLong())
            put("adult_content", adultContent)
            put("comments_filtering", commentsFiltering)
            if (logo != null) put("logo", logo)
        }
    }

    companion object {
        fun from(current: JsonNode) =
            RealmSettingsDraft(
                current["description"].asText(),
                current["label_color"].asText(),
                current["cleanup_penalty"].asText(),
                current["max_downvotes"].asText(),
                current["adult_content"].asBoolean(),
                current["comments_filtering"].asBoolean(),
            )
    }
}

object RealmSettings {
    private val mapper = ObjectMapper()

    fun validateMetadata(value: JsonNode, requireControllers: Boolean = true) {
        require(value.isObject)
        for (key in listOf("description", "label_color", "logo", "theme")) require(
            value.path(key).isTextual
        )
        for (key in
            listOf(
                "last_setting_update",
                "last_update",
                "max_downvotes",
                "num_members",
                "num_posts",
                "created",
            )) {
            val node = value.path(key)
            require(
                node.isIntegralNumber &&
                    node.bigIntegerValue().signum() >= 0 &&
                    node.bigIntegerValue().bitLength() <= 64
            ) {
                "Realm settings are incomplete: $key."
            }
        }
        require(
            value.path("cleanup_penalty").isIntegralNumber &&
                value["cleanup_penalty"].canConvertToLong() &&
                value.path("revenue").isIntegralNumber &&
                value["revenue"].canConvertToLong() &&
                value["max_downvotes"].bigIntegerValue().bitLength() <= 32
        )
        for (key in listOf("controllers", "whitelist", "posts")) {
            val entries = value.path(key)
            require(
                entries.isArray &&
                    entries.size() <= 1000 &&
                    entries.all {
                        it.isIntegralNumber &&
                            it.bigIntegerValue().signum() >= 0 &&
                            it.bigIntegerValue().bitLength() <= 64
                    }
            )
        }
        require(
            (!requireControllers || value["controllers"].size() > 0) &&
                value["whitelist"].size() <= 100
        )
        for (key in listOf("adult_content", "comments_filtering")) require(
            value.path(key).isBoolean
        )
        val filter = value.path("filter")
        require(filter.isObject && filter.path("safe").isBoolean)
        for (key in listOf("age_days", "balance", "num_followers")) {
            val node = filter.path(key)
            require(
                node.isIntegralNumber &&
                    node.bigIntegerValue().signum() >= 0 &&
                    node.bigIntegerValue().bitLength() <= 64
            )
        }
    }

    fun validArguments(bytes: ByteArray): Boolean =
        try {
            require(bytes.size <= 65536)
            val args = mapper.readTree(bytes)
            require(
                args.isArray &&
                    args.size() == 2 &&
                    args[0].isTextual &&
                    args[0].asText().isNotBlank() &&
                    args[0].asText().toByteArray().size <= 128
            )
            validateMetadata(args[1])
            require(
                args[1]["cleanup_penalty"].bigIntegerValue().signum() >= 0 &&
                    args[1]["description"].asText().toByteArray().size <= 2000 &&
                    args[1]["label_color"].asText().matches(Regex("#[0-9A-Fa-f]{6}")) &&
                    args[1]["logo"].asText().toByteArray().size <= 65536 &&
                    args[1]["theme"].asText().toByteArray().size <= 400
            )
            true
        } catch (_: Exception) {
            false
        }
}
