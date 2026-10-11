package org.taggr.android

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class UserBadgesUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun postShowsServerBadgesWithAccessibleLabelsAndKeepsBody() {
        compose.setContent {
            TaggrTheme {
                Column {
                    PostContent(
                        TaggrPost(
                            1,
                            "Alice",
                            "Body",
                            null,
                            0,
                            emptyList(),
                            0,
                            0,
                            null,
                            authorBadges = listOf(UserBadge.Og, UserBadge.Stalwart),
                        ),
                        false,
                    )
                }
            }
        }
        compose.onNodeWithContentDescription("OG account").assertIsDisplayed()
        compose.onNodeWithContentDescription("Stalwart").assertIsDisplayed()
        compose.onNodeWithText("Body").assertIsDisplayed()
    }
}
