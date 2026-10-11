package org.taggr.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.ProfileDraft
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ProfileFieldsTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun canEditProfileAndChooseRewardMode() {
        var observed = ProfileDraft("Alice", "About Alice", "", "Mining", true, "")
        compose.setContent {
            var draft by remember { mutableStateOf(observed) }
            TaggrTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    ProfileFields(draft, true, null) {
                        draft = it
                        observed = it
                    }
                }
            }
        }
        compose
            .onNode(hasSetTextAction() and (hasText("Name") or hasAnyDescendant(hasText("Name"))))
            .performTextReplacement("Alice2")
        compose.onNodeWithText("Convert rewards to credits").performScrollTo().performClick()
        compose
            .onNode(
                hasSetTextAction() and
                    (hasText("Controller Principal (one per line)") or
                        hasAnyDescendant(hasText("Controller Principal (one per line)")))
            )
            .performScrollTo()
            .performTextInput("2vxsx-fae")
        compose.runOnIdle {
            assertEquals("Alice2", observed.name)
            assertEquals("Credits", observed.mode)
            assertEquals(listOf("2vxsx-fae"), observed.controllerIds)
        }
    }
}
