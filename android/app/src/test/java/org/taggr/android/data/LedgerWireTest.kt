package org.taggr.android.data

import java.math.BigInteger
import org.ic4j.agent.android.*
import org.junit.Assert.*
import org.junit.Test

class LedgerWireTest {
    @Test
    fun transferIncludesTimestampDefaultSubaccountAndExactAmounts() {
        val to = ByteArray(32) { it.toByte() }
        val record =
            Candid.decode(
                    LedgerWire.transferArguments(to, 123456789u, 10000u, 42u, 123456789012345u)
                )
                .values
                .single()
                .value
        assertArrayEquals(to, LedgerWire.field(record, "to") as ByteArray)
        assertEquals(
            123456789uL,
            LedgerWire.uint(LedgerWire.field(LedgerWire.field(record, "amount"), "e8s")),
        )
        assertEquals(
            10000uL,
            LedgerWire.uint(LedgerWire.field(LedgerWire.field(record, "fee"), "e8s")),
        )
        val timestamp = LedgerWire.field(record, "created_at_time") as CandidOption.Some
        assertEquals(
            123456789012345uL,
            LedgerWire.uint(LedgerWire.field(timestamp.value, "timestamp_nanos")),
        )
        assertEquals(CandidOption.None, (record as Map<*, *>)[Candid.fieldID("from_subaccount")])
        assertThrows(IllegalArgumentException::class.java) {
            LedgerWire.transferArguments(to, ULong.MAX_VALUE, 1u, 0u, 1u)
        }
    }

    private fun reply(tag: String, value: CandidValue): ByteArray {
        val type = CandidType.Variant(listOf(CandidField(tag, value.type)))
        return CandidArguments(CandidValue(type, CandidVariant(Candid.fieldID(tag), value.value)))
            .encode()
    }

    @Test
    fun duplicateIsTheOriginalSuccessfulBlockAndErrorsKeepAmounts() {
        val duplicate = LedgerWire.record("duplicate_of" to Candid.nat64.encode(99u))
        val errorType = CandidType.Variant(listOf(CandidField("TxDuplicate", duplicate.type)))
        val error =
            CandidValue(errorType, CandidVariant(Candid.fieldID("TxDuplicate"), duplicate.value))
        assertEquals(
            LedgerTransferResult.Completed(99u, true),
            LedgerWire.transferReply(reply("Err", error)),
        )
        val badFee =
            LedgerWire.record(
                "expected_fee" to LedgerWire.record("e8s" to Candid.nat64.encode(20000u))
            )
        val feeType = CandidType.Variant(listOf(CandidField("BadFee", badFee.type)))
        assertEquals(
            LedgerTransferResult.BadFee(20000u),
            LedgerWire.transferReply(
                reply(
                    "Err",
                    CandidValue(feeType, CandidVariant(Candid.fieldID("BadFee"), badFee.value)),
                )
            ),
        )
        assertEquals(
            LedgerTransferResult.Completed(5u),
            LedgerWire.transferReply(reply("Ok", Candid.nat64.encode(5u))),
        )
    }

    @Test
    fun tokenUnitsNeverUseFloatingPoint() {
        assertEquals("123.45", WalletAmounts.token(BigInteger("12345"), 2))
        assertEquals("0.01", WalletAmounts.token(BigInteger.ONE, 2))
        assertEquals(
            "184467440737.09551615",
            WalletAmounts.token(BigInteger("18446744073709551615"), 8),
        )
        assertEquals("0", WalletAmounts.token(BigInteger.ZERO, 2))
    }
}
