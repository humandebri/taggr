package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class FinancialTest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "financial-test-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun recordSurvivesReloadRejectsOverwriteAndIsScoped() {
        val call =
            FinancialCall(
                "aaaaa-aa",
                "aaaaa-aa",
                "a".repeat(64),
                "withdraw_rewards",
                ByteArray(32),
                "null".toByteArray(),
            )
        val store = FinancialCallStore(context)
        store.save(call)
        assertTrue(FinancialCallStore(context).load(call.owner, call.network)!!.matches(call))
        assertNull(store.load("2vxsx-fae", call.network))
        assertNull(store.load(call.owner, "b".repeat(64)))
        assertThrows(IllegalArgumentException::class.java) {
            store.save(call.copy(requestId = ByteArray(32) { 1 }))
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.clear(call.copy(requestId = ByteArray(32) { 1 }))
        }
        store.clear(call)
        assertNull(store.load(call.owner, call.network))
    }

    @Test
    fun withdrawalRequiresExplicitConfirmationAndShowsActualRecipient() {
        var confirmed = false
        val quote = WithdrawQuote("aaaaa-aa", 7, "2vxsx-fae", 123000000u, 10000u, "a".repeat(64), 1)
        compose.setContent {
            TaggrTheme {
                WithdrawConfirmation(quote, "aaaaa-aa", "Test network", false, {}) {
                    confirmed = true
                }
            }
        }
        compose.onNodeWithText("You receive: 1.2299 ICP").assertExists()
        compose.onNodeWithText("Recipient: 2vxsx-fae").assertExists()
        compose.onNodeWithText("Test network").assertExists()
        assertFalse(confirmed)
        compose.onNodeWithText("Withdraw", useUnmergedTree = true).performClick()
        assertTrue(confirmed)
    }
}
