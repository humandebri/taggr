package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class InvitesUITest {
    @get:Rule val compose = createComposeRule()
    private val invite = TaggrInvite("abcdef1234", 100uL, 50uL, listOf(7), "TEST", 1)

    @Test
    fun participantNameNavigatesToTheOriginalUserID() {
        var opened: Long? = null
        compose.setContent {
            TaggrTheme {
                InviteCard(
                    invite,
                    "https://example.com/#/welcome/abcdef1234",
                    true,
                    {},
                    {},
                    {},
                    { opened = it },
                    name = { "invitesguest" },
                )
            }
        }
        compose.onNodeWithText("invitesguest").assertExists().performClick()
        compose.onNodeWithText("User #7").assertDoesNotExist()
        compose.runOnIdle { assertEquals(7L, opened) }
    }

    @Test
    fun cardSharesCanonicalURLAndHidesRestrictedJoinedUsers() {
        var copied = ""
        val url = "https://example.com/#/welcome/abcdef1234"
        compose.setContent {
            TaggrTheme { InviteCard(invite, url, true, { copied = it }, {}, {}, {}, { false }) }
        }
        compose.onNodeWithText("Active").assertExists()
        compose.onNodeWithText("User #7").assertDoesNotExist()
        compose.onNodeWithContentDescription("Invite QR code").assertExists()
        compose.onNodeWithText("Copy code").performClick()
        compose.runOnIdle { assertEquals("ABCDEF1234", copied) }
        compose.onNodeWithText("Copy URL").performClick()
        compose.runOnIdle { assertEquals(url, copied) }
    }

    @Test
    fun stoppingUsedInviteRequiresExplicitConfirmationAndPreservesPerUserAmount() {
        var saved: InviteDraft? = null
        compose.setContent {
            TaggrTheme { InviteEditor(invite, 50uL, false, false, {}) { saved = it } }
        }
        compose.onNodeWithText("Stop invite").performScrollTo().performClick()
        compose.onNodeWithText("Stop this invite?").assertExists()
        compose.runOnIdle { assertNull(saved) }
        compose.onAllNodesWithText("Stop invite").onLast().performClick()
        compose.runOnIdle {
            assertEquals(0uL, saved!!.credits)
            assertEquals(50uL, saved!!.perUser)
        }
    }

    @Test
    fun uncertainCreationDisablesRepeatSave() {
        compose.setContent {
            TaggrTheme {
                InviteEditor(null, 50uL, false, true, {}, serverError = "Result unavailable") {
                    error("Duplicate dispatch")
                }
            }
        }
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNodeWithText("Result unavailable").assertExists()
        compose
            .onNodeWithText("Check the pending invite result before saving again.")
            .assertExists()
    }
}
