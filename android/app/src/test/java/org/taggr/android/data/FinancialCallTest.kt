package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class FinancialCallTest {
    private val mapper = ObjectMapper()

    private fun user(treasury: Long = 123000000, principal: String = "2vxsx-fae") =
        mapper.readTree("""{"id":7,"principal":"$principal","treasury_e8s":$treasury}""")

    private fun quote() = WithdrawQuote.prepare("aaaaa-aa", user(), 10000u, "a".repeat(64), 1000)

    @Test
    fun withdrawalUsesAccountOwnerAndRejectsChangedConfirmation() {
        val quote = quote()
        assertEquals("2vxsx-fae", quote.recipient)
        assertNotEquals(quote.owner, quote.recipient)
        assertEquals(122990000uL, quote.netE8s)
        quote.validate(user(), 10000u, 121000)
        for (changed in
            listOf(
                user(123000001),
                user(principal = "aaaaa-aa"),
                user().deepCopy<com.fasterxml.jackson.databind.node.ObjectNode>().put("id", 8),
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                quote.validate(changed, 10000u, 1000)
            }
        }
        for (time in listOf(999L, 121001L)) assertThrows(IllegalArgumentException::class.java) {
            quote.validate(user(), 10000u, time)
        }
        assertThrows(IllegalArgumentException::class.java) { quote.validate(user(), 20000u, 1000) }
        assertThrows(IllegalArgumentException::class.java) {
            WithdrawQuote.prepare("aaaaa-aa", user(10000), 10000u, "a".repeat(64), 1000)
        }
    }

    @Test
    fun repliesRequireOneValidResultAndInvoicesRejectOverflowBytes() {
        assertTrue(
            FinancialReply.decode("withdraw_rewards", """{"Ok":null}""".toByteArray()).isNull
        )
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode(
                "withdraw_rewards",
                """{"Err":"Insufficient rewards"}""".toByteArray(),
            )
        }
        for (reply in listOf("{}", "{\"Ok\":1}", "{\"Ok\":null,\"Err\":\"x\"}")) {
            assertThrows(IllegalArgumentException::class.java) {
                FinancialReply.decode("withdraw_rewards", reply.toByteArray())
            }
        }
        val invoice =
            mapper.createObjectNode().put("e8s", 123).put("paid_e8s", 0).put("paid", false)
        val bytes = invoice.putArray("account")
        repeat(32) { bytes.add(if (it == 0) 4294967296L else 0L) }
        assertThrows(IllegalArgumentException::class.java) { ICPInvoice.decode(invoice) }
    }

    @Test
    fun persistedCallsOnlyAcceptExactSupportedArguments() {
        FinancialCall(
            "aaaaa-aa",
            "aaaaa-aa",
            "a".repeat(64),
            "withdraw_rewards",
            ByteArray(32),
            "null".toByteArray(),
        )
        for ((method, args) in
            listOf(
                "withdraw_rewards" to "[]",
                "mint_credits_with_icp" to "2",
                "transfer" to "null",
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                FinancialCall(
                    "aaaaa-aa",
                    "aaaaa-aa",
                    "a".repeat(64),
                    method,
                    ByteArray(32),
                    args.toByteArray(),
                )
            }
        }
    }
}
