package org.taggr.android

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class RepostNativeReadTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun actualPublicRepostLoadsItsOriginalAndOpensNativeConversation() {
        val selected = runBlocking {
            TaggrApi().use { api ->
                var found: Pair<TaggrPost, TaggrPost>? = null
                for (page in 0..5) {
                    val rows = api.feedPage(FeedMode.LATEST, page, 0)
                    for (post in
                        rows.posts.filter {
                            it.parent == null && it.repostId != null && it.restriction == null
                        }) {
                        val source = api.posts(listOf(post.repostId!!)).singleOrNull()
                        if (source != null && source.restriction == null && source.id != post.id) {
                            found = post to source
                            break
                        }
                    }
                    if (found != null || !rows.hasMore) break
                }
                requireNotNull(found) {
                    "No readable public Repost found in the inspected latest pages."
                }
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
                .setData(Uri.parse("https://${TaggrRuntime.domain}/post/${selected.first.id}"))
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
                val sourceId = selected.second.id
                compose.waitUntil(30000) {
                    compose
                        .onAllNodesWithTag("repost-open-$sourceId")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                compose.onNodeWithTag("repost-open-$sourceId").performScrollTo().assertIsDisplayed()
                compose.onNodeWithTag("post-row-$sourceId").assertDoesNotExist()
                val bitmap =
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    )
                File(context.cacheDir, "repost-native.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
                compose.onNodeWithTag("repost-open-$sourceId").performClick()
                compose.waitUntil(30000) {
                    compose
                        .onAllNodesWithTag("post-row-$sourceId")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                compose.onNodeWithTag("post-row-$sourceId").performScrollTo().assertIsDisplayed()
                require(selected.second.reposts.isNotEmpty()) {
                    "The quoted original must retain a Repost count."
                }
                compose
                    .onNodeWithText("${selected.second.reposts.size} reposts", substring = true)
                    .performScrollTo()
                    .assertIsDisplayed()
                println("Native Repost ${selected.first.id} opened original $sourceId")
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
