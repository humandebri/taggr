package org.taggr.android.data

import org.junit.Assert.*
import org.junit.Test

class StorageCreationTest {
    private val owner = "2vxsx-fae"
    private val network = "a".repeat(64)
    private val quote =
        StorageCreationQuote(
            7,
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            network,
            TransferQuote(
                owner,
                "b".repeat(64),
                DraftImages.hex(StorageProvisioning.creationAccount(owner)),
                100_000uL,
                10_000uL,
                1000,
            ),
            "c".repeat(64),
        )

    private fun id(value: Int) = ByteArray(32) { value.toByte() }

    private fun pending() =
        PendingTransfer(quote.transfer, id(1), ULong.MAX_VALUE, StorageProvisioning.CREATE_MEMO)

    @Test
    fun resumeRetainsPaymentAndEveryRequestAfterRestart() {
        var row = StorageCreationRecord(quote).withPayment(pending()).withPaymentReplay(id(2))
        row =
            row.paymentConfirmed(ULong.MAX_VALUE)
                .withCMCRequest(id(3))
                .created("r7inp-6aaaa-aaaaa-aaabq-cai")
                .withInstallRequest(id(4))
                .installed(quote.moduleHash)
                .withRegistrationRequest(id(5))
        val restored = StorageCreationCodec.decode(StorageCreationCodec.encode(row), owner, network)
        assertEquals(StorageCreationPhase.REGISTERING, restored.phase)
        assertEquals(ULong.MAX_VALUE, restored.block)
        assertEquals(ULong.MAX_VALUE, restored.payment!!.createdAtNanos)
        assertArrayEquals(id(2), restored.payment.replayRequestIds.single())
        assertArrayEquals(id(3), restored.cmcRequests.single())
        assertArrayEquals(id(4), restored.installRequests.single())
        assertArrayEquals(id(5), restored.registrationRequests.single())
        assertEquals(StorageCreationPhase.COMPLETE, restored.registered(restored.bucket!!).phase)
        assertThrows(IllegalArgumentException::class.java) {
            StorageCreationCodec.decode(StorageCreationCodec.encode(row), owner, "d".repeat(64))
        }
    }

    @Test
    fun rejectWrongMemoMissingReceiptAndChangedApprovedCode() {
        val initial = StorageCreationRecord(quote)
        assertThrows(IllegalArgumentException::class.java) {
            initial.withPayment(pending().copy(memo = StorageProvisioning.TOP_UP_MEMO))
        }
        assertThrows(IllegalArgumentException::class.java) { initial.paymentConfirmed(1uL) }
        assertThrows(IllegalArgumentException::class.java) {
            initial.copy(bucket = "r7inp-6aaaa-aaaaa-aaabq-cai")
        }
        val created =
            initial
                .withPayment(pending())
                .paymentConfirmed(1uL)
                .withCMCRequest(id(3))
                .created("r7inp-6aaaa-aaaaa-aaabq-cai")
        assertThrows(IllegalArgumentException::class.java) { created.installed("d".repeat(64)) }
        assertThrows(IllegalArgumentException::class.java) { created.registered(created.bucket!!) }
        assertThrows(IllegalArgumentException::class.java) { created.withPaymentReplay(id(6)) }
    }
}
