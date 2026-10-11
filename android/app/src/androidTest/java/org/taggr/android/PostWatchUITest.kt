package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostWatchUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun guestCannotWatchAndBusyCannotReversePendingSelection() {
        val signedIn = mutableStateOf(false)
        val watching = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                PostWatchControl(signedIn.value, watching.value, busy.value) {
                    requests.add(it)
                    busy.value = true
                }
            }
        }
        compose.onNodeWithText("Watch").assertDoesNotExist()
        compose.onNodeWithText("Unwatch").assertDoesNotExist()
        compose.runOnIdle { signedIn.value = true }
        compose.onNodeWithText("Watch").performClick()
        compose.onNodeWithText("Watch").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(listOf(true), requests)
            watching.value = true
            busy.value = false
        }
        compose.onNodeWithText("Unwatch").assertIsEnabled().performClick()
        compose.onNodeWithText("Unwatch").assertIsNotEnabled()
        compose.runOnIdle { Assert.assertEquals(listOf(true, false), requests) }
    }
}
