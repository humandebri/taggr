package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.mutableStateOf
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
class RealmMembershipUITest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "realm-membership-${UUID.randomUUID()}",
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
    fun buttonsRequestExplicitDesiredStateRatherThanAnUnconditionalToggle() {
        val joined = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                RealmMembershipControls(
                    true,
                    joined.value,
                    false,
                    true,
                    false,
                    false,
                    {
                        requests.add(it)
                        joined.value = it
                    },
                    {},
                    name = "TEST",
                    cleanupPenalty = 25uL,
                )
            }
        }
        compose.onNodeWithText("Join realm").performClick()
        compose.runOnIdle { assertTrue(requests.isEmpty()) }
        compose.onNodeWithText("Agree and Join").performClick()
        compose.onNodeWithText("Leave realm").performClick()
        compose.runOnIdle { assertEquals(listOf(true), requests) }
        compose.onNodeWithText("Leave Realm").performClick()
        compose.runOnIdle { assertEquals(listOf(true, false), requests) }
    }

    @Test
    fun consentFreezesDisplayedPenaltyAndCallbackAndCancelDoesNotJoin() {
        val currentPenalty = mutableStateOf(25uL)
        val approvals = mutableListOf<ULong>()
        compose.setContent {
            val penalty = currentPenalty.value
            TaggrTheme {
                RealmMembershipControls(
                    true,
                    false,
                    false,
                    true,
                    false,
                    false,
                    { approvals.add(penalty) },
                    {},
                    name = "TEST",
                    cleanupPenalty = penalty,
                )
            }
        }
        compose.onNodeWithText("Join realm").performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertTrue(approvals.isEmpty()) }
        compose.onNodeWithText("Join realm").performClick()
        compose.runOnIdle { currentPenalty.value = 99uL }
        compose
            .onNodeWithText(
                "By joining, you agree to the Realm description and rules. Rule violations may remove a post and charge up to 25 credits and reward points."
            )
            .assertIsDisplayed()
        compose.onNodeWithText("Agree and Join").performClick()
        compose.runOnIdle { assertEquals(listOf(25uL), approvals) }
    }

    @Test
    fun unknownResultAndUnreadableRecordBlockAnotherToggleButAllowLookup() {
        val blocked = mutableStateOf(false)
        var checks = 0
        compose.setContent {
            TaggrTheme {
                RealmMembershipControls(
                    true,
                    false,
                    false,
                    false,
                    !blocked.value,
                    blocked.value,
                    { error("Second toggle dispatched") },
                    { checks++ },
                )
            }
        }
        compose.onNodeWithText("Join realm").assertIsNotEnabled()
        compose.onNodeWithText("Check membership result").performClick()
        compose.runOnIdle { blocked.value = true }
        compose.onNodeWithText("Join realm").assertIsNotEnabled()
        compose.onNodeWithText("Check membership result").performClick()
        compose.runOnIdle { assertEquals(2, checks) }
    }

    @Test
    fun originalMembershipRequestSurvivesReloadWithScopeAndOverwriteProtection() {
        val call =
            FinancialCall(
                "2vxsx-fae",
                "aaaaa-aa",
                "b".repeat(64),
                "toggle_realm_membership",
                ByteArray(32) { it.toByte() },
                RealmMembership.arguments("TEST"),
            )
        FinancialCallStore(context).save(call)
        val restored = FinancialCallStore(context).load(call.owner, call.network)!!
        assertTrue(call.matches(restored))
        assertNull(FinancialCallStore(context).load("aaaaa-aa", call.network))
        assertNull(FinancialCallStore(context).load(call.owner, "c".repeat(64)))
        assertThrows(IllegalArgumentException::class.java) {
            FinancialCallStore(context).save(call.copy(requestId = ByteArray(32) { 9 }))
        }
        assertThrows(IllegalArgumentException::class.java) {
            FinancialCallStore(context).clear(call.copy(requestId = ByteArray(32) { 9 }))
        }
        assertTrue(call.matches(FinancialCallStore(context).load(call.owner, call.network)!!))
        FinancialCallStore(context).clear(restored)
        assertNull(FinancialCallStore(context).load(call.owner, call.network))
    }
}
