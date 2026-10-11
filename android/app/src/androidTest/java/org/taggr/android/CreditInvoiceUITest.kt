package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.*
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
class CreditInvoiceUITest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "credit-invoice-test-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    private fun receipt(paid: Boolean) =
        CreditInvoiceReceipt(
            "2vxsx-fae",
            "a".repeat(64),
            "aaaaa-aa",
            ICPInvoice(
                100000000uL,
                if (paid) 100000000uL else 0uL,
                paid,
                DraftImages.hex(ICPAccountIdentifier.account("aaaaa-aa", "2vxsx-fae")),
            ),
            ByteArray(32),
            1000,
        )

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun certifiedReceiptSurvivesPendingRecordClearAndScopeChange() {
        val value = receipt(true)
        val call =
            FinancialCall(
                value.owner,
                value.canister,
                value.network,
                "mint_credits_with_icp",
                value.requestId,
                "0".toByteArray(),
            )
        val pending = FinancialCallStore(context)
        pending.save(call)
        CreditInvoiceStore(context).save(value)
        pending.clear(call)
        assertNull(pending.load(value.owner, value.network))
        val store = CreditInvoiceStore(context)
        assertEquals(
            value.invoice,
            store.load(value.owner, value.network, value.canister)!!.invoice,
        )
        assertNull(store.load("aaaaa-aa", value.network, value.canister))
        assertNull(store.load(value.owner, "b".repeat(64), value.canister))
        assertThrows(IllegalArgumentException::class.java) {
            store.load(value.owner, value.network, "2vxsx-fae")
        }
    }

    @Test
    fun unpaidInvoiceCanBeCheckedAndPaidReceiptRemainsVisible() {
        var checked = false
        val state = mutableStateOf(CreditInvoiceState(false, receipt(false)))
        compose.setContent {
            TaggrTheme { CreditInvoicePanel(state.value, true) { checked = true } }
        }
        compose.onNodeWithText("Awaiting payment").assertExists()
        compose.onNodeWithText("Check credit invoice").performClick()
        compose.runOnIdle {
            assertTrue(checked)
            state.value = CreditInvoiceState(false, receipt(true))
        }
        compose.onNodeWithText("Payment confirmed: 1 ICP").assertExists()
        compose.onNodeWithText("Awaiting payment").assertDoesNotExist()
    }

    @Test
    fun pendingOperationsAndFailedRestorationPreventNewInvoiceRequests() {
        val state = mutableStateOf(CreditInvoiceState(false))
        compose.setContent {
            TaggrTheme { CreditInvoicePanel(state.value, false) { error("Request dispatched") } }
        }
        compose.onNodeWithText("Prepare credit invoice").assertIsNotEnabled()
        compose.runOnIdle { state.value = CreditInvoiceState(false, blocked = true) }
        compose.onNodeWithText("Prepare credit invoice").assertIsNotEnabled()
    }
}
