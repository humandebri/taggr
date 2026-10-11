package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.ReactionGroup
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class ReactionDetailsUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun knownNameLinkFallbackAndRetryUseTheirTargets() {
        var selected: Long? = null
        var retries = 0
        compose.setContent {
            TaggrTheme {
                ReactionDetailsContent(
                    listOf(ReactionGroup(11, "👍", listOf(7, 9))),
                    mapOf(7L to "Alice"),
                    remember { mutableStateMapOf() },
                    false,
                    true,
                    { retries++ },
                    { selected = it },
                )
            }
        }
        compose.onNodeWithText("👍 2").assertIsDisplayed()
        compose.onNodeWithTag("reaction-voters-11").clickPollVoter("Alice")
        compose.runOnIdle { assertEquals(7L, selected) }
        compose.onNodeWithText("Alice, @9").assertIsDisplayed()
        compose.onNodeWithText("Retry names").performClick()
        compose.runOnIdle { assertEquals(1, retries) }
    }

    @Test
    fun expansionRetainsTotalAndBlockedUsersDoNotAppear() {
        compose.setContent {
            TaggrTheme {
                ReactionDetailsContent(
                    listOf(ReactionGroup(10, "❤️", (1L..25L).toList())),
                    emptyMap(),
                    remember { mutableStateMapOf() },
                    false,
                    false,
                    {},
                    {},
                    { it != 2L },
                )
            }
        }
        compose.onNodeWithText("❤️ 25").assertIsDisplayed()
        compose.onNodeWithText("@25", substring = true).assertDoesNotExist()
        compose.onNodeWithText("More users").performClick()
        compose.onNodeWithTag("reaction-voters-10").assertTextContains("@25", substring = true)
        compose.onNodeWithText("More users").assertDoesNotExist()
    }
}
