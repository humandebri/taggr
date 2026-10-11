package org.taggr.android

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class MarkdownEditorUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun imageInsertionSelectionIsConsumedAndSubsequentTypingUsesNewCaret() {
        val text = mutableStateOf("AB")
        val requested = mutableStateOf<TextRange?>(null)
        var selection = TextRange.Zero
        compose.setContent {
            TaggrTheme {
                MarkdownEditor(
                    text.value,
                    { text.value = it },
                    "Write your post",
                    true,
                    selectionChanged = { selection = it },
                    selectionRequest = requested.value,
                    consumeSelectionRequest = { requested.value = null },
                )
            }
        }
        compose.waitUntil(10000) {
            compose
                .onAllNodes(hasSetTextAction())
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNode(hasSetTextAction()).performTextInputSelection(TextRange(1, 2))
        compose.runOnIdle {
            val edit = insertDraftImages(text.value, listOf("![x](/blob/x)"), selection.min)
            text.value = edit.text
            requested.value = edit.selection
        }
        compose.waitUntil(10000) { requested.value == null }
        compose.onNode(hasSetTextAction()).performTextInput("after")
        compose.runOnIdle { assertEquals("A\n\n![x](/blob/x)\nafterB", text.value) }
    }

    @Test
    fun selectedFormattingPersistsThroughCallbackAndCancelledLinkKeepsText() {
        val text = mutableStateOf("Hello 🧡 world")
        compose.setContent {
            TaggrTheme { MarkdownEditor(text.value, { text.value = it }, "Write your post", true) }
        }
        compose.onNode(hasSetTextAction()).performTextInputSelection(TextRange(6, 8))
        compose.onNodeWithText("Bold").performClick()
        compose.runOnIdle { assertEquals("Hello **🧡** world", text.value) }
        compose.onNodeWithText("Link").performScrollTo().performClick()
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("URL")
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("URL").performTextInput("https://example.test")
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals("Hello **🧡** world", text.value) }
        compose.onNodeWithText("Link").performScrollTo().performClick()
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("URL")
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("URL").performTextInput("https://example.test")
        compose.onNodeWithText("Insert").performClick()
        compose.runOnIdle { assertEquals("Hello **[🧡](https://example.test)** world", text.value) }
    }

    @Test
    fun changedDraftAndDisabledEditorCannotApplyStaleLink() {
        val text = mutableStateOf("Old draft")
        val enabled = mutableStateOf(true)
        compose.setContent {
            TaggrTheme {
                MarkdownEditor(text.value, { text.value = it }, "Write your post", enabled.value)
            }
        }
        compose.waitUntil(10000) {
            compose
                .onAllNodes(hasSetTextAction())
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("Link").performScrollTo().performClick()
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("URL")
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("URL").performTextInput("https://example.test")
        compose.runOnIdle { text.value = "Replacement draft" }
        compose.onNodeWithText("Insert").assertIsNotEnabled()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { enabled.value = false }
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("Bold")
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .isNotEmpty()
        }
        compose.onNodeWithText("Bold").assertIsNotEnabled()
        compose.runOnIdle { assertEquals("Replacement draft", text.value) }
    }
}
