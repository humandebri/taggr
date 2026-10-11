package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class BookmarkIDsTest {
    private val mapper = ObjectMapper()

    @Test
    fun stableDistinctIdsAreBatchedWithoutSkippingBoundary() {
        val ids = BookmarkIDs.decode(mapper.readTree((0..100).toList().plus(0).toString()))
        assertEquals(101, ids.size)
        assertEquals((0L..49L).toList(), BookmarkIDs.page(ids, 0))
        assertEquals((50L..99L).toList(), BookmarkIDs.page(ids, 1))
        assertEquals(listOf(100L), BookmarkIDs.page(ids, 2))
        assertTrue(BookmarkIDs.hasMore(ids, 1))
        assertFalse(BookmarkIDs.hasMore(ids, 2))
        assertEquals(emptyList<Long>(), BookmarkIDs.page(ids, 3))
    }

    @Test
    fun invalidIdsNeverWrapAndEmptyListNeverHasMore() {
        for (json in listOf("[18446744073709551615]", "[-1]", "[\"5\"]", "{}")) {
            assertThrows(IllegalArgumentException::class.java) {
                BookmarkIDs.decode(mapper.readTree(json))
            }
        }
        assertFalse(BookmarkIDs.hasMore(emptyList(), 0))
        assertThrows(IllegalArgumentException::class.java) { BookmarkIDs.page(emptyList(), -1) }
    }
}
