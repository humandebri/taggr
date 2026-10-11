package org.taggr.android.data

import java.math.BigInteger
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class StorageCreationWorkflowTest {
    private val owner = "2vxsx-fae"
    private val bucket = "r7inp-6aaaa-aaaaa-aaabq-cai"
    private val bytes = byteArrayOf(0, 0x61, 0x73, 0x6d, 1, 0, 0, 0)
    private val hash = DraftImages.hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private val quote =
        StorageCreationQuote(
            7,
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "a".repeat(64),
            TransferQuote(
                owner,
                "b".repeat(64),
                DraftImages.hex(StorageProvisioning.creationAccount(owner)),
                100_000uL,
                10_000uL,
                1000,
            ),
            hash,
        )

    private fun id(n: Int) = ByteArray(32) { n.toByte() }

    private inner class Backend : StorageCreationBackend {
        var funds = 0
        var creates = 0
        var installs = 0
        var registrations = 0
        var rejectPayment = false
        var cmcFailure: CMCFailure? = null
        var failPayment = false
        var failCreate = false
        var failInstall = false
        var paymentKnown = true
        var retryInstall = false
        var installedHash: String? = null
        var cancellationAt: String? = null
        val cancellation = kotlinx.coroutines.CancellationException("Cancelled creation")
        val blocks = mutableListOf<ULong>()

        override suspend fun validateAccount(row: StorageCreationRecord) {}

        override suspend fun fund(
            row: StorageCreationRecord,
            persist: (StorageCreationRecord) -> Unit,
        ): ULong {
            funds++
            persist(
                row.withPayment(
                    PendingTransfer(quote.transfer, id(1), 123uL, StorageProvisioning.CREATE_MEMO)
                )
            )
            if (cancellationAt == "payment") throw cancellation
            if (rejectPayment) throw TransferRejected("Insufficient funds")
            if (failPayment) throw java.io.IOException("unexpected end of stream after payment")
            return 42uL
        }

        override suspend fun paymentResult(payment: PendingTransfer): ULong? =
            if (paymentKnown) 42uL else null

        override suspend fun create(
            row: StorageCreationRecord,
            persist: (ByteArray) -> Unit,
        ): String {
            blocks += row.block!!
            creates++
            persist(id(2 + creates))
            if (cancellationAt == "create") throw cancellation
            cmcFailure?.let { throw it }
            if (failCreate) throw java.io.IOException("unexpected end of stream after CMC")
            return bucket
        }

        override suspend fun status(bucket: String) =
            StorageStatus(
                bucket,
                "running",
                listOf(owner),
                installedHash,
                BigInteger.ZERO,
                BigInteger.TEN,
                BigInteger.ZERO,
                hash,
            )

        override suspend fun installCanRetry(row: StorageCreationRecord) = retryInstall

        override suspend fun module() = VerifiedStorageWasm.verify(bytes, hash)

        override suspend fun install(
            bucket: String,
            wasm: VerifiedStorageWasm,
            persist: (ByteArray) -> Unit,
        ) {
            installs++
            persist(id(10 + installs))
            if (failInstall) error("Disconnected after install dispatch")
            installedHash = wasm.hash
        }

        override suspend fun register(row: StorageCreationRecord, persist: (ByteArray) -> Unit) {
            registrations++
            persist(id(20))
        }
    }

    @Test
    fun cancellationKeepsSavedPaymentOrCreationRequest() = runBlocking {
        for (stage in listOf("payment", "create")) {
            val backend = Backend().apply { cancellationAt = stage }
            var saved = StorageCreationRecord(quote)
            try {
                StorageCreationWorkflow(backend).resume(saved) { _, next -> saved = next }
                fail("Cancellation must propagate")
            } catch (e: kotlinx.coroutines.CancellationException) {
                assertSame(backend.cancellation, e)
            }
            assertNotNull(saved.payment)
            assertNull(saved.bucket)
            assertEquals(1, backend.funds)
            assertEquals(0, backend.installs)
            assertEquals(0, backend.registrations)
            if (stage == "payment") {
                assertEquals(StorageCreationPhase.PAYMENT_PENDING, saved.phase)
                assertEquals(0, backend.creates)
            } else {
                assertEquals(StorageCreationPhase.CREATING, saved.phase)
                assertEquals(42uL, saved.block)
                assertEquals(1, saved.cmcRequests.size)
            }
        }
    }

    @Test
    fun interruptedPaymentAndCreateResumeFromSameReceiptWithoutRepaying() = runBlocking {
        val backend = Backend().apply { failPayment = true }
        val workflow = StorageCreationWorkflow(backend)
        var saved = StorageCreationRecord(quote)
        suspend fun resume() {
            workflow.resume(saved) { old, next ->
                assertEquals(saved.phase, old.phase)
                saved = next
            }
        }
        try {
            resume()
            fail("Expected interruption")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Use Check and continue"))
            assertFalse(e.message!!.contains("unexpected end of stream"))
            assertTrue(e.cause is java.io.IOException)
        }
        assertEquals(StorageCreationPhase.PAYMENT_PENDING, saved.phase)
        backend.failPayment = false
        backend.paymentKnown = false
        try {
            resume()
            fail("Unknown payment must stop")
        } catch (_: IllegalStateException) {}
        assertEquals(0, backend.creates)
        backend.paymentKnown = true
        backend.failCreate = true
        try {
            resume()
            fail("Expected CMC interruption")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("canister creation result is unknown"))
            assertTrue(e.message!!.contains("No new ICP payment will be sent"))
            assertTrue(e.cause is java.io.IOException)
        }
        assertEquals(StorageCreationPhase.CREATING, saved.phase)
        backend.failCreate = false
        resume()
        assertEquals(StorageCreationPhase.COMPLETE, saved.phase)
        assertEquals(1, backend.funds)
        assertEquals(listOf(42uL, 42uL), backend.blocks)
        assertEquals(1, backend.installs)
        assertEquals(1, backend.registrations)
    }

    @Test
    fun uncertainInstallStopsUntilStatusProvesApprovedCode() = runBlocking {
        val backend = Backend().apply { failInstall = true }
        val workflow = StorageCreationWorkflow(backend)
        var saved = StorageCreationRecord(quote)
        suspend fun resume() {
            workflow.resume(saved) { _, next -> saved = next }
        }
        try {
            resume()
            fail("Expected interruption")
        } catch (_: IllegalStateException) {}
        assertEquals(StorageCreationPhase.INSTALLING, saved.phase)
        backend.failInstall = false
        try {
            resume()
            fail("Unknown installation must not be resent")
        } catch (_: IllegalArgumentException) {}
        assertEquals(1, backend.installs)
        backend.installedHash = "d".repeat(64)
        try {
            resume()
            fail("Different code must not be overwritten")
        } catch (_: IllegalArgumentException) {}
        assertEquals(0, backend.registrations)
        backend.installedHash = hash
        resume()
        assertEquals(StorageCreationPhase.COMPLETE, saved.phase)
        assertEquals(1, backend.installs)
        assertEquals(1, backend.funds)
    }

    @Test
    fun certifiedPaymentRejectionIsDurableAndCannotResume() = runBlocking {
        val backend = Backend().apply { rejectPayment = true }
        val workflow = StorageCreationWorkflow(backend)
        var saved = StorageCreationRecord(quote)
        try {
            workflow.resume(saved) { _, next -> saved = next }
            fail("Expected rejection")
        } catch (_: TransferRejected) {}
        assertEquals(StorageCreationFailureKind.PAYMENT_REJECTED, saved.failure!!.kind)
        assertEquals(StorageCreationPhase.FAILED, saved.phase)
        val restored =
            StorageCreationCodec.decode(
                StorageCreationCodec.encode(saved),
                quote.transfer.owner,
                quote.network,
            )
        assertEquals(saved.failure, restored.failure)
        try {
            workflow.resume(restored) { _, _ -> fail("Failure must be immutable") }
            fail("Expected explicit review")
        } catch (_: IllegalArgumentException) {}
        assertEquals(1, backend.funds)
        assertEquals(0, backend.creates)
    }

    @Test
    fun cmcProcessingStaysPendingWhileRefundRetainsOriginalAndRefundBlocks() = runBlocking {
        val backend =
            Backend().apply { cmcFailure = CMCFailure("Processing", "Still processing", true) }
        val workflow = StorageCreationWorkflow(backend)
        var saved = StorageCreationRecord(quote)
        try {
            workflow.resume(saved) { _, next -> saved = next }
            fail("Expected processing")
        } catch (_: CMCFailure) {}
        assertNull(saved.failure)
        assertEquals(StorageCreationPhase.CREATING, saved.phase)
        backend.cmcFailure =
            CMCFailure("Refunded", "Creation refused", refundBlock = ULong.MAX_VALUE)
        try {
            workflow.resume(saved) { _, next -> saved = next }
            fail("Expected refund")
        } catch (_: CMCFailure) {}
        val restored =
            StorageCreationCodec.decode(
                StorageCreationCodec.encode(saved),
                quote.transfer.owner,
                quote.network,
            )
        assertEquals(StorageCreationFailureKind.CMC_REFUNDED, restored.failure!!.kind)
        assertEquals(ULong.MAX_VALUE, restored.failure.refundBlock)
        assertEquals(42uL, restored.block)
        assertEquals(1, backend.funds)
        assertEquals(0, backend.installs)
        assertEquals(listOf(42uL, 42uL), backend.blocks)
        val withoutBlock = restored.copy(failure = restored.failure.copy(refundBlock = null))
        assertNull(
            StorageCreationCodec.decode(
                    StorageCreationCodec.encode(withoutBlock),
                    quote.transfer.owner,
                    quote.network,
                )
                .failure!!
                .refundBlock
        )
    }
}
