package org.taggr.android.data

import java.nio.ByteBuffer
import java.util.zip.CRC32
import org.junit.Assert.*
import org.junit.Test

class TransferQuoteTest {
    private val address =
        ByteArray(32)
            .also { bytes ->
                ByteBuffer.allocate(4)
                    .putInt(CRC32().apply { update(bytes, 4, 28) }.value.toInt())
                    .array()
                    .copyInto(bytes)
            }
            .let { DraftImages.hex(it) }
    private val snapshot = WalletSnapshot("2vxsx-fae", 100000000u, 10000u, 2)

    @Test
    fun changingGatewayDoesNotLosePendingWalletScope() {
        val first =
            org.ic4j.agent.android.ICClientConfiguration(
                TaggrApi.CANISTER_ID,
                "https://example.com",
                apiBaseURL = java.net.URI("https://gateway-one.example"),
            )
        val second =
            org.ic4j.agent.android.ICClientConfiguration(
                TaggrApi.CANISTER_ID,
                "https://example.com",
                apiBaseURL = java.net.URI("https://gateway-two.example"),
            )
        assertEquals(transferNetwork(first), transferNetwork(second))
        val changedRoot =
            first.rootKey.also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        val otherChain =
            org.ic4j.agent.android.ICClientConfiguration(
                TaggrApi.CANISTER_ID,
                "https://example.com",
                rootKey = changedRoot,
            )
        assertNotEquals(transferNetwork(first), transferNetwork(otherChain))
    }

    @Test
    fun checksFeeBalanceOwnerAndConfirmationExpiry() {
        val quote = TransferQuote.prepare(address, "0.9", snapshot, "a".repeat(64), 1000)
        assertEquals(90000000uL, quote.amount)
        quote.validate(snapshot, 121000)
        assertThrows(IllegalArgumentException::class.java) { quote.validate(snapshot, 121001) }
        assertThrows(IllegalArgumentException::class.java) { quote.validate(snapshot, 999) }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate(snapshot.copy(owner = "aaaaa-aa"), 1000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate(snapshot.copy(feeE8s = 20000u), 1000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate(snapshot.copy(balanceE8s = 90000000u), 1000)
        }
    }

    @Test
    fun rejectsInvalidAddressesZeroAndExcessPrecision() {
        for (amount in listOf("0", "-1", "1.123456789", "1e-3")) assertThrows(
            IllegalArgumentException::class.java
        ) {
            TransferQuote.prepare(address, amount, snapshot, "a".repeat(64), 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            TransferQuote.prepare("invalid-principal", "0.1", snapshot, "a".repeat(64), 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            TransferQuote.prepare("0".repeat(64), "0.1", snapshot, "a".repeat(64), 1)
        }
    }

    @Test
    fun confirmedRejectionsNeverBecomeSuccessAndDuplicateKeepsBlock() {
        assertEquals(9uL, confirmedTransfer(LedgerTransferResult.Completed(9u, true)))
        for (result in
            listOf(
                LedgerTransferResult.BadFee(20u),
                LedgerTransferResult.InsufficientFunds(0u),
                LedgerTransferResult.TooOld(100u),
                LedgerTransferResult.CreatedInFuture,
            )) assertThrows(TransferRejected::class.java) { confirmedTransfer(result) }
    }
}
