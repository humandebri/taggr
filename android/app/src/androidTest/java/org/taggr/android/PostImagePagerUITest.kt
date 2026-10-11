package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.ImageLoader
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostImagePagerUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun postThumbnailOpensAllAttachmentsAtSelectedIndexWithZoomAndMarginDismiss() {
        val urls = (1..6).map { "https://images.example/post-pager-$it.png" }
        val bitmap =
            Bitmap.createBitmap(320, 120, Bitmap.Config.ARGB_8888).apply {
                eraseColor(android.graphics.Color.BLUE)
            }
        urls.forEach { ImageLoader.cache.put(it, bitmap) }
        try {
            val post =
                TaggrPost(
                    42,
                    "Alice",
                    urls.joinToString("\n") { "![]($it)" },
                    null,
                    0,
                    emptyList(),
                    0,
                    0,
                    null,
                )
            compose.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize()) { PostContent(post, expanded = false) }
                }
            }
            compose.waitUntil {
                compose.onAllNodesWithContentDescription("Post image").fetchSemanticsNodes().size ==
                    4
            }
            compose.onAllNodesWithContentDescription("Post image")[2].performClick()
            compose.onNodeWithTag("photo-viewer").assertIsDisplayed()
            compose.onNodeWithText("3 of 6").assertIsDisplayed()
            compose.onNodeWithText("Next").performClick()
            compose.onNodeWithText("Next").performClick()
            compose.onNodeWithText("5 of 6").assertIsDisplayed()
            val viewport = compose.onNodeWithTag("viewer-photo-42-4")
            compose.waitUntil {
                compose
                    .onAllNodes(
                        hasContentDescription("Image from post 42") and
                            hasAnyAncestor(hasTestTag("viewer-photo-42-4"))
                    )
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            val image =
                compose.onNode(
                    hasContentDescription("Image from post 42") and
                        hasAnyAncestor(hasTestTag("viewer-photo-42-4"))
                )
            image.performTouchInput { click() }
            compose.onNodeWithTag("photo-viewer").assertIsDisplayed()
            image.performTouchInput { doubleClick() }
            image.assert(
                SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "250% zoom")
            )
            viewport.performTouchInput { swipeLeft() }
            compose.onNodeWithText("5 of 6").assertIsDisplayed()
            viewport.performTouchInput { doubleClick() }
            image.assert(
                SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100% zoom")
            )
            viewport.performTouchInput { click(Offset(center.x, 2f)) }
            compose.onNodeWithTag("photo-viewer").assertDoesNotExist()
            compose.onAllNodesWithContentDescription("Post image")[0].performClick()
            compose.onNodeWithText("1 of 6").assertIsDisplayed()
            compose.onNodeWithText("Close").performClick()
            compose.onNodeWithTag("photo-viewer").assertDoesNotExist()
        } finally {
            urls.forEach { ImageLoader.cache.remove(it) }
        }
    }
}
