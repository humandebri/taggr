package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme
import org.taggr.android.ui.UserBlockControl

@RunWith(AndroidJUnit4::class)
class UserBlockUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun confirmationCancelBusyAndUnblockPreserveTheRequestedChoice() {
        val blocked = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                UserBlockControl(8, "Alice", 7, "owner", blocked.value, busy.value) {
                    requests.add(it)
                    blocked.value = it
                    busy.value = true
                }
            }
        }
        compose.onNodeWithText("Block").performClick()
        compose.onNodeWithText("Block Alice?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(requests.isEmpty())
        compose.onNodeWithText("Block").performClick()
        compose.onAllNodesWithText("Block")[1].performClick()
        compose.onNodeWithText("Unblock").assertIsNotEnabled()
        compose.runOnIdle {
            assertEquals(listOf(true), requests)
            busy.value = false
        }
        compose.onNodeWithText("Unblock").performClick()
        compose.onNodeWithText("Unblock Alice?").assertIsDisplayed()
        compose.onAllNodesWithText("Unblock")[1].performClick()
        compose.runOnIdle { assertEquals(listOf(true, false), requests) }
    }

    @Test
    fun guestCanBlockButAnAccountChangeClosesConfirmationAndHidesSelfBlocking() {
        val viewer = mutableStateOf<Long?>(null)
        val scope = mutableStateOf<String?>(null)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                UserBlockControl(8, "Alice", viewer.value, scope.value, false, false) {
                    requests.add(it)
                }
            }
        }
        compose.onNodeWithText("Block").performClick()
        compose.onNodeWithText("Block Alice?").assertIsDisplayed()
        compose.runOnIdle {
            scope.value = "owner"
            viewer.value = 8
        }
        compose.onNodeWithText("Block Alice?").assertDoesNotExist()
        compose.onNodeWithText("Block").assertDoesNotExist()
        assertTrue(requests.isEmpty())
    }

    @Test
    fun localChoicesOverrideServerMembershipAndRemainAccountScopedAfterRestoration() {
        val context =
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        val principal = "block-validation-${java.util.UUID.randomUUID()}"
        val store = org.taggr.android.data.SafetyStore(context)
        val mapper = com.fasterxml.jackson.databind.ObjectMapper()
        val remote = mapper.readTree("{\"id\":7,\"blacklist\":[8]}")
        val canister = org.taggr.android.data.TaggrRuntime.configuration().canisterId
        val prefs =
            context.getSharedPreferences("taggr-safety", android.content.Context.MODE_PRIVATE)
        try {
            store.account(principal)
            store.remoteUser(remote)
            assertTrue(store.blocked(8))
            store.block(8, false)
            assertFalse(store.blocked(8))
            store.block(9, true)
            val restored = org.taggr.android.data.SafetyStore(context)
            restored.account(principal)
            restored.remoteUser(remote)
            assertFalse(restored.blocked(8))
            assertTrue(restored.blocked(9))
            restored.account("$principal-other")
            assertFalse(restored.blocked(9))
            restored.remoteUser(remote)
            assertTrue(restored.blocked(8))
        } finally {
            prefs
                .edit()
                .remove("block/$canister/$principal/8")
                .remove("block/$canister/$principal/9")
                .commit()
        }
    }
}
