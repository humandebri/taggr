package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode

internal data class ProfileUserState(val id: Long, val follows: Set<Long>, val muted: Set<Long>) {
    companion object {
        fun decode(user: JsonNode): ProfileUserState {
            val id = user.get("id")
            require(
                id != null && id.isIntegralNumber && id.canConvertToLong() && id.longValue() >= 0
            ) {
                "Account unavailable"
            }
            fun ids(value: JsonNode?): Set<Long> {
                require(
                    value != null &&
                        value.isArray &&
                        value.all {
                            it.isIntegralNumber && it.canConvertToLong() && it.longValue() >= 0
                        }
                ) {
                    "Profile action status unavailable. Refresh your account."
                }
                return value.map { it.longValue() }.toSet()
            }
            return ProfileUserState(
                id.longValue(),
                ids(user.get("followees")),
                ids(user.path("filters").get("users")),
            )
        }

        fun confirmMuteReply(reply: JsonNode) {
            require(reply.isObject && reply.size() == 1) {
                "Mute result is unconfirmed. Refresh your account."
            }
            reply.get("Err")?.let {
                require(it.isTextual) { "Invalid mute reply" }
                error(it.asText())
            }
            require(reply.has("Ok") && reply.get("Ok").isNull) {
                "Mute result is unconfirmed. Refresh your account."
            }
        }
    }
}
