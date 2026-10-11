package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import java.util.Base64
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.RealmLogo
import org.taggr.android.data.RealmSettingsDraft
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class RealmLogoPreviewTest {
    @get:Rule val compose = createComposeRule()

    private fun logo(color: Int): String {
        val source = Bitmap.createBitmap(1024, 1024, Bitmap.Config.ARGB_8888)
        source.eraseColor(color)
        val output = ByteArrayOutputStream()
        source.compress(Bitmap.CompressFormat.PNG, 100, output)
        source.recycle()
        return Base64.getEncoder().encodeToString(output.toByteArray())
    }

    private fun assertPreviewColor(color: Color) {
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithContentDescription("Selected Realm logo")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        val pixels =
            compose
                .onNodeWithContentDescription("Selected Realm logo")
                .performScrollTo()
                .captureToImage()
                .toPixelMap()
        assertEquals(color, pixels[pixels.width / 2, pixels.height / 2])
    }

    @Test
    fun selectedLogoIsSampledAndChangingItPreservesEditedFields() {
        val blue = logo(android.graphics.Color.BLUE)
        val red = logo(android.graphics.Color.RED)
        assertTrue(blue.length < 16384)
        val decoded = RealmLogo.decode(blue)!!
        assertTrue(decoded.width <= 256 && decoded.height <= 256)
        assertTrue(decoded.allocationByteCount <= 256 * 256 * 4)
        decoded.recycle()
        val draft =
            mutableStateOf(RealmSettingsDraft("Original", "#AABBCC", "10", "4", false, true, blue))
        compose.setContent {
            TaggrTheme {
                RealmSettingsForm(
                    "TEST",
                    draft.value,
                    500uL,
                    false,
                    true,
                    null,
                    { draft.value = it },
                    {},
                    {},
                    {},
                    logoPreview = { RealmLogoPreview(draft.value.logo) },
                )
            }
        }
        assertPreviewColor(Color.Blue)
        compose.onNodeWithText("Description").performTextReplacement("Edited rules")
        compose.runOnIdle { draft.value = draft.value.copy(logo = red) }
        assertPreviewColor(Color.Red)
        compose.runOnIdle { assertEquals("Edited rules", draft.value.description) }
    }

    @Test
    fun malformedOversizedAndRemovedLogoNeverShowThePreviousBitmap() {
        val encoded = mutableStateOf<String?>(logo(android.graphics.Color.BLUE))
        compose.setContent {
            TaggrTheme {
                androidx.compose.foundation.layout.Column { RealmLogoPreview(encoded.value) }
            }
        }
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithContentDescription("Selected Realm logo")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        for (invalid in listOf("not-base64", "A".repeat(65537), null)) {
            compose.runOnIdle { encoded.value = invalid }
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithContentDescription("Selected Realm logo")
                    .fetchSemanticsNodes()
                    .isEmpty()
            }
            compose.onNodeWithContentDescription("Selected Realm logo").assertDoesNotExist()
        }
    }
}
