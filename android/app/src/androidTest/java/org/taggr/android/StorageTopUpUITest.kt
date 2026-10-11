package org.taggr.android

import android.content.ContextWrapper
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.math.BigInteger
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class StorageTopUpUITest {
    @get:Rule val compose = createComposeRule()
    private val quote =
        StorageTopUpQuote(
            7,
            "r7inp-6aaaa-aaaaa-aaabq-cai",
            "a".repeat(64),
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            TransferQuote(
                "2vxsx-fae",
                "b".repeat(64),
                DraftImages.hex(StorageProvisioning.topUpAccount("rrkah-fqaaa-aaaaa-aaaaq-cai")),
                1000000uL,
                10000uL,
                1000,
            ),
        )

    @Test
    fun approvalShowsTargetSignerAmountFeeAndPreventsBusySubmission() {
        var confirmed = false
        var cancelled = false
        val busy = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                StorageTopUpConfirmation(quote, "Test network", busy.value, { cancelled = true }) {
                    confirmed = true
                }
            }
        }
        compose.onNodeWithText("Storage: ${quote.bucket}").assertExists()
        compose.onNodeWithText("Signed by: 2vxsx-fae").assertExists()
        compose.onNodeWithText("Amount: 0.01 ICP").assertExists()
        compose.onNodeWithText("Ledger fee: 0.0001 ICP").assertExists()
        compose.onNodeWithText("Total: 0.0101 ICP").assertExists()
        assertFalse(confirmed)
        compose.runOnIdle { busy.value = true }
        compose.onNodeWithText("Top up").assertIsNotEnabled().performClick()
        assertFalse(confirmed)
        compose.runOnIdle { busy.value = false }
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(cancelled)
        assertFalse(confirmed)
        compose.onNodeWithText("Top up").performClick()
        assertTrue(confirmed)
    }

    @Test
    fun unknownRefundDoesNotClaimFullAmountWasReturned() {
        val row =
            StorageTopUpRecord(
                quote,
                payment =
                    PendingTransfer(
                        quote.transfer,
                        ByteArray(32) { 1 },
                        123uL,
                        StorageProvisioning.TOP_UP_MEMO,
                    ),
                block = 42uL,
                cmcRequests = listOf(ByteArray(32) { 2 }),
                failure = StorageTopUpFailure("Refunded", "Confirmed CMC refund"),
            )
        compose.setContent { TaggrTheme { Column { StorageTopUpDetails(row) } } }
        compose.onNodeWithText("Payment block: 42").assertExists()
        compose
            .onNodeWithText(
                "No refund block was returned. The refunded amount has not been verified."
            )
            .assertExists()
        compose
            .onNodeWithText(
                "A processing fee may have been deducted. Check the refund before another payment."
            )
            .assertExists()
        compose.onNodeWithText("Cycles added:", substring = true).assertDoesNotExist()
    }

    @Test
    fun atomicStoreRestoresBlocksStopsStaleUpdatesAndRetainsReceipt() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(base.cacheDir, "topup-test-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val context =
            object : ContextWrapper(base) {
                override fun getNoBackupFilesDir() = root
            }
        fun reject(block: () -> Unit) {
            try {
                block()
                fail("Expected rejected state mutation")
            } catch (_: IllegalArgumentException) {}
        }
        try {
            val first = StorageTopUpRecord(quote)
            var store = StorageTopUpStore(context)
            store.create(first)
            val paid =
                first.copy(
                    payment =
                        PendingTransfer(
                            quote.transfer,
                            ByteArray(32) { 1 },
                            123uL,
                            StorageProvisioning.TOP_UP_MEMO,
                        )
                )
            store.update(first, paid)
            store = StorageTopUpStore(context)
            assertArrayEquals(
                StorageTopUpCodec.encode(paid),
                StorageTopUpCodec.encode(store.load(quote.transfer.owner, quote.network)!!),
            )
            reject { store.create(first) }
            reject { store.discardUnpaid(paid) }
            reject { store.update(first, paid) }
            val notified =
                paid.copy(block = ULong.MAX_VALUE, cmcRequests = listOf(ByteArray(32) { 2 }))
            store.update(paid, notified)
            val completed = notified.copy(cycles = BigInteger("184467440737095516160000"))
            store.update(notified, completed)
            reject { store.update(completed, notified) }
            reject { store.acknowledge(notified) }
            store.acknowledge(completed)
            store = StorageTopUpStore(context)
            assertNull(store.load(quote.transfer.owner, quote.network))
            assertArrayEquals(
                StorageTopUpCodec.encode(completed),
                StorageTopUpCodec.encode(
                    store.latestReceipt(quote.transfer.owner, quote.network)!!
                ),
            )
            store.create(first)
            store.discardUnpaid(first)
            assertNull(store.load(quote.transfer.owner, quote.network))
        } finally {
            check(root.deleteRecursively())
        }
    }
}
