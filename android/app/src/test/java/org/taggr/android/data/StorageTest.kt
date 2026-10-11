package org.taggr.android.data

import java.math.BigInteger
import org.ic4j.agent.android.*
import org.ic4j.types.Principal
import org.junit.Assert.*
import org.junit.Test

class StorageTest {
    private val hash = "a".repeat(64)

    private fun status() =
        StorageStatus(
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "running",
            listOf("2vxsx-fae"),
            hash,
            BigInteger.TEN,
            BigInteger.valueOf(100),
            BigInteger.TEN,
            hash,
        )

    @Test
    fun confirmationRejectsExpiredChangedOrUncontrolledStorage() {
        val value = status()
        val quote = StorageQuote("2vxsx-fae", 7, value, 1000)
        quote.validate("2vxsx-fae", 7, value, 121000)
        assertEquals(BigInteger.TEN, value.daysRemaining)
        assertNull(value.copy(dailyBurn = BigInteger.ZERO).daysRemaining)
        for (changed in
            listOf(
                value.copy(controllers = emptyList()),
                value.copy(moduleHash = "b".repeat(64)),
                value.copy(status = "stopped"),
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                quote.validate("2vxsx-fae", 7, changed, 1000)
            }
        }
        for (time in listOf(999L, 121001L)) assertThrows(IllegalArgumentException::class.java) {
            quote.validate("2vxsx-fae", 7, value, time)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate("2vxsx-fae", 8, value, 1000)
        }
    }

    @Test
    fun managementArgumentsAndExactLargeMetricsDecode() {
        val decoded = Candid.decode(StorageWire.arguments(status().bucket)).values.single().value
        assertEquals(
            Principal.fromString(status().bucket),
            LedgerWire.field(decoded, "canister_id"),
        )
        val state =
            CandidValue(
                CandidType.Variant(listOf(CandidField("running", CandidType.Primitive.NULL))),
                CandidVariant(Candid.fieldID("running"), null),
            )
        val row =
            LedgerWire.record(
                "status" to state,
                "settings" to
                    LedgerWire.record(
                        "controllers" to
                            Candid.vector(Candid.principal)
                                .encode(listOf(Principal.fromString("2vxsx-fae")))
                    ),
                "module_hash" to
                    Candid.optional(Candid.blob).encode(ByteArray(32) { 0xaa.toByte() }),
                "memory_size" to Candid.nat.encode(BigInteger.TEN),
                "cycles" to Candid.nat.encode(BigInteger.ONE.shiftLeft(90)),
                "idle_cycles_burned_per_day" to Candid.nat.encode(BigInteger.ZERO),
            )
        val result = StorageWire.reply(status().bucket, CandidArguments(row).encode(), hash)
        assertEquals(BigInteger.ONE.shiftLeft(90), result.cycles)
        assertTrue(result.compatible)
        assertEquals(listOf("2vxsx-fae"), result.controllers)
    }
}
