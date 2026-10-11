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
class AccountRetirementUITest {
    @get:Rule val compose = createComposeRule()
    private val quote = RetirementQuote("2vxsx-fae", "a".repeat(64), 7, 100uL, 1000)
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "retirement-test-${UUID.randomUUID()}",
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
    fun typedConfirmationIsExactAndRequiresASecondExplicitDecision() {
        var retired = false
        compose.setContent {
            TaggrTheme { RetirementConfirmation(quote, false, {}) { retired = true } }
        }
        compose.onNodeWithText("Continue").assertIsNotEnabled()
        compose
            .onNodeWithText("Type delete to continue")
            .performScrollTo()
            .performTextInput("Delete")
        compose.onNodeWithText("Continue").assertIsNotEnabled()
        compose.onNodeWithText("Type delete to continue").performTextReplacement("delete")
        compose.onNodeWithText("Continue").performClick()
        assertFalse(retired)
        compose.onNodeWithText("Cost: 100 credits").performScrollTo().assertExists()
        compose.onNodeWithText("Yes, delete account").performClick()
        assertTrue(retired)
    }

    @Test
    fun cancelDoesNotExecuteDeletion() {
        var cancelled = false
        compose.setContent {
            TaggrTheme {
                RetirementConfirmation(quote, false, { cancelled = true }) {
                    error("Deletion dispatched")
                }
            }
        }
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(cancelled)
    }

    @Test
    fun unknownStopSurvivesRestartIsScopedAndCannotBeOverwritten() {
        val store = RetirementStore(context)
        val initial = RetirementRecord(quote)
        store.create(initial)
        val unknown =
            initial.copy(stage = RetirementStage.STOP_PENDING, requestId = ByteArray(32) { 3 })
        store.update(initial, unknown)
        val restored = RetirementStore(context).load(quote.owner, quote.network)!!
        assertArrayEquals(unknown.requestId, restored.requestId)
        assertEquals(RetirementStage.STOP_PENDING, restored.stage)
        assertNull(store.load("aaaaa-aa", quote.network))
        assertNull(store.load(quote.owner, "b".repeat(64)))
        assertThrows(IllegalArgumentException::class.java) { store.create(initial) }
        assertThrows(IllegalArgumentException::class.java) {
            store.reapprove(restored, quote.copy(preparedAtMillis = 2000))
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.update(restored, restored.copy(requestId = ByteArray(32) { 4 }))
        }
        val cleanup = restored.copy(stage = RetirementStage.CLEANUP)
        store.update(restored, cleanup)
        assertEquals(
            RetirementStage.CLEANUP,
            RetirementStore(context).load(quote.owner, quote.network)!!.stage,
        )
        assertThrows(IllegalArgumentException::class.java) { store.update(cleanup, unknown) }
    }

    @Test
    fun rejectedPreparationNeedsFreshApprovalWhilePreservingPriorRequestID() {
        val store = RetirementStore(context)
        val initial = RetirementRecord(quote)
        store.create(initial)
        val request =
            initial.copy(stage = RetirementStage.STOP_PENDING, requestId = ByteArray(32) { 3 })
        store.update(initial, request)
        val rejected = request.copy(stage = RetirementStage.PREPARING)
        store.update(request, rejected)
        val approved = store.reapprove(rejected, quote.copy(cost = 200uL, preparedAtMillis = 2000))
        assertEquals(200uL, approved.quote.cost)
        assertArrayEquals(request.requestId, approved.requestId)
        val fresh =
            approved.copy(stage = RetirementStage.STOP_PENDING, requestId = ByteArray(32) { 4 })
        store.update(approved, fresh)
        assertArrayEquals(fresh.requestId, store.load(quote.owner, quote.network)!!.requestId)
    }
}
