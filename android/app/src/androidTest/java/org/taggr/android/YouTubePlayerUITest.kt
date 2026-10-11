package org.taggr.android

import android.graphics.Bitmap
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class YouTubePlayerUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun views(view: View): List<VideoWebView> =
        if (view is VideoWebView) listOf(view)
        else if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) }
        else emptyList()

    @Test
    fun actualInlineWebViewLoadsAndIsDestroyedWhenPostLeavesComposition() {
        var show by mutableStateOf(true)
        var active by mutableStateOf(true)
        compose.setContent {
            TaggrTheme {
                CompositionLocalProvider(LocalVideoActive provides active) {
                    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
                        if (show)
                            PostContent(
                                TaggrPost(
                                    1,
                                    "Alice",
                                    "Before\n\nhttps://youtu.be/M7lc1UVf-VE\n\nAfter",
                                    null,
                                    0,
                                    emptyList(),
                                    0,
                                    0,
                                    null,
                                ),
                                false,
                            )
                        else androidx.compose.material3.Text("Closed")
                    }
                }
            }
        }
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").assertIsDisplayed()
        compose.onNodeWithText("Before").assertIsDisplayed()
        compose.onNodeWithText("After").assertIsDisplayed()
        lateinit var player: VideoWebView
        compose.waitUntil(30000) {
            var loaded = false
            compose.activity.runOnUiThread {
                val found = views(compose.activity.window.decorView).singleOrNull()
                if (found != null) {
                    player = found
                    loaded =
                        found.progress == 100 &&
                            found.url?.startsWith("https://www.youtube.com/embed/") == true
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            loaded
        }
        compose.runOnIdle {
            assertTrue(player.settings.javaScriptEnabled)
            assertFalse(player.settings.allowFileAccess)
            assertTrue(player.settings.mediaPlaybackRequiresUserGesture)
        }
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").performTouchInput { click(center) }
        var playedTime = 0.0
        compose.waitUntil(25000) {
            compose.activity.runOnUiThread {
                player.evaluateJavascript(
                    "(() => { const v=document.querySelector('video'); return v && !v.paused ? v.currentTime : 0; })()"
                ) { value ->
                    playedTime = value.toDoubleOrNull() ?: 0.0
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            playedTime > 1.0
        }
        val beforeTime = playedTime
        compose.waitUntil(10000) {
            compose.activity.runOnUiThread {
                player.evaluateJavascript("document.querySelector('video')?.currentTime || 0") {
                    value ->
                    playedTime = value.toDoubleOrNull() ?: 0.0
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            playedTime > beforeTime + 0.5
        }
        android.os.SystemClock.sleep(500)
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.cacheDir, "youtube-native.png").outputStream().use {
            check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        image.recycle()
        var fullScreenButton: JsonNode? = null
        val mapper = ObjectMapper()
        compose.waitUntil(10000) {
            compose.activity.runOnUiThread {
                player.evaluateJavascript(
                    "(() => { const b=Array.from(document.querySelectorAll('button')).find(b => /full.?screen/i.test((b.getAttribute('aria-label')||'')+' '+(b.title||'')) && b.offsetWidth>0); if(!b) return null; const r=b.getBoundingClientRect(); return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2,width:innerWidth,height:innerHeight}); })()"
                ) { value ->
                    fullScreenButton =
                        runCatching { mapper.readTree(mapper.readTree(value).asText()) }.getOrNull()
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            fullScreenButton?.path("width")?.asDouble(0.0)?.let { it > 0.0 } == true
        }
        val button = requireNotNull(fullScreenButton)
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").performTouchInput {
            click(
                Offset(
                    (button.path("x").asDouble() * width / button.path("width").asDouble())
                        .toFloat(),
                    (button.path("y").asDouble() * height / button.path("height").asDouble())
                        .toFloat(),
                )
            )
        }
        compose.waitUntil(15000) {
            compose.onAllNodesWithText("Close video").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Close video").assertIsDisplayed()
        var fullTime = 0.0
        var fullPaused = true
        var fullStatusLoaded = false
        compose.waitUntil(10000) {
            compose.activity.runOnUiThread {
                player.evaluateJavascript(
                    "JSON.stringify({time:document.querySelector('video')?.currentTime||0,paused:document.querySelector('video')?.paused!==false})"
                ) { value ->
                    val status = mapper.readTree(mapper.readTree(value).asText())
                    fullTime = status.path("time").asDouble()
                    fullPaused = status.path("paused").asBoolean(true)
                    fullStatusLoaded = true
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            fullStatusLoaded
        }
        if (fullPaused)
            compose.onNodeWithTag("youtube-fullscreen-player").performTouchInput { click(center) }
        val fullStart = fullTime
        compose.waitUntil(15000) {
            compose.activity.runOnUiThread {
                player.evaluateJavascript(
                    "(() => { const v=document.querySelector('video'); return v && !v.paused ? v.currentTime : 0; })()"
                ) { value ->
                    fullTime = value.toDoubleOrNull() ?: 0.0
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            fullTime > fullStart + 0.5
        }
        android.os.SystemClock.sleep(500)
        val fullImage = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
        File(context.cacheDir, "youtube-fullscreen-native.png").outputStream().use {
            check(fullImage.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        fullImage.recycle()
        compose.onNodeWithText("Close video").performTouchInput { click(center) }
        compose.waitUntil(10000) {
            compose.onAllNodesWithText("Close video").fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithText("After").assertIsDisplayed()
        compose.runOnIdle { assertFalse(player.released) }
        compose.runOnIdle { active = false }
        compose.waitUntil(10000) { player.released }
        compose.onNodeWithText("Before").assertIsDisplayed()
        compose.runOnIdle { show = false }
        compose.runOnIdle { assertTrue(views(compose.activity.window.decorView).isEmpty()) }
        compose.onNodeWithText("Closed").assertIsDisplayed()
    }
}
