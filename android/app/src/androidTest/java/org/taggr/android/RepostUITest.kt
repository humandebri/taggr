package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class RepostUITest {
    @get:Rule val compose = createComposeRule()

    private fun source(body: String = "Original body") =
        TaggrPost(42, "Alice", body, null, 0, emptyList(), 0, 0, null)

    @Test
    fun commentFormattingUsesDraftCallbackAndPendingRepostDisablesIt() {
        val comment = mutableStateOf("Quote")
        val pending = mutableStateOf(false)
        var submits = 0
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    RepostForm(
                        source(),
                        comment.value,
                        "",
                        false,
                        pending.value,
                        true,
                        null,
                        { comment.value = it },
                        {},
                        { submits++ },
                        {},
                        {},
                    )
                }
            }
        }
        compose.waitUntil(10000) {
            compose
                .onAllNodes(hasSetTextAction())
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("Comment (optional)").performTextInputSelection(TextRange(0, 5))
        compose.onNodeWithText("Italic").performClick()
        compose.runOnIdle {
            Assert.assertEquals("_Quote_", comment.value)
            pending.value = true
        }
        compose.onNodeWithText("Bold").assertIsNotEnabled()
        compose.onNodeWithTag("repost-submit").assertIsNotEnabled()
        compose.runOnIdle { Assert.assertEquals(0, submits) }
    }

    @Test
    fun humanReviewRequiresConfirmationAndNeverSubmitsByItself() {
        var submits = 0
        var checked = 0
        var edits = 0
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    RepostForm(
                        source(),
                        "Quote",
                        "",
                        false,
                        true,
                        true,
                        null,
                        {},
                        {},
                        submit = { submits++ },
                        check = {},
                        dismiss = {},
                        markChecked = { checked++ },
                        retryEditing = { edits++ },
                    )
                }
            }
        }
        compose.onNodeWithText("Edit and retry").performScrollTo().performClick()
        compose.runOnIdle { Assert.assertEquals(0, edits) }
        compose.onNodeWithText("Confirm review").performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, edits)
            Assert.assertEquals(0, submits)
        }
        compose.onNodeWithText("I confirmed it was reposted").performScrollTo().performClick()
        compose.onNodeWithText("Confirm review").performClick()
        compose.runOnIdle {
            Assert.assertEquals(1, checked)
            Assert.assertEquals(0, submits)
        }
    }

    @Test
    fun emptyCommentCanSubmitButUnknownResultMustBeCheckedWithoutResending() {
        val busy = mutableStateOf(false)
        val pending = mutableStateOf(false)
        var submits = 0
        var checks = 0
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    RepostForm(
                        source(),
                        "",
                        "",
                        busy.value,
                        pending.value,
                        true,
                        null,
                        {},
                        {},
                        submit = {
                            submits++
                            busy.value = true
                        },
                        check = { checks++ },
                        dismiss = {},
                    )
                }
            }
        }
        android.util.Log.i("TaggrRepostTest", "content installed")
        val submit = hasTestTag("repost-submit")
        android.util.Log.i("TaggrRepostTest", "before first submit")
        compose.waitUntil(10000) {
            compose
                .onAllNodes(submit)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNode(submit).assertIsEnabled().performClick()
        android.util.Log.i("TaggrRepostTest", "after first submit")
        compose.onNode(submit).assertIsNotEnabled().performClick()
        android.util.Log.i("TaggrRepostTest", "after disabled submit")
        compose.runOnIdle {
            Assert.assertEquals(1, submits)
            busy.value = false
            pending.value = true
        }
        android.util.Log.i("TaggrRepostTest", "pending state set")
        compose.onNode(submit).assertIsNotEnabled()
        android.util.Log.i("TaggrRepostTest", "before check result")
        compose.onNodeWithText("Check post result").performClick()
        android.util.Log.i("TaggrRepostTest", "after check result")
        compose.runOnIdle {
            Assert.assertEquals(1, checks)
            Assert.assertEquals(1, submits)
        }
    }

    @Test
    fun previewHasFourLinesThenExpandsAndSourceTextOpensOriginal() {
        var opened: Long? = null
        val text = (1..12).joinToString("\n") { "Original line $it" }
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    RepostPreview(source(text)) { opened = it }
                }
            }
        }
        compose.onNodeWithText("Show full post").performClick()
        compose.onNodeWithText("Show full post").assertDoesNotExist()
        compose.onNodeWithTag("repost-body-42-0").assertIsDisplayed().performClick()
        compose.runOnIdle { Assert.assertEquals(42L, opened) }
    }
}
