package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class ProfileDetailsUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun labelledLinksDispatchTheExactTargetAndPrincipalRemainsText() {
        var opened: String? = null
        compose.setContent {
            TaggrTheme {
                ProfileDetailsContent(
                    listOf(ProfileLink("Site 🍊", "https://example.org/a:b")),
                    "2vxsx-fae",
                ) {
                    opened = it
                }
            }
        }
        compose
            .onNodeWithTag("profile-principal")
            .assertTextEquals("2vxsx-fae")
            .assertHasNoClickAction()
        compose.runOnIdle { Assert.assertNull(opened) }
        compose.onNodeWithTag("profile-link-0").performClick()
        compose.runOnIdle { Assert.assertEquals("https://example.org/a:b", opened) }
    }
}
