package org.taggr.android

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.VideoWebView

/** Actual MainActivity/public post and OS configuration recreation; no authenticated writes. */
@RunWith(AndroidJUnit4::class)
class VideoActivityRecreationReadTest {
    @get:Rule val compose = createEmptyComposeRule()

    private fun report(message: String) {
        InstrumentationRegistry.getInstrumentation()
            .sendStatus(
                2,
                android.os.Bundle().apply {
                    putString("stream", "$message\n")
                },
            )
    }

    private fun players(view: View): List<VideoWebView> =
        if (view is VideoWebView) listOf(view)
        else if (view is ViewGroup)
            (0 until view.childCount).flatMap { players(view.getChildAt(it)) }
        else emptyList()

    @Test
    fun publicVideoConversationSurvivesLandscapePortraitAndReturnsToSearch() {
        val selected = runBlocking {
            TaggrApi().use { api ->
                val ids = api.search("youtube").filter { it.kind == "post" }.map { it.id }.take(20)
                api.posts(ids).first {
                    it.restriction == null &&
                        PostBodyParser.blocks(it.body).any { block ->
                            block is PostBodyBlock.YouTube
                        }
                }
            }
        }
        val video =
            PostBodyParser.blocks(selected.body).filterIsInstance<PostBodyBlock.YouTube>().first()
        report("Selected public post ${selected.id}, video ${video.id}")
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
            fun views(): List<VideoWebView> {
                var result = emptyList<VideoWebView>()
                scenario.onActivity { result = players(it.window.decorView) }
                return result
            }
            fun load(): VideoWebView {
                val tag = "youtube-${video.id}"
                compose.waitUntil(30000) {
                    compose
                        .onAllNodesWithTag(tag, useUnmergedTree = true)
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                compose
                    .onNodeWithTag(tag, useUnmergedTree = true)
                    .performScrollTo()
                    .assertIsDisplayed()
                val started = android.os.SystemClock.elapsedRealtime()
                var reported = false
                var loaded: VideoWebView? = null
                compose.waitUntil(40000) {
                    var states = emptyList<String>()
                    scenario.onActivity {
                        val attached = players(it.window.decorView)
                        loaded = attached.firstOrNull { player ->
                            !player.released &&
                                player.progress == 100 &&
                                player.url?.startsWith(
                                    "https://www.youtube.com/embed/${video.id}"
                                ) == true
                        }
                        states = attached.map { player ->
                            "released=${player.released}, progress=${player.progress}, url=${player.url}, size=${player.width}x${player.height}"
                        }
                    }
                    if (!reported && android.os.SystemClock.elapsedRealtime() - started > 5000) {
                        reported = true
                        val bounds =
                            compose
                                .onNodeWithTag(tag, useUnmergedTree = true)
                                .fetchSemanticsNode()
                                .boundsInRoot
                        val errors =
                            compose
                                .onAllNodesWithText("YouTube video could not be loaded.")
                                .fetchSemanticsNodes()
                                .size
                        report("Video diagnostic: $states, bounds=$bounds, errors=$errors")
                    }
                    loaded != null
                }
                return requireNotNull(loaded)
            }
            fun rotate(
                orientation: Int,
                configuration: Int,
                previousPlayer: VideoWebView,
            ): VideoWebView {
                scenario.onActivity { it.requestedOrientation = orientation }
                compose.waitUntil(30000) {
                    var oriented = false
                    scenario.onActivity {
                        oriented = it.resources.configuration.orientation == configuration
                    }
                    oriented && previousPlayer.released
                }
                compose.onNodeWithText("Conversation").assertIsDisplayed()
                val restored = load()
                assertNotSame(previousPlayer, restored)
                return restored
            }
            try {
                lateinit var account: AccountViewModel
                scenario.onActivity {
                    account = ViewModelProvider(it)[AccountViewModel::class.java]
                }
                compose.waitUntil(30000) { !account.state.value.restoring }
                assertNull("Preserve existing signed-in identities", account.state.value.principal)
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
                    compose.onNodeWithText("Agree and continue").performClick()
                    changed = true
                }
                val result = "search-result-post-${selected.id}"
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag(result).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithTag(result).performScrollTo().performClick()
                val original = load()
                val landscape =
                    rotate(
                        ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
                        Configuration.ORIENTATION_LANDSCAPE,
                        original,
                    )
                val portrait =
                    rotate(
                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
                        Configuration.ORIENTATION_PORTRAIT,
                        landscape,
                    )
                compose.onNodeWithText("Back").performClick()
                compose.waitUntil(10000) { portrait.released }
                compose.waitUntil(30000) {
                    compose.onAllNodesWithText("Search TAGGR").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNode(hasSetTextAction()).assertTextContains(selected.id.toString())
                assertTrue(views().isEmpty())
                report(
                    "Normal MainActivity public post ${selected.id}, video ${video.id}, landscape/portrait recreation and return verified"
                )
            } finally {
                scenario.onActivity {
                    it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                }
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
