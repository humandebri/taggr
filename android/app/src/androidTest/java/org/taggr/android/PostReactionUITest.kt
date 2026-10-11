package org.taggr.android

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostReactionUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun accountAndPostChangesRemoveUnavailableActions() {
        val post =
            mutableStateOf(
                TaggrPost(42, "Alice", "Hello", null, 0, emptyList(), 0, 0, null, authorId = 7)
            )
        val viewer = mutableStateOf<Long?>(8)
        val busy = mutableStateOf(false)
        var opened = 0
        compose.setContent {
            TaggrTheme { PostReactionControl(post.value, viewer.value, busy.value) { opened++ } }
        }
        compose.onNodeWithText("React").assertIsEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, opened)
            busy.value = true
        }
        compose.onNodeWithText("React").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, opened)
            busy.value = false
            viewer.value = 7
        }
        compose.onNodeWithText("React").assertDoesNotExist()
        compose.runOnIdle {
            viewer.value = 8
            post.value = post.value.copy(reactions = mapOf(1 to listOf(8L)))
        }
        compose.onNodeWithText("React").assertDoesNotExist()
        compose.runOnIdle {
            post.value = post.value.copy(reactions = emptyMap(), viewerBlocked = true)
        }
        compose.onNodeWithText("React").assertDoesNotExist()
        compose.runOnIdle { viewer.value = null }
        compose.onNodeWithText("React").assertDoesNotExist()
    }
}
