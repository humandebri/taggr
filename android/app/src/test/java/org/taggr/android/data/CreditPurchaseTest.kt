package org.taggr.android.data

import kotlinx.coroutines.runBlocking
import org.ic4j.agent.android.ICPAccountIdentifier
import org.junit.Assert.*
import org.junit.Test

class CreditPurchaseTest {
    private fun quote(): CreditPurchaseQuote {
        val owner = "2vxsx-fae"
        val invoice =
            ICPInvoice(
                100000000uL,
                0uL,
                false,
                DraftImages.hex(ICPAccountIdentifier.account("aaaaa-aa", owner)),
            )
        val receipt =
            CreditInvoiceReceipt(
                owner,
                "a".repeat(64),
                "aaaaa-aa",
                invoice,
                ByteArray(32) { 8 },
                1000,
            )
        return CreditPurchaseQuote(
            7,
            1000uL,
            receipt,
            TransferQuote(owner, "b".repeat(64), invoice.account, invoice.amountE8s, 10000uL, 1000),
        )
    }

    private class Backend(private val quote: CreditPurchaseQuote) : CreditPurchaseBackend {
        var paid = 0
        var minted = 0
        var paymentChecks = 0
        var settlementChecks = 0
        var lostPayment = false
        var lostSettlement = false
        var rejectPayment = false
        var rejectSettlement = false
        var unavailablePayment = false
        var unavailableSettlement = false
        var mismatchedResult = false
        var cancellationAt: String? = null
        val cancellation = kotlinx.coroutines.CancellationException("Cancelled purchase")

        override suspend fun validate(row: CreditPurchaseRecord) {}

        override suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit): ULong {
            paid++
            persist(PendingTransfer(quote, ByteArray(32) { 1 }, 123uL, 321uL))
            if (cancellationAt == "payment") throw cancellation
            if (rejectPayment) throw TransferRejected("InsufficientFunds")
            if (lostPayment)
                throw java.io.IOException("unexpected end of stream on https://localhost/")
            return 42uL
        }

        override suspend fun paymentResult(payment: PendingTransfer): ULong? {
            paymentChecks++
            return if (unavailablePayment) null else 42uL
        }

        private fun invoice() =
            quote.invoice.invoice.copy(
                paid = true,
                paidE8s =
                    if (mismatchedResult) quote.transfer.amount + 1uL else quote.transfer.amount,
            )

        override suspend fun settle(persist: (FinancialCall) -> Unit): ICPInvoice {
            minted++
            persist(
                FinancialCall(
                    quote.invoice.owner,
                    quote.invoice.canister,
                    quote.invoice.network,
                    "mint_credits_with_icp",
                    ByteArray(32) { (minted + 1).toByte() },
                    "1".toByteArray(),
                )
            )
            if (cancellationAt == "mint") throw cancellation
            if (rejectSettlement) throw FinancialRejected("Try again later")
            if (lostSettlement) error("Disconnected after mint")
            return invoice()
        }

