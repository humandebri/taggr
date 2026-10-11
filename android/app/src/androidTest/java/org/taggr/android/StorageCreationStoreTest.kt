package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class StorageCreationStoreTest {
    @Test
    fun persistedPaymentCannotBeOverwrittenOrClearedByStaleCallback() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val dir = File(base.cacheDir, "creation-test-${UUID.randomUUID()}")
        val context =
            object : ContextWrapper(base) {
                override fun getNoBackupFilesDir() = dir
            }
        val owner = "2vxsx-fae"
        val network = "a".repeat(64)
        val quote =
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
        try {
            val store = StorageCreationStore(context)
            val initial = StorageCreationRecord(quote)
            store.create(initial)
            val payment =
                initial.withPayment(
                    PendingTransfer(
                        quote.transfer,
                        ByteArray(32) { 1 },
                        123uL,
                        StorageProvisioning.CREATE_MEMO,
                    )
                )
            store.update(initial, payment)
            val restarted = StorageCreationStore(context)
            val restored = restarted.load(owner, network)!!
            assertEquals(StorageCreationPhase.PAYMENT_PENDING, restored.phase)
            assertThrows(IllegalArgumentException::class.java) { restarted.create(initial) }
            assertThrows(IllegalArgumentException::class.java) { store.update(initial, payment) }
            assertThrows(IllegalArgumentException::class.java) {
                restarted.clearCompleted(restored)
            }
            assertNull(restarted.load(owner, "d".repeat(64)))
            val paid = restored.paymentConfirmed(42uL)
            restarted.update(restored, paid)
            assertThrows(IllegalArgumentException::class.java) {
                restarted.update(paid, paid.copy(block = 43uL))
            }
            assertEquals(42uL, restarted.load(owner, network)!!.block)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun acknowledgementPreservesReceiptAndCannotClearUnknownOrChangedPayment() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val dir = File(base.cacheDir, "creation-result-test-${UUID.randomUUID()}")
        val context =
            object : ContextWrapper(base) {
                override fun getNoBackupFilesDir() = dir
            }
        val owner = "2vxsx-fae"
        val network = "a".repeat(64)
        val quote =
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
        try {
            val store = StorageCreationStore(context)
            val initial = StorageCreationRecord(quote)
            store.create(initial)
            val pending =
                initial.withPayment(
                    PendingTransfer(
                        quote.transfer,
                        ByteArray(32) { 1 },
                        123uL,
                        StorageProvisioning.CREATE_MEMO,
                    )
                )
            store.update(initial, pending)
            assertThrows(IllegalArgumentException::class.java) { store.acknowledgeFailure(pending) }
            val rejected =
                pending.copy(
                    failure =
                        StorageCreationFailure(
                            StorageCreationFailureKind.PAYMENT_REJECTED,
                            "Rejected",
                        )
                )
            store.update(pending, rejected)
            assertThrows(IllegalArgumentException::class.java) {
                store.acknowledgeFailure(
                    rejected.copy(failure = rejected.failure!!.copy(reason = "Changed"))
                )
            }
            assertThrows(IllegalArgumentException::class.java) { store.update(rejected, pending) }
            store.acknowledgeFailure(rejected)
            val restarted = StorageCreationStore(context)
            assertNull(restarted.load(owner, network))
            val receipt = restarted.latestFailureReceipt(owner, network)!!
            assertEquals(rejected.id, receipt.id)
            assertEquals(rejected.failure, receipt.failure)
            assertArrayEquals(rejected.payment!!.requestId, receipt.payment!!.requestId)
            restarted.create(StorageCreationRecord(quote))
            assertNotNull(restarted.load(owner, network))
            assertEquals(rejected.id, restarted.latestFailureReceipt(owner, network)!!.id)
        } finally {
            dir.deleteRecursively()
        }
    }
}
