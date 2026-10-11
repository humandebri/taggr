package org.taggr.android.data

import com.fasterxml.jackson.databind.DeserializationFeature
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import java.util.Locale

private val creationMapper = ObjectMapper().enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)

val realmThemeDefaults =
    linkedMapOf(
        "text" to "#e0e0c8",
        "background" to "#1c3239",
        "code" to "#ffffff",
        "clickable" to "#30d5c8",
        "accent" to "#ffc700",
    )

data class RealmCreationLimits(
    val cost: ULong,
    val maxNameBytes: Int,
    val maxPenalty: ULong,
    val defaultDownvotes: UInt,
    val reservedName: String,
) {
    init {
        require(
            cost <= Long.MAX_VALUE.toULong() &&
                maxPenalty <= Long.MAX_VALUE.toULong() &&
                maxNameBytes in 1..128 &&
                reservedName.isNotBlank()
        )
    }

    companion object {
        fun decode(config: JsonNode): RealmCreationLimits {
            val length = WithdrawQuote.unsigned(config, "max_realm_name")
            val downvotes = WithdrawQuote.unsigned(config, "default_max_downvotes")
            require(
                length in 1uL..128uL &&
                    downvotes <= UInt.MAX_VALUE.toULong() &&
                    config.path("name").isTextual
            )
            return RealmCreationLimits(
                WithdrawQuote.unsigned(config, "realm_cost"),
                length.toInt(),
                WithdrawQuote.unsigned(config, "max_realm_cleanup_penalty"),
                downvotes.toUInt(),
                config["name"].asText(),
            )
        }
    }
}

data class RealmCreationDraft(val values: Map<String, String>) {
    val name
        get() = values.getValue("name").trim().uppercase(Locale.ROOT)

    fun flag(key: String) = values.getValue(key) == "true"

    fun handles(key: String): List<String> =
        values
            .getValue(key)
            .split(',', '\n')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .also { require(it.size <= if (key == "whitelist") 100 else 1000) { "Too many $key." } }

    fun payload(
        limits: RealmCreationLimits,
        controllers: List<ULong>,
        whitelist: List<ULong>,
    ): JsonNode {
        RealmCreation.validateName(name, limits.maxNameBytes)
        require(!name.equals(limits.reservedName, ignoreCase = true)) { "Realm name is reserved." }
        require(controllers.isNotEmpty() && controllers.size <= 1000 && whitelist.size <= 100) {
            "At least one controller and at most 100 whitelist users are required."
        }
        fun number(key: String): ULong {
            val text = values.getValue(key).trim()
            require(text.matches(Regex("[0-9]+"))) { "$key must be a non-negative integer." }
            return text.toULongOrNull() ?: error("$key is too large.")
        }
        val penalty = number("penalty")
        val downvotes = number("downvotes")
        require(penalty <= limits.maxPenalty && downvotes <= UInt.MAX_VALUE.toULong()) {
            "Realm moderation limits are exceeded."
        }
        val description = values.getValue("description").trim()
        require(description.isNotEmpty() && description.toByteArray().size <= 2000) {
            "Description must contain 1–2,000 UTF-8 bytes."
        }
        val color = values.getValue("color")
        require(color.matches(Regex("#[0-9A-Fa-f]{6}"))) { "Label color must use #RRGGBB." }
        val theme =
            if (flag("ownTheme"))
                creationMapper.writeValueAsString(
                    realmThemeDefaults.keys.associateWith { key ->
                        values.getValue("theme_$key").also {
                            require(it.matches(Regex("#[0-9A-Fa-f]{6}"))) {
                                "Theme colors must use #RRGGBB."
                            }
                        }
                    }
                )
            else ""
        val zero = BigInteger.ZERO
        val result =
            creationMapper.valueToTree<JsonNode>(
                linkedMapOf(
                    "description" to description,
                    "label_color" to color.uppercase(Locale.ROOT),
                    "logo" to "",
                    "controllers" to
                        controllers.distinct().sorted().map { BigInteger(it.toString()) },
                    "whitelist" to whitelist.distinct().sorted().map { BigInteger(it.toString()) },
                    "cleanup_penalty" to penalty.toLong(),
                    "max_downvotes" to downvotes.toLong(),
                    "filter" to
                        mapOf(
                            "age_days" to BigInteger(number("age").toString()),
                            "safe" to flag("safe"),
                            "balance" to BigInteger(number("balance").toString()),
                            "num_followers" to BigInteger(number("followers").toString()),
                        ),
                    "adult_content" to flag("adult"),
                    "comments_filtering" to flag("filterComments"),
                    "theme" to theme,
                    "last_setting_update" to zero,
                    "last_update" to zero,
                    "num_members" to zero,
                    "num_posts" to zero,
                    "revenue" to zero,
                    "created" to zero,
                    "posts" to emptyList<Long>(),
                )
            )
        require(
            RealmCreation.validArguments(creationMapper.writeValueAsBytes(listOf(name, result)))
        )
        return result
    }