        override suspend fun settlementResult(call: FinancialCall): ICPInvoice? {
            settlementChecks++
            return if (unavailableSettlement) null else invoice()
        }
    }

    private class Journal(val backend: Backend, initial: CreditPurchaseRecord) {
        var row = initial
        val writes = mutableListOf<CreditPurchaseRecord>()

        suspend fun resume(): CreditPurchaseRecord =
            CreditPurchaseWorkflow(backend).resume(row) { previous, next ->
                assertSame(row, previous)
                row = next
                writes.add(next)
            }
    }

    @Test
    fun paymentAndMintRequestsAreDurableBeforeCompletion() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q)
            val journal = Journal(backend, CreditPurchaseRecord(q))
            val result = journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(1, backend.minted)
            assertEquals(42uL, result.block)
            assertNotNull(result.result)
            assertNull(journal.writes[0].block)
            assertNotNull(journal.writes[0].payment)
            assertNull(journal.writes[2].result)
            assertNotNull(journal.writes[2].settlement)
            journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(1, backend.minted)
        }

    @Test
    fun interruptedPaymentIsCheckedWithoutAnotherTransfer() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { lostPayment = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (e: IllegalStateException) {
                assertTrue(e.message!!.contains("Check / continue credit purchase"))
                assertFalse(e.message!!.contains("unexpected end of stream"))
                assertTrue(e.cause is java.io.IOException)
            }
            assertNotNull(journal.row.payment)
            assertNull(journal.row.block)
            journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(1, backend.paymentChecks)
            assertEquals(1, backend.minted)
        }

    @Test
    fun interruptedMintIsCheckedWithoutAnotherMintOrPayment() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { lostSettlement = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (e: IllegalStateException) {
                assertTrue(e.message!!.contains("credit mint result is unknown"))
                assertTrue(e.message!!.contains("No payment or mint was automatically repeated"))
                assertEquals("Disconnected after mint", e.cause?.message)
            }
            assertNotNull(journal.row.settlement)
            val saved = journal.row.settlement!!.requestId
            journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(1, backend.minted)
            assertEquals(1, backend.settlementChecks)
            assertArrayEquals(saved, journal.row.settlement!!.requestId)
        }

    @Test
    fun cancellationKeepsOriginalExceptionAndDurableRequest() =
        runBlocking<Unit> {
            for (stage in listOf("payment", "mint")) {
                val q = quote()
                val backend = Backend(q).apply { cancellationAt = stage }
                val journal = Journal(backend, CreditPurchaseRecord(q))
                try {
                    journal.resume()
                    fail("Cancellation must propagate")
                } catch (e: kotlinx.coroutines.CancellationException) {
                    assertSame(backend.cancellation, e)
                }
                assertNotNull(journal.row.payment)
                assertNull(journal.row.result)
                assertEquals(1, backend.paid)
                if (stage == "payment") {
                    assertNull(journal.row.block)
                    assertEquals(0, backend.minted)
                } else {
                    assertNotNull(journal.row.settlement)
                    assertEquals(1, backend.minted)
                }
            }
        }

    @Test
    fun certifiedPaymentRejectionNeverStartsMint() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { rejectPayment = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (_: TransferRejected) {}
            assertEquals("InsufficientFunds", journal.row.paymentFailure)
            journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(0, backend.minted)
        }

    @Test
    fun onlyCertifiedMintRejectionAllowsAnExplicitLaterMintAttempt() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { rejectSettlement = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (_: FinancialRejected) {}
            assertNull(journal.row.settlement)
            assertEquals(1, journal.row.rejectedSettlements.size)
            backend.rejectSettlement = false
            journal.resume()
            assertEquals(1, backend.paid)
            assertEquals(2, backend.minted)
            assertFalse(
                journal.row.settlement!!
                    .requestId
                    .contentEquals(journal.row.rejectedSettlements[0].requestId)
            )
        }

    @Test
    fun mismatchedCertifiedInvoiceKeepsPendingRequestForReview() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { mismatchedResult = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (_: IllegalArgumentException) {}
            assertNotNull(journal.row.settlement)
            assertNull(journal.row.result)
            try {
                journal.resume()
                fail()
            } catch (_: IllegalArgumentException) {}
            assertEquals(1, backend.paid)
            assertEquals(1, backend.minted)
        }

    @Test
    fun durableCodecPreservesPaidBlockAndSettlementArgumentsAndRejectsOtherScope() =
        runBlocking<Unit> {
            val q = quote()
            val backend = Backend(q).apply { lostSettlement = true }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (_: IllegalStateException) {}
            val row = journal.row.copy(block = ULong.MAX_VALUE)
            val bytes = CreditPurchaseCodec.encode(row)
            val restored = CreditPurchaseCodec.decode(bytes, q.invoice.owner, q.invoice.network)
            assertEquals(ULong.MAX_VALUE, restored.block)
            assertTrue(row.payment!!.matches(restored.payment!!))
            assertTrue(row.settlement!!.matches(restored.settlement!!))
            assertThrows(IllegalArgumentException::class.java) {
                CreditPurchaseCodec.decode(bytes, "aaaaa-aa", q.invoice.network)
            }
            assertThrows(IllegalArgumentException::class.java) {
                CreditPurchaseCodec.decode(bytes, q.invoice.owner, "c".repeat(64))
            }
        }

    @Test
    fun unavailableRequestStatusRetainsExactPaymentAndMintInsteadOfRetrying() =
        runBlocking<Unit> {
            val q = quote()
            val backend =
                Backend(q).apply {
                    lostPayment = true
                    unavailablePayment = true
                }
            val journal = Journal(backend, CreditPurchaseRecord(q))
            try {
                journal.resume()
                fail()
            } catch (_: IllegalStateException) {}
            val payment = CreditPurchaseCodec.encode(journal.row)
            repeat(2) {
                try {
                    journal.resume()
                    fail()
                } catch (_: IllegalStateException) {}
                assertArrayEquals(payment, CreditPurchaseCodec.encode(journal.row))
            }
            assertEquals(1, backend.paid)
            assertEquals(0, backend.minted)
            backend.unavailablePayment = false
            backend.lostSettlement = true
            backend.unavailableSettlement = true
            try {
                journal.resume()
                fail()
            } catch (_: IllegalStateException) {}
            val mint = CreditPurchaseCodec.encode(journal.row)
            repeat(2) {
                try {
                    journal.resume()
                    fail()
                } catch (_: IllegalStateException) {}
                assertArrayEquals(mint, CreditPurchaseCodec.encode(journal.row))
            }
            assertEquals(1, backend.paid)
            assertEquals(1, backend.minted)
        }

    @Test
    fun approvalCannotChangeInvoiceAmountRecipientOrPreparationAge() {
        val q = quote()
        assertThrows(IllegalArgumentException::class.java) {
            q.copy(transfer = q.transfer.copy(amount = 1uL))
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.copy(
                transfer =
                    q.transfer.copy(
                        recipient =
                            DraftImages.hex(ICPAccountIdentifier.defaultAccount("2vxsx-fae"))
                    )
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.copy(transfer = q.transfer.copy(preparedAtMillis = 121001))
        }
    }
}
