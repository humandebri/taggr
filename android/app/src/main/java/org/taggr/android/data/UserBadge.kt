package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import java.math.BigInteger

enum class UserBadge(val label: String, val accessibilityLabel: String) {
    Bot("BOT", "Bot account"),
    Og("OG", "OG account"),
    Stalwart("STALWART", "Stalwart"),
    Frequenter("FREQUENTER", "Frequenter"),
    FollowsYou("FOLLOWS YOU", "Follows you"),
    Inactive("INACTIVE", "Inactive");

    companion object {
        fun decode(node: JsonNode): List<UserBadge> =
            (if (node.isArray) node.toList() else emptyList())
                .filter { it.isTextual }
                .mapNotNull { value -> entries.firstOrNull { it.label == value.asText() } }
                .distinct()

        fun profile(
            user: JsonNode,
            viewer: Long?,
            activityWeeks: BigInteger?,
            nowMillis: Long,
        ): List<UserBadge> = buildList {
            val bot = user.path("controllers").any { it.isTextual && it.asText().length == 27 }
            if (bot) add(Bot)
            else if (
                unsigned(user.path("timestamp"))?.let { it < BigInteger("1672500000000000000") } ==
                    true
            )
                add(Og)
            if (user.path("stalwart").asBoolean()) add(Stalwart)
            if (unsigned(user.path("active_weeks"))?.let { it > BigInteger.valueOf(12) } == true)
                add(Frequenter)
            if (
                viewer != null &&
                    user.path("id").isIntegralNumber &&
                    user.path("id").asLong() != viewer &&
                    user.path("followees").any {
                        it.isIntegralNumber && it.canConvertToLong() && it.asLong() == viewer
                    }
            )
                add(FollowsYou)
            val lastActivity = unsigned(user.path("last_activity"))
            if (lastActivity != null && activityWeeks != null && activityWeeks.signum() >= 0) {
                val deadline = lastActivity + activityWeeks * BigInteger("604800000000000")
                if (BigInteger.valueOf(nowMillis) * BigInteger.valueOf(1000000) > deadline)
                    add(Inactive)
            }
        }

        fun unsigned(node: JsonNode): BigInteger? =
            node
                .takeIf { it.isIntegralNumber }
                ?.bigIntegerValue()
                ?.takeIf { it.signum() >= 0 && it.bitLength() <= 64 }
    }
}
