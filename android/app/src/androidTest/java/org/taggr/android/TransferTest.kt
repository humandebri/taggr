package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import java.util.zip.CRC32
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class TransferTest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "transfer-test-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    private val address =
        ByteArray(32)
            .also { bytes ->
                ByteBuffer.allocate(4)
                    .putInt(CRC32().apply { update(bytes, 4, 28) }.value.toInt())
                    .array()
                    .copyInto(bytes)
            }
            .let { DraftImages.hex(it) }

    private fun quote() = TransferQuote("2vxsx-fae", "a".repeat(64), address, 123000000u, 10000u, 1)

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun replayIdsAreDurableAndOldSnapshotsCannotClearNewAttempts() {
        val pending = PendingTransfer(quote(), ByteArray(32), 123u, 1u)
        val store = PendingTransferStore(context)
        store.save(pending)
        val updated = store.appendReplay(pending, ByteArray(32) { 1 })
        val restored =
            PendingTransferStore(context).load(pending.quote.owner, pending.quote.network)!!
        assertTrue(restored.matches(updated))
        assertEquals(2, restored.allRequestIds.size)
        assertArrayEquals(pending.arguments(), restored.arguments())
        assertThrows(IllegalArgumentException::class.java) { store.clear(pending) }
        assertThrows(IllegalArgumentException::class.java) {
            store.appendReplay(pending, ByteArray(32) { 2 })
        }
        store.clear(restored)
    }

    @Test
    fun concurrentStoreInstancesCannotOverwriteThePendingPayment() {
        val pending = PendingTransfer(quote(), ByteArray(32), 123u, 1u)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        val start = java.util.concurrent.CountDownLatch(1)
        try {
            val futures =
                (0..1).map { n ->
                    pool.submit<Boolean> {
                        start.await()
                        try {
                            PendingTransferStore(context)
                                .save(pending.copy(requestId = ByteArray(32) { n.toByte() }))
                            true
                        } catch (_: IllegalArgumentException) {
                            false
                        }
                    }
                }
            start.countDown()
            assertEquals(1, futures.count { it.get(5, java.util.concurrent.TimeUnit.SECONDS) })
            assertNotNull(
                PendingTransferStore(context).load(pending.quote.owner, pending.quote.network)
            )
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun replayConfirmationNeedsExplicitRetryAndShowsOriginalMemo() {
        val pending = PendingTransfer(quote(), ByteArray(32), 123000000000u, 765u)
        var retries = 0
        compose.setContent {
            TaggrTheme { ReplayConfirmation(pending, "Test network", false, {}, { retries++ }) }
        }
        compose.onNodeWithText("Original memo: 765").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("To: $address").performScrollTo().assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, retries) }
        compose.onNodeWithText("Retry same transfer", substring = false).performClick()
        compose.runOnIdle { assertEquals(1, retries) }
    }

    @Test
    fun pendingRequestSurvivesNewStoreAndDoesNotCrossOwnerOrNetwork() {
        val pending =
            PendingTransfer(quote(), ByteArray(32) { it.toByte() }, 123456789012345u, 765u)
        val store = PendingTransferStore(context)
        store.save(pending)
        val restored =
            PendingTransferStore(context).load(pending.quote.owner, pending.quote.network)!!
        assertArrayEquals(pending.requestId, restored.requestId)
        assertEquals(pending.createdAtNanos, restored.createdAtNanos)
        assertEquals(pending.memo, restored.memo)
        assertEquals(pending.quote, restored.quote)
        assertNull(store.load("aaaaa-aa", pending.quote.network))
        assertNull(store.load(pending.quote.owner, "b".repeat(64)))
        assertThrows(IllegalArgumentException::class.java) {
            store.save(pending.copy(requestId = ByteArray(32) { 1 }))
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.clear(pending.copy(requestId = ByteArray(32) { 1 }))
        }
        store.clear(pending)
        assertNull(store.load(pending.quote.owner, pending.quote.network))
    }

    @Test
    fun legacyAtomicBackupIsRecoveredInsteadOfTreatingPaymentAsMissing() {
        val pending = PendingTransfer(quote(), ByteArray(32), 123u, 1u)
        val store = PendingTransferStore(context)
        store.save(pending)
        val file = File(directory, "taggr-pending-transfers").listFiles()!!.single()
        assertTrue(file.renameTo(File(file.path + ".bak")))
        assertNotNull(
            PendingTransferStore(context).load(pending.quote.owner, pending.quote.network)
        )
    }

    @Test
    fun corruptPendingRecordIsNotTreatedAsAnAbsentPayment() {
        val pending = PendingTransfer(quote(), ByteArray(32), 123u, 1u)
        val store = PendingTransferStore(context)
        store.save(pending)
        val file = File(directory, "taggr-pending-transfers").listFiles()!!.single()
        file.writeText("broken JSON")
        assertThrows(Exception::class.java) {
            store.load(pending.quote.owner, pending.quote.network)
        }
        assertTrue(file.exists())
    }

    @Test
    fun confirmationShowsExactPaymentAndDoesNotSendUntilPressed() {
        var sent = 0
        compose.setContent {
            TaggrTheme { TransferConfirmation(quote(), "Test network", false, {}, { sent++ }) }
        }
        compose.onNodeWithText("Amount: 1.23 ICP").assertIsDisplayed()
        compose.onNodeWithText("Fee: 0.0001 ICP").assertIsDisplayed()
        compose.onNodeWithText("Network: Test network").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("To: $address").performScrollTo().assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, sent) }
        compose.onNodeWithText("Send", substring = false).performClick()
        compose.runOnIdle { assertEquals(1, sent) }
    }
}
