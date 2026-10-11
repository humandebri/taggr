package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.ic4j.agent.android.ICPAccountIdentifier
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class CreditPurchaseUITest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "credit-purchase-test-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    private fun row(): CreditPurchaseRecord {
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
        return CreditPurchaseRecord(
            CreditPurchaseQuote(
                7,
                1000uL,
                receipt,
                TransferQuote(
                    owner,
                    "b".repeat(64),
                    invoice.account,
                    invoice.amountE8s,
                    10000uL,
                    1000,
                ),
            )
        )
    }

    private fun payment(row: CreditPurchaseRecord) =
        PendingTransfer(row.quote.transfer, ByteArray(32) { 1 }, 123uL, 321uL)

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun storeSurvivesRestartPreservesPaidPurposeAndArchivesBeforeStartingAnother() {
        val initial = row()
        val store = CreditPurchaseStore(context)
        store.create(initial)
        val paid = initial.copy(payment = payment(initial), block = ULong.MAX_VALUE)
        store.update(initial, paid)
        val restored =
            CreditPurchaseStore(context)
                .load(initial.quote.invoice.owner, initial.quote.invoice.network)!!
        assertEquals(ULong.MAX_VALUE, restored.block)
        assertTrue(restored.payment!!.matches(paid.payment!!))
        assertThrows(IllegalArgumentException::class.java) { store.create(row()) }
        assertThrows(IllegalArgumentException::class.java) { store.discardUnpaid(restored) }
        assertThrows(IllegalArgumentException::class.java) {
            store.update(restored, restored.copy(payment = payment(initial).copy(memo = 1uL)))
        }
        val call =
            FinancialCall(
                initial.quote.invoice.owner,
                initial.quote.invoice.canister,
                initial.quote.invoice.network,
                "mint_credits_with_icp",
                ByteArray(32) { 2 },
                "1".toByteArray(),
            )
        val complete =
            restored.copy(
                settlement = call,
                result =
                    initial.quote.invoice.invoice.copy(
                        paid = true,
                        paidE8s = initial.quote.transfer.amount,
                    ),
            )
        store.update(restored, complete)
        store.archive(complete)
        assertNull(store.load(initial.quote.invoice.owner, initial.quote.invoice.network))
        assertEquals(
            ULong.MAX_VALUE,
            store.latestReceipt(initial.quote.invoice.owner, initial.quote.invoice.network)!!.block,
        )
        assertNull(store.latestReceipt("aaaaa-aa", initial.quote.invoice.network))
        assertNull(store.latestReceipt(initial.quote.invoice.owner, "c".repeat(64)))
        store.create(row())
    }

    @Test
    fun confirmationShowsActualAmountFeeOwnerAndRequiresExplicitPayment() {
        var paid = false
        compose.setContent {
            TaggrTheme {
                CreditPurchaseConfirmation(row().quote, "Test network", false, {}) { paid = true }
            }
        }
        compose.onNodeWithText("Wallet owner: 2vxsx-fae").performScrollTo().assertExists()
        compose.onNodeWithText("Payment: 1 ICP").performScrollTo().assertExists()
        compose.onNodeWithText("Fee: 0.0001 ICP").performScrollTo().assertExists()
        compose.onNodeWithText("Total: 1.0001 ICP").performScrollTo().assertExists()
        assertFalse(paid)
        compose.onNodeWithText("Pay and buy credits").performClick()
        assertTrue(paid)
    }

    @Test
    fun uncertainPaymentShowsRecoveryAndNeverOffersAnotherPurchase() {
        val initial = row()
        val pending = initial.copy(payment = payment(initial))
        var checked = false
        compose.setContent {
            TaggrTheme {
                CreditPurchasePanel(
                    CreditPurchaseState(false, pending),
                    false,
                    true,
                    { error("Second purchase prepared") },
                    { checked = true },
                    { error("Uncertain payment discarded") },
                    invoiceReady = false,
                )
            }
        }
        compose.onNodeWithText("Buy credits with ICP").assertDoesNotExist()
        compose.onNodeWithText("Cancel purchase preparation").assertDoesNotExist()
        compose.onNodeWithText("Check / continue credit purchase").performClick()
        assertTrue(checked)
    }

    @Test
    fun failedRecordRestoreOffersReloadAndBlocksAnotherPurchase() {
        var reloaded = false
        compose.setContent {
            TaggrTheme {
                CreditPurchasePanel(
                    CreditPurchaseState(restoring = false, blocked = true),
                    false,
                    true,
                    { error("Purchase prepared before restore") },
                    { reloaded = true },
                    { error("Unreadable record discarded") },
                )
            }
        }
        compose.onNodeWithText("Buy credits with ICP").assertIsNotEnabled()
        compose.onNodeWithText("Reload credit purchase").performClick()
        assertTrue(reloaded)
    }

    @Test
    fun preparedRecordCanBeCancelledButPendingSettlementRemainsDurable() {
        val initial = row()
        val store = CreditPurchaseStore(context)
        store.create(initial)
        store.discardUnpaid(initial)
        assertNull(store.load(initial.quote.invoice.owner, initial.quote.invoice.network))
        store.create(initial)
        val pending =
            initial.copy(
                payment = payment(initial),
                block = 42uL,
                settlement =
                    FinancialCall(
                        initial.quote.invoice.owner,
                        initial.quote.invoice.canister,
                        initial.quote.invoice.network,
                        "mint_credits_with_icp",
                        ByteArray(32) { 2 },
                        "1".toByteArray(),
                    ),
            )
        store.update(initial, pending)
        val restored =
            CreditPurchaseStore(context)
                .load(initial.quote.invoice.owner, initial.quote.invoice.network)!!
        assertTrue(restored.settlement!!.matches(pending.settlement!!))
        assertThrows(IllegalArgumentException::class.java) { store.discardUnpaid(restored) }
        assertThrows(IllegalArgumentException::class.java) { store.archive(restored) }
    }
}
