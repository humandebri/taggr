package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode

object BookmarkIDs {
    const val PAGE_SIZE = 50

    fun decode(value: JsonNode?): List<Long> {
        if (value == null || value.isNull) return emptyList()
        require(value.isArray) { "Invalid bookmark list. Refresh your account." }
        return value
            .map {
                require(
                    it.isIntegralNumber &&
                        it.bigIntegerValue().signum() >= 0 &&
                        it.bigIntegerValue().bitLength() <= 63
                ) {
                    "Invalid bookmark ID. Refresh your account."
                }
                it.asLong()
            }
            .distinct()
    }

    fun page(ids: List<Long>, page: Int): List<Long> {
        require(page >= 0)
        return ids.drop(Math.multiplyExact(page, PAGE_SIZE)).take(PAGE_SIZE)
    }

    fun hasMore(ids: List<Long>, page: Int) =
        Math.multiplyExact(page.toLong() + 1, PAGE_SIZE.toLong()) < ids.size
}
