package org.taggr.android.data

import org.junit.Assert.assertEquals
import org.junit.Test

class LegacyJsonArgumentsTest {
    @Test
    fun matchesSwiftAndBackendSingleScalarAndVectorContracts() {
        assertEquals("null", String(LegacyJsonArguments.encode(emptyList())))
        assertEquals("42", String(LegacyJsonArguments.encode(listOf(42))))
        assertEquals("[42]", String(LegacyJsonArguments.encode(listOf(listOf(42)))))
        assertEquals("[\"DAO\"]", String(LegacyJsonArguments.encode(listOf(listOf("DAO")))))
        assertEquals(
            "[\"domain\",[]]",
            String(LegacyJsonArguments.encode(listOf("domain", emptyList<String>()))),
        )
        assertEquals("[42,10]", String(LegacyJsonArguments.encode(listOf(42, 10))))
    }
}
