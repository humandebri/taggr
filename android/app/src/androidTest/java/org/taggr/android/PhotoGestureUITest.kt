package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PhotoGestureUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun offCenterPinchKeepsTheTouchedImageFeatureAndPanCannotExposeEmptySpace() {
        val bitmap =
            Bitmap.createBitmap(400, 400, Bitmap.Config.ARGB_8888).apply {
                eraseColor(android.graphics.Color.WHITE)
                for (x in 275..285) for (y in 195..205) setPixel(x, y, android.graphics.Color.RED)
            }
        compose.setContent {
            ZoomablePhoto(
                bitmap,
                "Gesture photo",
                Modifier.size(300.dp).background(Color.Black).testTag("gesture-viewport"),
                {},
            )
        }
        val viewport = compose.onNodeWithTag("gesture-viewport")
        val image = compose.onNodeWithContentDescription("Gesture photo")
        val beforeImage = viewport.captureToImage()
        val before = redCenter(beforeImage)
        viewport.performTouchInput {
            pinch(
                start0 = before - Offset(24f, 0f),
                end0 = before - Offset(96f, 0f),
                start1 = before + Offset(24f, 0f),
                end1 = before + Offset(96f, 0f),
            )
        }
        val percentage =
            image
                .fetchSemanticsNode()
                .config[SemanticsProperties.StateDescription]
                .substringBefore('%')
                .toInt()
        assertTrue("Pinch actually enlarged the image: $percentage", percentage > 200)
        val after = redCenter(viewport.captureToImage())
        assertEquals("Touched feature X stays under the fingers", before.x, after.x, 6f)
        assertEquals("Touched feature Y stays under the fingers", before.y, after.y, 6f)
        repeat(8) {
            viewport.performTouchInput {
                swipe(
                    Offset(width * .35f, height * .35f),
                    Offset(width * .85f, height * .85f),
                    durationMillis = 200,
                )
            }
        }
        val panned = viewport.captureToImage().toPixelMap()
        for (point in
            listOf(
                2 to 2,
                2 to (panned.height - 3),
                (panned.width - 3) to 2,
                (panned.width - 3) to (panned.height - 3),
            )) {
            val pixel = panned[point.first, point.second]
            assertTrue(
                "Clamped image still covers viewport corner $point",
                pixel.red > .9f && pixel.green > .9f && pixel.blue > .9f,
            )
        }
        viewport.performTouchInput { doubleClick() }
        image.assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100% zoom")
        )
        val reset = redCenter(viewport.captureToImage())
        assertEquals(before.x, reset.x, 1f)
        assertEquals(before.y, reset.y, 1f)
    }

    private fun redCenter(image: ImageBitmap): Offset {
        val pixels = image.toPixelMap()
        var count = 0
        var xTotal = 0L
        var yTotal = 0L
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val pixel = pixels[x, y]
            if (pixel.red > .9f && pixel.green < .1f && pixel.blue < .1f) {
                count++
                xTotal += x
                yTotal += y
            }
        }
        assertTrue("The image feature is visible", count > 0)
        return Offset(xTotal.toFloat() / count, yTotal.toFloat() / count)
    }
}
