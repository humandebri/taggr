package org.taggr.android.data

import org.ic4j.agent.android.ICPAccountIdentifier
import org.junit.Assert.*
import org.junit.Test

class CreditInvoiceTest {
    private fun receipt(paid: Boolean = false) =
        CreditInvoiceReceipt(
            "2vxsx-fae",
            "a".repeat(64),
            "aaaaa-aa",
            ICPInvoice(
                ULong.MAX_VALUE,
                if (paid) ULong.MAX_VALUE else 0uL,
                paid,
                DraftImages.hex(ICPAccountIdentifier.account("aaaaa-aa", "2vxsx-fae")),
            ),
            ByteArray(32) { it.toByte() },
            1000,
        )

    @Test
    fun paidReceiptKeepsExactUnsignedAmountAndRequestAcrossRestart() {
        val original = receipt(true)
        val restored = CreditInvoiceCodec.decode(CreditInvoiceCodec.encode(original))
        assertEquals(original.invoice, restored.invoice)
        assertArrayEquals(original.requestId, restored.requestId)
        assertEquals(original.owner, restored.owner)
        assertEquals(original.network, restored.network)
    }

    @Test
    fun recipientMustBeDerivedFromSigningPrincipalAndTaggrCanister() {
        val original = receipt()
        for (changed in listOf("aaaaa-aa", "ryjl3-tyaaa-aaaaa-aaaba-cai")) {
            assertThrows(IllegalArgumentException::class.java) { original.copy(owner = changed) }
        }
        assertThrows(IllegalArgumentException::class.java) { original.copy(canister = "2vxsx-fae") }
    }

    @Test
    fun malformedStoredPrincipalIsARecoverableValidationError() {
        val original = receipt()
        assertThrows(IllegalArgumentException::class.java) {
            original.copy(owner = "aaaaa-ab")
        }
        assertThrows(IllegalArgumentException::class.java) {
            original.copy(canister = "aaaaa-ab")
        }
    }

    @Test
    fun inconsistentPaymentStatusAndOversizedReceiptAreRejected() {
        val original = receipt()
        assertThrows(IllegalArgumentException::class.java) {
            original.copy(invoice = original.invoice.copy(paidE8s = 1uL))
        }
        assertThrows(IllegalArgumentException::class.java) {
            original.copy(invoice = original.invoice.copy(paid = true))
        }
        assertThrows(IllegalArgumentException::class.java) {
            CreditInvoiceCodec.decode(ByteArray(4097))
        }
    }
}
