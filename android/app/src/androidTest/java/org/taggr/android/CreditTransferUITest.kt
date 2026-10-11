package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class CreditTransferUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun feeIncludedBalanceReviewAndPendingPreventDuplicateSubmission() {
        var amount by mutableStateOf("")
        var pending by mutableStateOf(false)
        var reviews = 0
        var checks = 0
        compose.setContent {
            TaggrTheme {
                CreditTransferForm(
                    "Alice",
                    amount,
                    { amount = it },
                    110uL,
                    10uL,
                    pending,
                    false,
                    pending,
                    null,
                    {},
                    {
                        reviews++
                        pending = true
                    },
                    { checks++ },
                )
            }
        }
        compose.onNodeWithText("Review transfer").assertIsNotEnabled()
        compose.onNodeWithTag("profile-credits-amount").performTextInput("101")
        compose.onNodeWithText("Review transfer").assertIsNotEnabled()
        compose.onNodeWithTag("profile-credits-amount").performTextReplacement("100")
        compose.onNodeWithText("Total deducted: 110 credits").assertIsDisplayed()
        compose.onNodeWithText("Review transfer").performClick()
        compose.onNodeWithText("Review transfer").assertIsNotEnabled()
        compose.onNodeWithText("Check transfer result").performClick()
        compose.runOnIdle {
            assertEquals(1, reviews)
            assertEquals(1, checks)
        }
    }

    @Test
    fun unknownFeeReloadAndConfirmedResultDisableSend() {
        var fee by mutableStateOf<ULong?>(null)
        var sent by mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                CreditTransferForm(
                    "Alice",
                    "1",
                    {},
                    10uL,
                    fee,
                    false,
                    sent,
                    false,
                    null,
                    { fee = 1uL },
                    { sent = true },
                    {},
                )
            }
        }
        compose.onNodeWithText("Review transfer").assertIsNotEnabled()
        compose.onNodeWithText("Reload fee").performClick()
        compose.onNodeWithText("Review transfer").performClick()
        compose.onNodeWithText("Credits sent").assertIsDisplayed()
        compose.onNodeWithText("Review transfer").assertIsNotEnabled()
    }
}
