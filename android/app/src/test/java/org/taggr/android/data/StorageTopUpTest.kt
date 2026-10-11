package org.taggr.android.data

import java.math.BigInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class StorageTopUpTest {
    private val owner = "2vxsx-fae"
    private val bucket = "r7inp-6aaaa-aaaaa-aaabq-cai"
    private val quote =
        StorageTopUpQuote(
            7,
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "a".repeat(64),
            bucket,
            TransferQuote(
                owner,
                "b".repeat(64),
                DraftImages.hex(StorageProvisioning.topUpAccount(bucket)),
                100000uL,
                10000uL,
                1000,
            ),
        )

    private fun id(n: Int) = ByteArray(32) { n.toByte() }

    private val payment
        get() = PendingTransfer(quote.transfer, id(1), 123uL, StorageProvisioning.TOP_UP_MEMO)

    private inner class Backend : StorageTopUpBackend {
        var payments = 0
        var notified = mutableListOf<Pair<ULong, String>>()
        var payFailure: Exception? = null
        var notifyFailure: Exception? = null
        var known = true
        var valid = true

        override suspend fun validate(row: StorageTopUpRecord) {
            require(valid) { "Account changed" }
        }

        override suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit): ULong {
            payments++
            persist(payment)
            payFailure?.let { throw it }
            return 42uL
        }

        override suspend fun paymentResult(payment: PendingTransfer): ULong? =
            if (known) 42uL else null

        override suspend fun notify(
            block: ULong,
            bucket: String,
            persist: (ByteArray) -> Unit,
        ): BigInteger {
            notified += block to bucket
            persist(id(2 + notified.size))
            notifyFailure?.let { throw it }
            return BigInteger("100000000000000000000")
        }
    }

    @Test
    fun lostPaymentThenLostCMCContinuesSameBlockWithoutRepayment() = runBlocking {
        val backend = Backend()
        val flow = StorageTopUpWorkflow(backend)
        var row = StorageTopUpRecord(quote)
        suspend fun resume() {
            row =
                flow.resume(row) { old, next ->
                    assertArrayEquals(StorageTopUpCodec.encode(row), StorageTopUpCodec.encode(old))
                    row = next
                }
        }
        backend.payFailure = java.io.IOException("socket lost")
        try {
            resume()
            fail()
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Check and continue"))
            assertTrue(e.cause is java.io.IOException)
        }
        row = StorageTopUpCodec.decode(StorageTopUpCodec.encode(row), owner, quote.network)
        backend.known = false
        try {
            resume()
            fail()
        } catch (_: IllegalStateException) {}
        assertEquals(1, backend.payments)
        assertTrue(backend.notified.isEmpty())
        backend.known = true
        backend.notifyFailure = java.io.IOException("socket lost")
        try {
            resume()
            fail()
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("No new ICP payment"))
        }
        assertEquals(42uL, row.block)
        assertEquals(1, row.cmcRequests.size)
        row = StorageTopUpCodec.decode(StorageTopUpCodec.encode(row), owner, quote.network)
        backend.notifyFailure = null
        resume()
        resume()
        assertEquals(1, backend.payments)
        assertEquals(listOf(42uL to bucket, 42uL to bucket), backend.notified)
        assertEquals(BigInteger("100000000000000000000"), row.cycles)
    }

    @Test
    fun confirmedLedgerFailureStopsAndPersists() = runBlocking {
        val backend = Backend().apply { payFailure = TransferRejected("Insufficient funds") }
        var row = StorageTopUpRecord(quote)
        try {
            StorageTopUpWorkflow(backend).resume(row) { _, next -> row = next }
            fail()
        } catch (_: TransferRejected) {}
        assertEquals("PaymentRejected", row.failure!!.kind)
        val saved = StorageTopUpCodec.decode(StorageTopUpCodec.encode(row), owner, quote.network)
        StorageTopUpWorkflow(backend).resume(saved) { _, _ -> fail() }
        assertEquals(1, backend.payments)
        assertTrue(backend.notified.isEmpty())
    }

    @Test
    fun nonRetriableCMCErrorsPersistWithoutNewPayment() = runBlocking {
        for (kind in listOf("Refunded", "InvalidTransaction", "TransactionTooOld")) {
            val backend =
                Backend().apply {
                    notifyFailure =
                        CMCFailure(
                            kind,
                            "Confirmed failure",
                            false,
                            if (kind == "Refunded") 99uL else null,
                        )
                }
            var row = StorageTopUpRecord(quote)
            try {
                StorageTopUpWorkflow(backend).resume(row) { _, next -> row = next }
                fail()
            } catch (_: CMCFailure) {}
            assertEquals(kind, row.failure!!.kind)
            assertEquals(if (kind == "Refunded") 99uL else null, row.failure!!.refundBlock)
            val saved =
                StorageTopUpCodec.decode(StorageTopUpCodec.encode(row), owner, quote.network)
            StorageTopUpWorkflow(backend).resume(saved) { _, _ -> fail() }
            assertEquals(1, backend.payments)
            assertEquals(1, backend.notified.size)
        }
    }

    @Test
    fun processingRetainsPaidReceiptForExplicitContinuation() = runBlocking {
        val backend = Backend().apply { notifyFailure = CMCFailure("Processing", "Pending", true) }
        var row = StorageTopUpRecord(quote)
        try {
            StorageTopUpWorkflow(backend).resume(row) { _, next -> row = next }
            fail()
        } catch (_: CMCFailure) {}
        assertFalse(row.finished)
        assertEquals(42uL, row.block)
        assertEquals(1, row.cmcRequests.size)
        backend.notifyFailure = null
        StorageTopUpWorkflow(backend).resume(row) { _, next -> row = next }
        assertNotNull(row.cycles)
        assertEquals(1, backend.payments)
    }

    @Test
    fun cancellationPropagatesAndPreservesLastDispatchedStage() = runBlocking {
        for (stage in listOf("pay", "notify")) {
            val cancel = CancellationException("Cancelled")
            val backend =
                Backend().apply {
                    if (stage == "pay") payFailure = cancel else notifyFailure = cancel
                }
            var row = StorageTopUpRecord(quote)
            try {
                StorageTopUpWorkflow(backend).resume(row) { _, next -> row = next }
                fail()
            } catch (e: CancellationException) {
                assertSame(cancel, e)
            }
            assertNotNull(row.payment)
            assertFalse(row.finished)
            if (stage == "notify") {
                assertEquals(42uL, row.block)
                assertEquals(1, row.cmcRequests.size)
            } else assertNull(row.block)
        }
    }

    @Test
    fun accountValidationStopsBeforeAnyDispatch() = runBlocking {
        val backend = Backend().apply { valid = false }
        try {
            StorageTopUpWorkflow(backend).resume(StorageTopUpRecord(quote)) { _, _ -> fail() }
            fail()
        } catch (_: IllegalArgumentException) {}
        assertEquals(0, backend.payments)
        assertTrue(backend.notified.isEmpty())
    }

    @Test
    fun codecEnforcesTargetWalletNetworkMemoAndFullWidthReceipt() {
        val row =
            StorageTopUpRecord(
                quote,
                payment = payment,
                block = ULong.MAX_VALUE,
                cmcRequests = listOf(id(2)),
                cycles = BigInteger("184467440737095516160000"),
            )
        val bytes = StorageTopUpCodec.encode(row)
        assertArrayEquals(
            bytes,
            StorageTopUpCodec.encode(StorageTopUpCodec.decode(bytes, owner, quote.network)),
        )
        fun reject(block: () -> Unit) {
            try {
                block()
                fail()
            } catch (_: IllegalArgumentException) {}
        }
        reject { StorageTopUpCodec.decode(bytes, "aaaaa-aa", quote.network) }
        reject { StorageTopUpCodec.decode(bytes, owner, "c".repeat(64)) }
        reject {
            StorageTopUpRecord(
                quote,
                payment = payment.copy(memo = StorageProvisioning.CREATE_MEMO),
            )
        }
        reject { quote.copy(bucket = "aaaaa-aa") }
        reject {
            StorageTopUpRecord(
                quote,
                payment = payment,
                block = 42uL,
                cmcRequests = listOf(id(2), id(2)),
            )
        }
        reject {
            StorageTopUpRecord(
                quote,
                payment = payment,
                block = 42uL,
                cmcRequests = listOf(id(2)),
                cycles = BigInteger.valueOf(-1),
            )
        }
    }
}
