package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.time.Instant
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PhotoLibraryUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun yearGridAndFullScreenPreviousNextOpenTheSelectedSourcePost() {
        val recent = Instant.parse("2026-07-01T00:00:00Z").toEpochMilli()
        val old = Instant.parse("2025-07-01T00:00:00Z").toEpochMilli()
        val photos =
            (1L..4L).map {
                AccountPhoto(
                    it,
                    if (it == 4L) old else recent,
                    "https://images.example/$it.png",
                    "Photo caption $it",
                    0,
                )
            }
        var opened: Long? = null
        compose.setContent {
            TaggrTheme {
                PhotoLibraryContent(
                    "Alice",
                    PhotoPageState(photos, canLoadMore = false),
                    {},
                    {},
                    {},
                    { opened = it },
                    image = { _, modifier, _ -> Box(modifier.background(Color.Blue)) },
                    viewerImage = { _, modifier, _, _ -> Box(modifier.background(Color.Blue)) },
                )
            }
        }
        compose.onNodeWithText("2026").assertIsDisplayed()
        val row = (1L..3L).map { compose.onNodeWithTag("photo-$it-0").getUnclippedBoundsInRoot() }
        assertEquals(row[0].top, row[1].top)
        assertEquals(row[1].top, row[2].top)
        compose.onNodeWithTag("photo-3-0").performClick()
        compose.onNodeWithTag("photo-viewer").assertIsDisplayed()
        compose.onNodeWithText("1 of 4").assertIsDisplayed()
        compose.onNodeWithText("Previous").assertIsNotEnabled()
        compose.onNodeWithText("Next").performClick()
        compose.onNodeWithText("2 of 4").assertIsDisplayed()
        compose.onNodeWithText("Post #2").assertIsDisplayed()
        compose.onNodeWithText("Open conversation").performClick()
        compose.runOnIdle { assertEquals(2L, opened) }
        compose.onNodeWithTag("photo-viewer").assertDoesNotExist()
    }

    @Test
    fun enlargedPhotoPansWithoutPagingAndResetAllowsTheNextPhoto() {
        val photos =
            (1L..2L).map {
                AccountPhoto(it, 0L, "https://images.example/$it.png", "", 0)
            }
        compose.setContent {
            val bitmap = remember {
                Bitmap.createBitmap(320, 320, Bitmap.Config.ARGB_8888).apply {
                    eraseColor(android.graphics.Color.BLUE)
                }
            }
            TaggrTheme {
                PhotoLibraryContent(
                    "Alice",
                    PhotoPageState(photos, canLoadMore = false),
                    {},
                    {},
                    {},
                    {},
                    image = { _, modifier, _ -> Box(modifier.background(Color.Blue)) },
                    viewerImage = { photo, modifier, zoom, dismiss ->
                        ZoomablePhoto(
                            bitmap,
                            "Zoom photo ${photo.postId}",
                            modifier,
                            zoom,
                            dismiss,
                        )
                    },
                )
            }
        }
        compose.onNodeWithTag("photo-2-0").performClick()
        val photo = compose.onNodeWithContentDescription("Zoom photo 2")
        fun zoom(value: String) =
            photo.assert(
                SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.StateDescription,
                    "$value% zoom",
                )
            )
        zoom("100")
        photo.performTouchInput { doubleClick() }
        zoom("250")
        compose.onNodeWithTag("viewer-photo-2-0").performTouchInput { swipeLeft() }
        compose.onNodeWithText("Post #2").assertIsDisplayed()
        compose.onNodeWithTag("viewer-photo-2-0").performTouchInput {
            pinch(
                start0 = center - Offset(12f, 0f),
                end0 = center - Offset(120f, 0f),
                start1 = center + Offset(12f, 0f),
                end1 = center + Offset(120f, 0f),
            )
        }
        zoom("400")
        compose.onNodeWithTag("viewer-photo-2-0").performTouchInput { doubleClick() }
        zoom("100")
        compose.onNodeWithTag("viewer-photo-2-0").performTouchInput { swipeLeft() }
        compose.onNodeWithText("Post #1").assertIsDisplayed()
        compose
            .onNodeWithContentDescription("Zoom photo 1")
            .assert(
                SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.StateDescription,
                    "100% zoom",
                )
            )
    }

    @Test
    fun emptyAndRetryStatesKeepProfileAndRefreshReachable() {
        var back = false
        var retry = false
        compose.setContent {
            TaggrTheme {
                PhotoLibraryContent(
                    "Alice",
                    PhotoPageState(error = "Offline"),
                    { back = true },
                    {},
                    { retry = true },
                    {},
                )
            }
        }
        compose.onNodeWithText("Offline").assertIsDisplayed()
        compose.onNodeWithText("Retry photos").performClick()
        compose.runOnIdle { assertTrue(retry) }
        compose.onNodeWithText("Profile").performClick()
        compose.runOnIdle { assertTrue(back) }
    }
}
