package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode

internal object PinnedPosts {
    fun decode(value: JsonNode?): List<Long> {
        if (value == null || value.isNull) return emptyList()
        require(value.isArray) { "Invalid pinned posts. Refresh your account." }
        return value
            .map {
                require(it.isIntegralNumber && it.canConvertToLong() && it.longValue() >= 0) {
                    "Invalid pinned post ID. Refresh your account."
                }
                it.longValue()
            }
            .distinct()
    }
}
