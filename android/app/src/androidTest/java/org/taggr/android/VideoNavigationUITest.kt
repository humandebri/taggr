package org.taggr.android

import android.app.Application
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.*

/** Normal app navigation with a fixture repository and the actual public YouTube player. */
@RunWith(AndroidJUnit4::class)
class VideoNavigationUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun players(view: View): List<VideoWebView> =
        if (view is VideoWebView) listOf(view)
        else if (view is ViewGroup)
            (0 until view.childCount).flatMap { players(view.getChildAt(it)) }
        else emptyList()

    private fun loadedPlayer(scroll: Boolean = true): VideoWebView {
        var result: VideoWebView? = null
        println(
            "Video bounds before load: " +
                compose
                    .onNodeWithTag("youtube-M7lc1UVf-VE", useUnmergedTree = true)
                    .fetchSemanticsNode()
                    .boundsInRoot
        )
        val video = compose.onNodeWithTag("youtube-M7lc1UVf-VE", useUnmergedTree = true)
        if (scroll) video.performScrollTo()
        video.assertIsDisplayed()
        val started = android.os.SystemClock.elapsedRealtime()
        var reported = false
        compose.waitUntil(40_000) {
            var loaded = false
            compose.runOnIdle {
                val found = players(compose.activity.window.decorView)
                result = found.singleOrNull()
                loaded =
                    result?.progress == 100 &&
                        result?.url?.startsWith("https://www.youtube.com/embed/") == true
                if (!reported && android.os.SystemClock.elapsedRealtime() - started > 5_000) {
                    reported = true
                    InstrumentationRegistry.getInstrumentation()
                        .sendStatus(
                            2,
                            android.os.Bundle().apply {
                                putString(
                                    "stream",
                                    "Video load diagnostic: " +
                                        found.map {
                                            "released=${it.released}, progress=${it.progress}, url=${it.url}"
                                        } +
                                        "\n",
                                )
                            },
                        )
                }
            }
            loaded
        }
        return requireNotNull(result)
    }

    private fun advancing(player: VideoWebView) {
        var time = 0.0
        compose.waitUntil(25_000) {
            compose.runOnIdle {
                player.evaluateJavascript(
                    "(() => { const v=document.querySelector('video'); return v && !v.paused ? v.currentTime : 0; })()"
                ) {
                    time = it.toDoubleOrNull() ?: 0.0
                }
            }
            time > 0.5
        }
        val start = time
        compose.waitUntil(10_000) {
            compose.runOnIdle {
                player.evaluateJavascript(
                    "(() => { const v=document.querySelector('video'); return v && !v.paused ? v.currentTime : 0; })()"
                ) {
                    time = it.toDoubleOrNull() ?: 0.0
                }
            }
            time > start + 0.5
        }
    }

    @Test
    fun normalFeedConversationRestorationBackgroundAndTabDisposal() {
        val post =
            TaggrPost(
                9240,
                "Alice",
                "Video navigation fixture\n\nhttps://youtu.be/M7lc1UVf-VE\n\nVideo tail",
                null,
                0,
                emptyList(),
                0,
                0,
                null,
            )
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        val restoration = StateRestorationTester(compose)
        restoration.setContent { TaggrTheme { TaggrApp(model, account) } }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        val feedPlayer = loadedPlayer()
        compose
            .onNodeWithTag("post-body-9240-0", useUnmergedTree = true)
            .performScrollTo()
            .performTouchInput {
                click(center)
            }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.waitUntil(10_000) { feedPlayer.released }
        val conversationPlayer = loadedPlayer()
        assertNotSame(feedPlayer, conversationPlayer)
        compose.onNodeWithTag("youtube-M7lc1UVf-VE", useUnmergedTree = true).performTouchInput {
            click(center)
        }
        advancing(conversationPlayer)

        // A real Activity lifecycle transition, independent of composition visibility.
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        var paused = false
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = android.os.SystemClock.elapsedRealtime() + 10_000
        while (!paused && android.os.SystemClock.elapsedRealtime() < deadline) {
            instrumentation.runOnMainSync {
                conversationPlayer.evaluateJavascript(
                    "document.querySelector('video')?.paused === true"
                ) {
                    paused = it == "true"
                }
            }
            instrumentation.waitForIdleSync()
            android.os.SystemClock.sleep(100)
        }
        assertTrue("Backgrounding must pause the actual video", paused)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.runOnIdle { assertFalse(conversationPlayer.released) }
        compose.onNodeWithTag("youtube-M7lc1UVf-VE", useUnmergedTree = true).performTouchInput {
            click(center)
        }
        advancing(conversationPlayer)

        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.waitUntil(10_000) { conversationPlayer.released }
        val restoredPlayer = loadedPlayer(scroll = false)
        assertNotSame(conversationPlayer, restoredPlayer)
        compose.onNodeWithText("Back").performClick()
        compose.waitUntil(10_000) { restoredPlayer.released }
        compose.onNodeWithText("Conversation").assertDoesNotExist()
        val returnedPlayer = loadedPlayer()
        compose.onNodeWithText("Account").performClick()
        compose.waitUntil(10_000) { returnedPlayer.released }
        compose.runOnIdle { assertTrue(players(compose.activity.window.decorView).isEmpty()) }
        compose.onNodeWithText("Password").assertIsDisplayed()
    }
}
