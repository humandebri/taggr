package org.taggr.android

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.FeedMode
import org.taggr.android.data.TaggrApi
import org.taggr.android.data.TaggrRuntime
import org.taggr.android.ui.postImageUrls

@RunWith(AndroidJUnit4::class)
class BrowsingColdStartTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun initialURLSurvivesGuestRestorationAndTermsGate() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
        val key = "terms/${TaggrRuntime.configuration().canisterId}"
        val before = prefs.getString(key, null)
        fun matching(url: String) =
            context.packageManager.queryIntentActivities(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .setPackage(context.packageName)
                    .addCategory(Intent.CATEGORY_BROWSABLE),
                PackageManager.MATCH_DEFAULT_ONLY,
            )
        assertTrue(
            matching("https://${TaggrRuntime.domain}/user/0/photos").any {
                it.activityInfo.name == MainActivity::class.java.name
            }
        )
        assertTrue(
            matching("https://${TaggrRuntime.domain}/android-auth-callback").none {
                it.activityInfo.name == MainActivity::class.java.name
            }
        )
        var changed = false
        val selectedPost = runBlocking {
            TaggrApi().use { api ->
                api.feedPage(FeedMode.LATEST, 0, 0).posts.first {
                    it.restriction == null && postImageUrls(it, it.body).isNotEmpty()
                }
            }
        }
        fun screenshot(name: String) {
            // Compose idleness does not include the window's dialog enter animation.
            android.os.SystemClock.sleep(500)
            val bitmap =
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
            File(context.cacheDir, name).outputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
            bitmap.recycle()
        }
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(
                    Uri.parse("https://${TaggrRuntime.domain}/user/${selectedPost.authorId}/photos")
                )
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            try {
                lateinit var account: AccountViewModel
                scenario.onActivity {
                    account = ViewModelProvider(it)[AccountViewModel::class.java]
                }
                compose.waitUntil(30000) { !account.state.value.restoring }
                assertNull(
                    "Guest-only cold-start test leaves any existing session intact.",
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
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag("photo-library").fetchSemanticsNodes().isNotEmpty()
                }
                val thumb = "photo-${selectedPost.id}-0"
                compose.waitUntil(40000) {
                    compose.onAllNodesWithTag(thumb).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithTag("photo-library").performScrollToNode(hasTestTag(thumb))
                compose.waitUntil(25000) {
                    compose
                        .onAllNodesWithContentDescription("Image from post ${selectedPost.id}")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                screenshot("photo-library-native.png")
                compose.onNodeWithTag(thumb).performClick()
                compose.onNodeWithTag("photo-viewer").assertIsDisplayed()
                compose.onNodeWithText("Post #${selectedPost.id}").assertIsDisplayed()
                screenshot("photo-viewer-native.png")
                compose.onNodeWithText("Share image").assertIsEnabled().performClick()
                assertSystemImageChooserAndCancel("normal-photo-share-chooser") {
                    compose.mainClock.advanceTimeByFrame()
                }
                compose.onNodeWithTag("photo-viewer").assertIsDisplayed()
                compose.onNodeWithText("Post #${selectedPost.id}").assertIsDisplayed()
                compose.onNodeWithText("Share image").assertIsEnabled()
                compose.onNodeWithText("Close").performClick()
                compose.onNodeWithTag("photo-library").performScrollToIndex(0)
                compose.onNodeWithText("Profile").performClick()
                compose.onNodeWithText("Photos").assertIsEnabled()
                scenario.onActivity {
                    assertNull(
                        ViewModelProvider(it)[IncomingLinksViewModel::class.java].pending.value
                    )
                }
            } finally {
                if (changed) {
                    val edit = prefs.edit()
                    if (before == null) edit.remove(key) else edit.putString(key, before)
                    assertTrue(edit.commit())
                }
            }
        }
    }
}
