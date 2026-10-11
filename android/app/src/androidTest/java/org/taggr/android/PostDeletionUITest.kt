package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostDeletionUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun onlyOwnUndeletedPostOpensReviewAndConfirmationPreventsPendingRepeat() {
        val own = mutableStateOf(false)
        val deleted = mutableStateOf(false)
        val shown = mutableStateOf(false)
        val busy = mutableStateOf(false)
        val pending = mutableStateOf(false)
        var requests = 0
        var checks = 0
        compose.setContent {
            TaggrTheme {
                if (shown.value)
                    DeletePostConfirmation(
                        busy.value,
                        pending.value,
                        null,
                        delete = {
                            requests++
                            busy.value = true
                        },
                        check = { checks++ },
                        cancel = { shown.value = false },
                    )
                else DeletePostControl(own.value, deleted.value, false) { shown.value = true }
            }
        }
        compose.onNodeWithText("Delete").assertDoesNotExist()
        compose.runOnIdle {
            own.value = true
            deleted.value = true
        }
        compose.onNodeWithText("Delete").assertDoesNotExist()
        compose.runOnIdle { deleted.value = false }
        compose.onNodeWithText("Delete").performClick()
        compose.runOnIdle { Assert.assertEquals(0, requests) }
        compose.onNodeWithText("Delete").performClick()
        compose.onNodeWithText("Delete").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, requests)
            busy.value = false
            pending.value = true
        }
        compose.onNodeWithText("Delete").assertIsNotEnabled()
        compose.onNodeWithText("Check post result").performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, checks)
            Assert.assertEquals(1, requests)
        }
    }
}