    companion object {
        fun defaults(userId: String, downvotes: String = "0") =
            RealmCreationDraft(
                linkedMapOf(
                    "name" to "",
                    "description" to "",
                    "color" to "#ffffff",
                    "controllers" to userId,
                    "whitelist" to "",
                    "penalty" to "10",
                    "downvotes" to downvotes,
                    "adult" to "false",
                    "filterComments" to "true",
                    "safe" to "false",
                    "age" to "0",
                    "balance" to "0",
                    "followers" to "0",
                    "ownTheme" to "false",
                ) + realmThemeDefaults.mapKeys { "theme_${it.key}" }
            )
    }
}

data class RealmCreationQuote(
    val owner: String,
    val network: String,
    val userId: Long,
    val name: String,
    val payloadJson: String,
    val limits: RealmCreationLimits,
    val preparedAtMillis: Long,
) {
    init {
        require(
            owner.isNotBlank() &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                userId >= 0 &&
                preparedAtMillis >= 0
        )
        require(RealmCreation.validArguments(arguments()))
        RealmCreation.validateName(name, limits.maxNameBytes)
        require(!name.equals(limits.reservedName, ignoreCase = true))
        require(
            WithdrawQuote.unsigned(creationMapper.readTree(payloadJson), "cleanup_penalty") <=
                limits.maxPenalty
        )
    }

    fun arguments(): ByteArray =
        creationMapper.writeValueAsBytes(listOf(name, creationMapper.readTree(payloadJson)))

    fun validate(user: JsonNode, current: RealmCreationLimits, nowMillis: Long) {
        require(nowMillis >= preparedAtMillis && nowMillis - preparedAtMillis <= 120000) {
            "Creation confirmation expired. Review it again."
        }
        require(current == limits && user.path("id").asLong(-1) == userId) {
            "Account or Realm creation settings changed. Review again."
        }
        require(user.path("deactivated").isBoolean && !user["deactivated"].asBoolean()) {
            "This account is stopped."
        }
        require(WithdrawQuote.unsigned(user, "cycles") >= limits.cost) {
            "Insufficient credits to create the Realm."
        }
    }
}

object RealmCreation {
    fun validateName(name: String, maximumBytes: Int) {
        require(
            name.isNotEmpty() &&
                name.toByteArray().size <= maximumBytes &&
                name.matches(Regex("[\\p{L}\\p{N}_-]+")) &&
                !name.all { it in '0'..'9' }
        ) {
            "Realm name must fit $maximumBytes UTF-8 bytes, contain letters/numbers/_/-, and not be only digits."
        }
    }

    fun validArguments(bytes: ByteArray): Boolean =
        try {
            require(bytes.size <= 65536)
            val args = creationMapper.readTree(bytes)
            require(args.isArray && args.size() == 2 && args[0].isTextual)
            validateName(args[0].asText(), 128)
            require(args[0].asText() == args[0].asText().uppercase(Locale.ROOT))
            require(
                RealmSettings.validArguments(bytes) &&
                    args[1]["description"].asText().isNotBlank() &&
                    args[1]["logo"].asText().isEmpty()
            )
            for (key in
                listOf(
                    "last_setting_update",
                    "last_update",
                    "num_members",
                    "num_posts",
                    "revenue",
                    "created",
                )) require(args[1][key].bigIntegerValue() == BigInteger.ZERO)
            require(args[1]["posts"].size() == 0)
            true
        } catch (_: Exception) {
            false
        }
}
