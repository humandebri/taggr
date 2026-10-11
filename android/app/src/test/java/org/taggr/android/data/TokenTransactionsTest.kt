package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import org.ic4j.agent.android.*
import org.ic4j.types.Principal
import org.junit.Assert.*
import org.junit.Test

class TokenTransactionsTest {
    private val mapper = ObjectMapper()

    private fun page() =
        mapper.readTree(
            """[[4294967295,{"from":{"owner":"aaaaa-aa","subaccount":null},"to":{"owner":"2vxsx-fae","subaccount":null},"amount":18446744073709551615,"fee":1000,"timestamp":18446744073709551615,"memo":[0,255]}]]"""
        )

    @Test
    fun textualSubaccountMatchesIndependentCrc32Base32VectorAndRejectsTampering() {
        val account = TokenAccount("2vxsx-fae", "0".repeat(63) + "1")
        assertEquals("2vxsx-fae-22yutvy.1", account.address)
        assertEquals(account, TokenAccount.parse(account.address))
        assertEquals(TokenAccount("2vxsx-fae"), TokenAccount.parse("2vxsx-fae"))
        for (text in
            listOf(
                "2vxsx-fae-22yutvy.2",
                "2vxsx-fae-22yutvx.1",
                "2vxsx-fae-22yutvy.",
                "aaaaa-ab",
                "2vxsx-fae-22yutvy.1.2",
            )) {
            assertThrows(IllegalArgumentException::class.java) { TokenAccount.parse(text) }
        }
    }

    @Test
    fun transactionsKeepUint32IdsUint64AmountsTimestampAndBinaryMemo() {
        val entry = TokenTransactions.decode(page()).single()
        assertEquals(4294967295L, entry.id)
        assertEquals(ULong.MAX_VALUE, entry.amount)
        assertEquals(ULong.MAX_VALUE, entry.timestamp)
        assertEquals("00ff", entry.memo)
        assertEquals("2vxsx-fae", entry.to.address)
    }

    @Test
    fun invalidBytesUnsignedOverflowAndDuplicateIdsAreRejected() {
        for ((field, value) in
            listOf("amount" to "18446744073709551616", "fee" to "-1", "timestamp" to "1.5")) {
            val rows = page()
            (rows[0][1] as com.fasterxml.jackson.databind.node.ObjectNode).set<
                com.fasterxml.jackson.databind.JsonNode
            >(
                field,
                mapper.readTree(value),
            )
            assertThrows(IllegalArgumentException::class.java) { TokenTransactions.decode(rows) }
        }
        for (value in listOf("[256]", "[-1]", "[4294967296]")) {
            val rows = page()
            (rows[0][1] as com.fasterxml.jackson.databind.node.ObjectNode).set<
                com.fasterxml.jackson.databind.JsonNode
            >(
                "memo",
                mapper.readTree(value),
            )
            assertThrows(IllegalArgumentException::class.java) { TokenTransactions.decode(rows) }
        }
        val rows = page() as com.fasterxml.jackson.databind.node.ArrayNode
        rows.add(rows[0].deepCopy<com.fasterxml.jackson.databind.JsonNode>())
        assertThrows(IllegalArgumentException::class.java) { TokenTransactions.decode(rows) }
    }

    @Test
    fun candidBalanceUsesOwnerAndExactOptionalSubaccountAndRequiresNatReply() {
        val account = TokenAccount.parse("2vxsx-fae-22yutvy.1")
        val record =
            Candid.decode(TokenTransactions.balanceArguments(account)).values.single().value
                as Map<*, *>
        assertEquals(Principal.fromString(account.owner), record[Candid.fieldID("owner")])
        assertArrayEquals(
            account.bytes,
            (record[Candid.fieldID("subaccount")] as CandidOption.Some).value as ByteArray,
        )
        val amount = BigInteger("18446744073709551616")
        assertEquals(
            amount,
            TokenTransactions.balanceReply(CandidArguments(Candid.nat.encode(amount)).encode()),
        )
        assertThrows(IllegalArgumentException::class.java) {
            TokenTransactions.balanceReply(CandidArguments(Candid.nat64.encode(1uL)).encode())
        }
    }
}
