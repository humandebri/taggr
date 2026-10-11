package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PostHiddenUITest {
    @get:Rule val compose = createComposeRule()

    private fun captureNotice() {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.cacheDir, "post-hidden-native.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }

    private fun post(body: String = "Hidden body", restriction: String? = null) =
        TaggrPost(42, "Alice", body, null, 0, emptyList(), 0, 0, restriction, hiddenFor = setOf(7))

    @Test
    fun revealIsLocalAndResetsWhenViewerChangesWhileUnhideControlUsesServerState() {
        val viewer = mutableStateOf<Long?>(7)
        val hidden = mutableStateOf(true)
        val busy = mutableStateOf(false)
        val requests = mutableListOf<Boolean>()
        compose.setContent {
            TaggrTheme {
                CompositionLocalProvider(LocalPostViewer provides viewer.value) {
                    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
                        PostContent(
                            post().copy(hiddenFor = if (hidden.value) setOf(7) else emptySet()),
                            true,
                        )
                        PostHideControl(viewer.value != null, hidden.value, busy.value) {
                            requests.add(it)
                            busy.value = true
                        }
                    }
                }
            }
        }
        captureNotice()
        Assert.assertTrue(
            compose.onRoot(useUnmergedTree = true).printToString(),
            compose.onAllNodesWithText("Show").fetchSemanticsNodes().isNotEmpty(),
        )
        compose.onNodeWithText("Hidden body").assertDoesNotExist()
        compose.onNodeWithText("Show").performClick()
        compose.onNodeWithText("Hidden body").assertIsDisplayed()
        compose.onNodeWithText("Unhide").assertIsDisplayed()
        compose.runOnIdle { viewer.value = 8 }
        compose.onNodeWithText("Hidden body").assertIsDisplayed()
        compose.runOnIdle { viewer.value = 7 }
        compose.onNodeWithText("Hidden body").assertDoesNotExist()
        compose.onNodeWithText("Unhide").performClick()
        compose.onNodeWithText("Unhide").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            Assert.assertEquals(listOf(false), requests)
            hidden.value = false
            busy.value = false
        }
        compose.onNodeWithText("Hidden body").assertIsDisplayed()
        compose.onNodeWithText("Hide").performClick()
        compose.runOnIdle {
            Assert.assertEquals(listOf(false, true), requests)
            viewer.value = null
        }
        compose.onNodeWithText("Hide").assertDoesNotExist()
    }

    @Test
    fun decodedDeletedHashesShowOnlyPrefixesAndNeverRevealRestrictedBody() {
        fun decoded(encrypted: Boolean = false, moderated: Boolean = false) =
            TaggrPost.decodeEnvelopes(
                    """[[{"id":42,"user":7,"body":"Secret caption\n\n![Private image](https://example.test/private.png)\n\nhttps://youtu.be/M7lc1UVf-VE","hashes":["0123456789abcdef0123456789abcdef","fedcba9876543210fedcba9876543210"],"encrypted":$encrypted},{"author_name":"Alice","max_downvotes_reached":$moderated}]]"""
                        .toByteArray()
                )
                .single()
        val current = mutableStateOf(decoded())
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
                    PostContent(current.value, true)
                }
            }
        }
        compose.onNodeWithText("This post has been deleted.").assertIsDisplayed()
        compose
            .onNodeWithTag("deleted-post-hashes-42")
            .assertTextEquals("0123456789abcdef\nfedcba9876543210")
        compose.onNodeWithText("Secret caption", substring = true).assertDoesNotExist()
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").assertDoesNotExist()
        compose.onNodeWithText("Show").assertDoesNotExist()
        compose.runOnIdle { current.value = decoded(encrypted = true) }
        compose.onNodeWithText("This post is encrypted.").assertIsDisplayed()
        compose.onNodeWithTag("deleted-post-hashes-42").assertDoesNotExist()
        compose.runOnIdle { current.value = decoded(moderated = true) }
        compose.onNodeWithText("This post has been moderated.").assertIsDisplayed()
        compose.onNodeWithTag("deleted-post-hashes-42").assertDoesNotExist()
        compose.onNodeWithText("Secret caption", substring = true).assertDoesNotExist()
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").assertDoesNotExist()
    }

    @Test
    fun hiddenVideoCreatesNoPlayerAndOtherRestrictionsCannotBeRevealed() {
        val restricted = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                CompositionLocalProvider(LocalPostViewer provides 7L) {
                    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
                        PostContent(
                            post(
                                "https://youtu.be/M7lc1UVf-VE",
                                if (restricted.value) "Post deleted" else null,
                            ),
                            true,
                        )
                    }
                }
            }
        }
        captureNotice()
        Assert.assertTrue(
            compose.onRoot(useUnmergedTree = true).printToString(),
            compose.onAllNodesWithText("Show").fetchSemanticsNodes().isNotEmpty(),
        )
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").assertDoesNotExist()
        compose.onNodeWithText("Show").assertIsDisplayed()
        compose.runOnIdle { restricted.value = true }
        compose.onNodeWithText("Post deleted").assertIsDisplayed()
        compose.onNodeWithText("Show").assertDoesNotExist()
        compose.onNodeWithTag("youtube-M7lc1UVf-VE").assertDoesNotExist()
    }
}
