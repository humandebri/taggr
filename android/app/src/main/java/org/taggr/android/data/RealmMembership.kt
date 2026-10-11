package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper

object RealmMembership {
    private val mapper =
        ObjectMapper()
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS)

    fun arguments(name: String): ByteArray {
        require(validName(name)) { "Invalid Realm name." }
        return mapper.writeValueAsBytes(name)
    }

    fun validArguments(bytes: ByteArray): Boolean =
        try {
            val value = mapper.readTree(bytes)
            bytes.size <= 8192 && value.isTextual && validName(value.asText())
        } catch (_: Exception) {
            false
        }

    private fun validName(name: String) =
        name.isNotEmpty() &&
            name.toByteArray().size <= 1024 &&
            name.matches(Regex("[\\p{L}\\p{N}_-]+")) &&
            !name.all { it in '0'..'9' }

    fun joined(user: JsonNode, name: String): Boolean {
        val realms = user.path("realms")
        require(realms.isArray && realms.all { it.isTextual }) {
            "Realm membership is unavailable. Refresh your account."
        }
        return realms.any { it.asText().equals(name, ignoreCase = true) }
    }

    fun validateConsent(approved: JsonNode, current: JsonNode) {
        RealmSettings.validateMetadata(approved, requireControllers = false)
        RealmSettings.validateMetadata(current, requireControllers = false)
        require(
            listOf(
                    "description",
                    "cleanup_penalty",
                    "max_downvotes",
                    "filter",
                    "whitelist",
                    "controllers",
                    "comments_filtering",
                    "adult_content",
                    "last_setting_update",
                )
                .all { approved[it] == current[it] }
        ) {
            "Realm rules changed. Review the current description and rules before joining."
        }
    }

    suspend fun set(
        name: String,
        desired: Boolean,
        user: suspend () -> JsonNode,
        toggle: suspend (ByteArray) -> JsonNode,
    ) {
        val arguments = arguments(name)
        if (joined(user(), name) == desired) return
        val reply = toggle(arguments)
        require(reply.isBoolean && reply.asBoolean() == desired) {
            "The Realm returned a different membership state. Refresh before changing it again."
        }
        require(joined(user(), name) == desired) {
            "Realm membership did not refresh to the requested state. Refresh before changing it again."
        }
    }

    fun notice(call: FinancialCall, reply: JsonNode): String {
        require(call.method == "toggle_realm_membership" && reply.isBoolean)
        val name = mapper.readTree(call.arguments).asText()
        return "Realm /$name: ${if (reply.asBoolean()) "joined" else "left"} (confirmed)."
    }
}
