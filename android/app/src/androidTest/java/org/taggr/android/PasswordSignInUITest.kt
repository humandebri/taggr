package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PasswordSignInUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun preservesExactInputAndClearsItOnSubmissionAndDismissal() {
        var submitted: String? = null
        val visible = mutableStateOf(true)
        compose.setContent {
            TaggrTheme {
                if (visible.value)
                    PasswordSignInDialog(false, null, { visible.value = false }, { submitted = it })
            }
        }
        compose.onNodeWithText("Sign in", substring = false).assertIsNotEnabled()
        compose.onNodeWithTag("password-input").performTextInput("  日本語 Seed 🔑  ")
        compose.onNodeWithText("Sign in", substring = false).performClick()
        compose.runOnIdle { assertEquals("  日本語 Seed 🔑  ", submitted) }
        compose.onNodeWithText("Sign in", substring = false).assertIsNotEnabled()
        compose.onNodeWithTag("password-input").performTextInput("temporary")
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { visible.value = true }
        compose.onNodeWithText("Sign in", substring = false).assertIsNotEnabled()
    }

    @Test
    fun busyAuthenticationDisablesInputSubmitAndDismissal() {
        var dismissed = false
        var submitted = false
        compose.setContent {
            TaggrTheme {
                PasswordSignInDialog(true, null, { dismissed = true }, { submitted = true })
            }
        }
        compose.onNodeWithTag("password-input").assertIsNotEnabled()
        compose.onNodeWithText("Cancel").assertIsNotEnabled()
        compose.onNodeWithText("Signing in...").assertIsNotEnabled()
        compose.runOnIdle {
            assertFalse(dismissed)
            assertFalse(submitted)
        }
    }
}
