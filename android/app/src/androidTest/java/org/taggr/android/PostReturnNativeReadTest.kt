package org.taggr.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class PostReturnNativeReadTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun publicSearchReturnsToQueryAfterPostNavigationAndActivityRecreation() {
        val selected = runBlocking {
            TaggrApi().use { api ->
                val post =
                    api.feedPage(FeedMode.LATEST, 0, 0).posts.first {
                        it.restriction == null && it.parent == null
                    }
                api.search(post.id.toString()).first { it.kind == "post" && it.id == post.id }
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
        val terms = "terms/${TaggrRuntime.configuration().canisterId}"
        val previous = prefs.getString(terms, null)
        var changed = false
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("https://${TaggrRuntime.domain}/search/${selected.id}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            try {
                lateinit var account: AccountViewModel
                scenario.onActivity {
                    account = ViewModelProvider(it)[AccountViewModel::class.java]
                }
                compose.waitUntil(30000) { !account.state.value.restoring }
                Assert.assertNull(
                    "Read test preserves existing signed-in sessions.",
                    account.state.value.principal,
                )
                if (
                    compose
                        .onAllNodesWithText("Agree and continue")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                ) {
                    compose
                        .onNodeWithText("I agree to the Terms of Use and safety rules")
                        .performScrollTo()
                        .performClick()
                    compose.onNodeWithText("Agree and continue").performScrollTo().performClick()
                    changed = true
                }
                val resultTag = "search-result-post-${selected.target}"
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag(resultTag).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithTag(resultTag).performScrollTo().performClick()
                compose.waitUntil(30000) {
                    compose
                        .onAllNodesWithTag("post-row-${selected.id}")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                compose.waitUntil(30000) {
                    try {
                        compose.onNodeWithText("Conversation").assertIsDisplayed()
                        true
                    } catch (_: AssertionError) {
                        false
                    }
                }
                compose.onNodeWithText("Conversation").assertIsDisplayed()
                scenario.recreate()
                compose.waitUntil(30000) {
                    runCatching {
                            compose
                                .onAllNodesWithText("Conversation")
                                .fetchSemanticsNodes()
                                .isNotEmpty()
                        }
                        .getOrDefault(false)
                }
                compose.onNodeWithText("Back").performClick()
                compose.waitUntil(30000) {
                    compose.onAllNodesWithText("Search TAGGR").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNode(hasSetTextAction()).assertTextContains(selected.id.toString())
                compose.onNodeWithText("Conversation").assertDoesNotExist()
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag(resultTag).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithTag(resultTag).performScrollTo().assertIsDisplayed()
                compose.onNodeWithTag(resultTag).performClick()
                compose.waitUntil(30000) {
                    compose.onAllNodesWithText("Conversation").fetchSemanticsNodes().isNotEmpty()
                }
                InstrumentationRegistry.getInstrumentation()
                    .uiAutomation
                    .performGlobalAction(
                        android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK
                    )
                compose.waitUntil(30000) {
                    compose.onAllNodesWithText("Search TAGGR").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNode(hasSetTextAction()).assertTextContains(selected.id.toString())
                println(
                    "Public search post ${selected.id} returned to its query after recreation and system Back"
                )
            } finally {
                if (changed)
                    prefs
                        .edit()
                        .apply {
                            if (previous == null) remove(terms) else putString(terms, previous)
                        }
                        .commit()
            }
        }
    }
}
