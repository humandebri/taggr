package org.taggr.android

import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.ui.RootTabIcon
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class InboxBadgeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun inboxBadgeUpdatesAndDisappearsWhenRead() {
        val count = mutableIntStateOf(2)
        compose.setContent { TaggrTheme { RootTabIcon(2, count.intValue) } }
        compose.onNodeWithContentDescription("2 unread notifications").assertIsDisplayed()
        compose.runOnIdle { count.intValue = 1 }
        compose.onNodeWithContentDescription("1 unread notification").assertIsDisplayed()
        compose.runOnIdle { count.intValue = 0 }
        compose.onNodeWithContentDescription("1 unread notification").assertDoesNotExist()
        compose.onNodeWithText("0").assertDoesNotExist()
    }

    @Test
    fun otherTabsNeverShowInboxCount() {
        compose.setContent { TaggrTheme { RootTabIcon(0, 12) } }
        compose.onNodeWithText("12").assertDoesNotExist()
    }
}
