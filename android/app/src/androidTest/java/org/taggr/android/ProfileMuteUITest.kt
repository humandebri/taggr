package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ProfileMuteUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun muteNeedsConfirmationAndUnmuteIsExplicitWithoutGuestOrBusyActions() {
        val identity = mutableStateOf(7L)
        val available = mutableStateOf(false)
        val muted = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                ProfileMuteControl(available.value, muted.value, busy.value, identity.value) {
                    requests += it
                    busy.value = true
                }
            }
        }
        compose.onNodeWithText("Mute").assertDoesNotExist()
        compose.runOnIdle { available.value = true }
        compose.onNodeWithText("Mute").performClick()
        compose.runOnIdle { Assert.assertTrue(requests.isEmpty()) }
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { Assert.assertTrue(requests.isEmpty()) }
        compose.onNodeWithText("Mute").performClick()
        compose.runOnIdle { identity.value = 8L }
        compose.onNodeWithText("Mute this user?").assertDoesNotExist()
        compose.runOnIdle { Assert.assertTrue(requests.isEmpty()) }
        compose.onNodeWithText("Mute").performClick()
        compose.onAllNodesWithText("Mute").filter(hasClickAction()).onLast().performClick()
        compose.onNodeWithText("Mute").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(listOf(true), requests)
            muted.value = true
            busy.value = false
        }
        compose.onNodeWithText("Unmute").performClick()
        compose.onNodeWithText("Unmute").assertIsNotEnabled().performClick()
        compose.runOnIdle { Assert.assertEquals(listOf(true, false), requests) }
    }
}
