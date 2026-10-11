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
class ProfileUsersUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun guestFallbackSelectionRetryAndDoneUseTheirCallbacks() {
        var selected: Long? = null
        var retries = 0
        var more = 0
        var done = false
        compose.setContent {
            TaggrTheme {
                ProfileUsersContent(
                    "Followers",
                    listOf(3, 9),
                    mapOf(3L to "Alice"),
                    false,
                    true,
                    true,
                    null,
                    emptySet(),
                    false,
                    { done = true },
                    { retries++ },
                    { more++ },
                    { selected = it },
                    {},
                )
            }
        }
        compose.onNodeWithText("Follow").assertDoesNotExist()
        compose.onNodeWithText("@Alice").performClick()
        compose.runOnIdle { assertEquals(3L, selected) }
        compose.onNodeWithText("@9").performClick()
        compose.runOnIdle { assertEquals(9L, selected) }
        compose.onNodeWithText("Retry").performClick()
        compose.onNodeWithText("More users").performClick()
        compose.onNodeWithText("Done").performClick()
        compose.runOnIdle {
            assertEquals(1, retries)
            assertEquals(1, more)
            assertTrue(done)
        }
    }

    @Test
    fun followsHideSelfAndDisableMutationWhileBusy() {
        var busy by mutableStateOf(false)
        var target: Long? = null
        compose.setContent {
            TaggrTheme {
                ProfileUsersContent(
                    "Follows",
                    listOf(3, 9),
                    emptyMap(),
                    false,
                    false,
                    false,
                    3L,
                    setOf(9),
                    busy,
                    {},
                    {},
                    {},
                    {},
                    {
                        target = it
                        busy = true
                    },
                )
            }
        }
        compose.onNodeWithText("Follow").assertDoesNotExist()
        compose.onNodeWithText("Unfollow").performClick()
        compose.runOnIdle { assertEquals(9L, target) }
        compose.onNodeWithText("Unfollow").assertIsNotEnabled()
    }
}
