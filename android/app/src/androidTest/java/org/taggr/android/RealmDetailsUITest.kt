package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class RealmDetailsUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun cardShowsRulesCountsControllerProfileAndMalformedLogoFallback() {
        var profile: String? = null
        val details =
            RealmDetails(
                "**Realm rules**",
                "#AABBCC",
                "invalid-logo",
                123uL,
                45uL,
                25,
                "Limited to 2 approved users",
                "Realm posting rules apply",
                listOf(7uL),
            )
        val color = mutableStateOf(details.labelColor)
        compose.setContent {
            TaggrTheme {
                RealmDetailsCard(
                    "TEST",
                    details.copy(labelColor = color.value),
                    mapOf(7uL to "alice"),
                ) {
                    profile = it
                }
            }
        }
        fun capture(name: String) {
            val run = InstrumentationRegistry.getArguments().getString("ui_capture_run") ?: return
            compose.waitForIdle()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val output = File(context.getExternalFilesDir(null), "ui-checks/$run")
            check(output.mkdirs() || output.isDirectory)
            val bitmap =
                requireNotNull(
                    InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                )
            File(output, "$name.png").outputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
            bitmap.recycle()
        }
        capture("realm-initials-light")
        compose.runOnIdle { color.value = "#102030" }
        compose.onNodeWithText("TE").assertIsDisplayed()
        capture("realm-initials-dark")
        compose.onNodeWithText("123 members · 45 posts").assertIsDisplayed()
        compose.onNodeWithText("Posting: Limited to 2 approved users").assertIsDisplayed()
        compose.onNodeWithText("Cleanup penalty: 25 credits").assertIsDisplayed()
        compose.onNodeWithText("TE").assertIsDisplayed()
        compose.onNodeWithContentDescription("Realm logo").assertDoesNotExist()
        compose.onNodeWithText("@alice").performClick()
        compose.runOnIdle { assertEquals("7", profile) }
    }

    @Test
    fun nativeLogoDecoderSamplesLargeCompressedImageWithinItsAllocationLimit() {
        val bitmap = Bitmap.createBitmap(1024, 1024, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.BLUE)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        val encoded = java.util.Base64.getEncoder().encodeToString(out.toByteArray())
        val decoded = RealmLogo.decode(encoded)!!
        assertTrue(decoded.width <= 256 && decoded.height <= 256)
        assertTrue(decoded.allocationByteCount <= 256 * 256 * 4)
        decoded.recycle()
        assertNull(RealmLogo.decode("A".repeat(65537)))
        assertNull(RealmLogo.decode("not-base64"))
    }

    @Test
    fun nativePublicRealmMetadataAndControllerNamesReadFromPinnedMainnet() = runBlocking {
        val api = TaggrApi()
        try {
            val all = api.jsonQuery("all_realms", listOf(TaggrRuntime.domain, "popularity", 0))
            val row = all.first { !it[1].path("adult_content").asBoolean() }
            val raw = api.jsonQuery("realms", listOf(listOf(row[0].asText()))).first()
            val details = RealmDetails.decode(raw)
            assertTrue(details.description.isNotBlank())
            assertTrue(details.members > 0uL)
            if (details.controllers.isNotEmpty()) {
                val names =
                    api.jsonQuery(
                        "users_data",
                        listOf(details.controllers.map { java.math.BigInteger(it.toString()) }),
                    )
                assertTrue(names.isObject)
                assertTrue(details.controllers.any { names.path(it.toString()).isTextual })
            }
        } finally {
            api.close()
        }
    }
}
