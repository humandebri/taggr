package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode

data class ReactionGroup(val id: Int, val emoji: String, val users: List<Long>) {
    companion object {
        val defaultOrder = listOf(11, 10, 50, 51, 52, 53, 100, 101, 12, 1)

        fun emoji(id: Int): String? =
            when (id) {
                1 -> "❌"
                10 -> "❤️"
                11 -> "👍"
                12 -> "😢"
                50 -> "🔥"
                51 -> "😂"
                52 -> "💯"
                53 -> "🚀"
                100 -> "⭐️"
                101 -> "🏴‍☠️"
                else -> null
            }

        fun decode(node: JsonNode): Map<Int, List<Long>> {
            if (!node.isObject) return emptyMap()
            return node
                .fields()
                .asSequence()
                .mapNotNull { entry ->
                    val id =
                        entry.key.toIntOrNull()?.takeIf {
                            it in 0..65535 && it.toString() == entry.key
                        } ?: return@mapNotNull null
                    if (!entry.value.isArray) return@mapNotNull null
                    id to
                        entry.value
                            .filter {
                                it.isIntegralNumber && it.canConvertToLong() && it.asLong() >= 0
                            }
                            .map { it.asLong() }
                            .distinct()
                }
                .toMap()
        }

        fun groups(reactions: Map<Int, List<Long>>, order: List<Int>): List<ReactionGroup> =
            reactions
                .mapNotNull { (id, users) -> emoji(id)?.let { ReactionGroup(id, it, users) } }
                .sortedWith(
                    compareBy<ReactionGroup> {
                            order.indexOf(it.id).takeIf { it >= 0 } ?: Int.MAX_VALUE
                        }
                        .thenBy { it.id }
                )
    }
}
