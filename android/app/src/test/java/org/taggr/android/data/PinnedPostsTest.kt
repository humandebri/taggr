package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class PinnedPostsTest {
    private val mapper = ObjectMapper()

    @Test
    fun retainsBackendOrderAndExactIdsWithoutDuplicates() {
        assertEquals(
            listOf(90L, 40L, Long.MAX_VALUE),
            PinnedPosts.decode(mapper.readTree("[90,40,90,9223372036854775807]")),
        )
        assertEquals(emptyList<Long>(), PinnedPosts.decode(null))
        assertEquals(emptyList<Long>(), PinnedPosts.decode(mapper.readTree("null")))
    }

    @Test
    fun rejectsMalformedStatusRatherThanPresentingAnUnpinnedDefault() {
        for (json in listOf("{}", "[null]", "[\"40\"]", "[-1]", "[0.5]", "[9223372036854775808]")) {
            assertTrue(json, runCatching { PinnedPosts.decode(mapper.readTree(json)) }.isFailure)
        }
    }
}
