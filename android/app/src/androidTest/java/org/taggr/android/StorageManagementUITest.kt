package org.taggr.android

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class StorageManagementUITest {
    @get:Rule val compose = createComposeRule()
    private val status =
        StorageStatus(
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "running",
            listOf("2vxsx-fae"),
            "a".repeat(64),
            BigInteger.TEN,
            BigInteger.TEN,
            BigInteger.ONE,
            "b".repeat(64),
        )

    @Test
    fun upgradeApprovalShowsTargetSignerAndBothHashesBeforeDispatch() {
        var confirmed = false
        val busy = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                StorageManagementConfirmation(
                    StorageManagementQuote(
                        StorageManagementAction.UPGRADE,
                        "2vxsx-fae",
                        7,
                        status,
                        1,
                    ),
                    "aaaaa-aa",
                    "Test network",
                    busy.value,
                    {},
                ) {
                    confirmed = true
                }
            }
        }
        compose.onNodeWithText("Storage: ${status.bucket}").assertExists()
        compose.onNodeWithText("Signed by: 2vxsx-fae").assertExists()
        compose.onNodeWithText("Current module: ${status.moduleHash}").assertExists()
        compose.onNodeWithText("Approved module: ${status.expectedHash}").assertExists()
        assertFalse(confirmed)
        compose.runOnIdle { busy.value = true }
        compose.onNodeWithText("Upgrade").assertIsNotEnabled().performClick()
        assertFalse(confirmed)
        compose.runOnIdle { busy.value = false }
        compose.onNodeWithText("Upgrade").performClick()
        assertTrue(confirmed)
    }

    @Test
    fun grantApprovalRetainsOwnerAndCancelNeverChangesControllers() {
        var confirmed = false
        var cancelled = false
        compose.setContent {
            TaggrTheme {
                StorageManagementConfirmation(
                    StorageManagementQuote(
                        StorageManagementAction.ADD_BLACKHOLE,
                        "2vxsx-fae",
                        7,
                        status.copy(moduleHash = status.expectedHash),
                        1,
                    ),
                    "aaaaa-aa",
                    "Test network",
                    false,
                    { cancelled = true },
                ) {
                    confirmed = true
                }
            }
        }
        compose.onNodeWithText("New controller: ${StorageProvisioning.BLACKHOLE}").assertExists()
        compose.onNodeWithText("Existing controllers:").assertExists()
        compose.onNodeWithText("2vxsx-fae").assertExists()
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(cancelled)
        assertFalse(confirmed)
    }

    @Test
    fun obsoleteCodeAndPendingActionsPreventControllerGrant() {
        var selected: StorageManagementAction? = null
        val ready = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                androidx.compose.foundation.layout.Column {
                    StorageManagementControls(status, "2vxsx-fae", ready.value) { selected = it }
                }
            }
        }
        compose.onNodeWithText("Add Blackhole controller").assertIsNotEnabled().performClick()
        compose.onNodeWithText("Upgrade storage").assertIsNotEnabled().performClick()
        assertNull(selected)
        compose.runOnIdle { ready.value = true }
        compose.onNodeWithText("Add Blackhole controller").assertIsNotEnabled()
        compose.onNodeWithText("Upgrade storage").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(StorageManagementAction.UPGRADE, selected) }
    }
}
