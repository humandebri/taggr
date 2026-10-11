package org.taggr.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ProfileStatisticsUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun countCardsOpenUserAndRealmListsWithoutMutations() {
        val stats =
            listOf(
                ProfileStatistic("posts", "Posts", "12"),
                ProfileStatistic("followers", "Followers", "2", ProfileUserList.Followers),
                ProfileStatistic("joined-realms", "Joined realms", "2", realms = listOf("A", "B")),
            )
        var sheet by mutableStateOf<ProfileStatistic?>(null)
        var kind: ProfileUserList? = null
        var realm: String? = null
        compose.setContent {
            TaggrTheme {
                ProfileStatisticsGrid(stats, { kind = it }, { sheet = it })
                sheet?.let {
                    ProfileRealmsSheet(it, { sheet = null }) { selected ->
                        realm = selected
                        sheet = null
                    }
                }
            }
        }
        compose.onNodeWithTag("profile-stat-posts").assertHasNoClickAction()
        compose.onNodeWithTag("profile-stat-followers").performClick()
        compose.runOnIdle {
            Assert.assertEquals(ProfileUserList.Followers, kind)
            Assert.assertNull(realm)
        }
        compose.onNodeWithTag("profile-stat-joined-realms").performClick()
        compose.onNodeWithTag("profile-realm-list").assertIsDisplayed()
        compose.onNodeWithTag("profile-realm-B").performClick()
        compose.runOnIdle { Assert.assertEquals("B", realm) }
        compose.onNodeWithTag("profile-realm-list").assertDoesNotExist()
    }
}
