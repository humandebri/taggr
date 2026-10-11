package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostPinUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun onlyOwnedPostsOfferPinAndPendingSelectionCannotToggleAgain() {
        val own = mutableStateOf(false)
        val pinned = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                PostPinControl(own.value, pinned.value, busy.value) {
                    requests.add(it)
                    busy.value = true
                }
            }
        }
        compose.onNodeWithText("Pin").assertDoesNotExist()
        compose.onNodeWithText("Unpin").assertDoesNotExist()
        compose.runOnIdle { own.value = true }
        compose.onNodeWithText("Pin").performClick()
        compose.onNodeWithText("Pin").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(listOf(true), requests)
            pinned.value = true
            busy.value = false
        }
        compose.onNodeWithText("Unpin").performClick()
        compose.onNodeWithText("Unpin").assertIsNotEnabled()
        compose.runOnIdle {
            Assert.assertEquals(listOf(true, false), requests)
            own.value = false
        }
        compose.onNodeWithText("Unpin").assertDoesNotExist()
    }
}
