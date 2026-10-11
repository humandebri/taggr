package org.taggr.android

import android.app.Application
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class InlineReplyUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun inlineEditorKeepsDraftOnCancelAndRestoresItInsideTheTimeline() {
        val parent = 987654321010L
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        assertEquals("", account.readDraft(parent))
        val visible = mutableStateOf(true)
        try {
            compose.setContent {
                TaggrTheme {
                    LazyColumn(Modifier.fillMaxWidth()) {
                        item {
                            if (visible.value)
                                PostComposer(
                                    account,
                                    parent,
                                    null,
                                    onDismiss = { visible.value = false },
                                    inline = true,
                                    completed = {},
                                )
                        }
                    }
                }
            }
            compose.waitUntil(5000) {
                compose.onAllNodes(hasSetTextAction() and isEnabled()).fetchSemanticsNodes().size ==
                    1
            }
            compose.onNodeWithText("Reply here...").assertIsDisplayed()
            compose.onNodeWithText("Realm (optional)").assertDoesNotExist()
            compose.onNodeWithText("Submit").assertIsNotEnabled()
            compose.onNode(hasSetTextAction()).performTextReplacement("Kept inline reply draft")
            compose.runOnIdle { assertEquals("Kept inline reply draft", account.readDraft(parent)) }
            compose.onNodeWithText("Preview").performClick()
            compose.onNodeWithText("Kept inline reply draft").assertIsDisplayed()
            compose.onNodeWithText("Write").performClick()
            compose.onNodeWithText("Cancel").performClick()
            compose.onNodeWithText("Reply here...").assertDoesNotExist()
            compose.runOnIdle { visible.value = true }
            compose.waitUntil(5000) {
                compose
                    .onAllNodesWithText("Kept inline reply draft")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            compose.onNodeWithText("Submit").assertIsEnabled()
        } finally {
            runBlocking { account.discardDraft(parent, null) }
        }
    }

    @Test
    fun changingParentRestoresItsOwnDraftAndNeverCopiesAnotherReply() {
        val first = 987654321011L
        val second = first + 1
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        assertEquals("", account.readDraft(first))
        assertEquals("", account.readDraft(second))
        val parent = mutableLongStateOf(first)
        try {
            compose.setContent {
                TaggrTheme {
                    PostComposer(account, parent.longValue, null, {}, inline = true, completed = {})
                }
            }
            compose.waitUntil(5000) {
                compose.onAllNodes(hasSetTextAction() and isEnabled()).fetchSemanticsNodes().size ==
                    1
            }
            compose.onNode(hasSetTextAction()).performTextReplacement("Only first parent")
            compose.runOnIdle { parent.longValue = second }
            compose.waitUntil(5000) {
                compose.onAllNodesWithText("Only first parent").fetchSemanticsNodes().isEmpty()
            }
            compose.onNodeWithText("Submit").assertIsNotEnabled()
            compose.runOnIdle { parent.longValue = first }
            compose.waitUntil(5000) {
                compose.onAllNodesWithText("Only first parent").fetchSemanticsNodes().isNotEmpty()
            }
            compose.runOnIdle { assertEquals("", account.readDraft(second)) }
        } finally {
            runBlocking {
                account.discardDraft(first, null)
                account.discardDraft(second, null)
            }
        }
    }
}
