package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class CreditTransferTest {
    private val mapper = ObjectMapper()

    private fun user(balance: String = "110") = mapper.readTree("""{"id":7,"cycles":$balance}""")

    private fun recipient(name: String = "Alice") = mapper.readTree("""{"id":9,"name":"$name"}""")

    private fun quote() =
        CreditTransferQuote("owner", 7, 9, "Alice", 100uL, 10uL, "0".repeat(64), 1000)

    @Test
    fun amountsArePositiveAsciiIntegersWithExactUnsignedLimits() {
        assertEquals(10uL, CreditTransferQuote.parse(" 010 "))
        for (value in
            listOf("", "0", "-1", "+1", "1.0", "1e3", "１", "18446744073709551616")) assertNull(
            CreditTransferQuote.parse(value)
        )
        assertEquals(ULong.MAX_VALUE, CreditTransferQuote.parse(ULong.MAX_VALUE.toString()))
        assertEquals(110uL, CreditTransferQuote.total(100uL, 10uL))
        assertThrows(IllegalArgumentException::class.java) {
            CreditTransferQuote.total(ULong.MAX_VALUE, 1uL)
        }
    }

    @Test
    fun feeBalanceRecipientAndExpiryAreRevalidated() {
        quote().validate(user(), recipient(), 10uL, 121000)
        assertThrows(IllegalArgumentException::class.java) {
            quote().validate(user("109"), recipient(), 10uL, 1000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote().validate(user(), recipient(), 11uL, 1000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote().validate(user(), recipient("Renamed"), 10uL, 1000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote().validate(user(), recipient(), 10uL, 121001)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote().validate(user(), recipient(), 10uL, 999)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CreditTransferQuote("owner", 7, 7, "Self", 1uL, 0uL, "0".repeat(64), 0)
        }
    }

    @Test
    fun canonicalWireIsAdmittedAndUnitResultIsRequired() {
        assertEquals("[9,100]", quote().arguments().toString(Charsets.UTF_8))
        assertTrue(
            CreditTransferQuote.validArguments(CreditTransferQuote.arguments(9, ULong.MAX_VALUE))
        )
        for (args in
            listOf(
                "[9,0]",
                "[-1,1]",
                "[9,1.0]",
                "[9,\"1\"]",
                "[9,1] null",
                "[9, 1]",
                "[9,18446744073709551616]",
            )) assertFalse(CreditTransferQuote.validArguments(args.toByteArray()))
        FinancialCall(
            "owner",
            "canister",
            "0".repeat(64),
            "transfer_credits",
            ByteArray(32),
            quote().arguments(),
        )
        assertTrue(
            FinancialReply.decode("transfer_credits", """{"Ok":null}""".toByteArray()).isNull
        )
        assertThrows(IllegalArgumentException::class.java) {
            FinancialReply.decode("transfer_credits", """{"Ok":true}""".toByteArray())
        }
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode(
                "transfer_credits",
                """{"Err":"insufficient credits"}""".toByteArray(),
            )
        }
    }
}
