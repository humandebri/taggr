package org.taggr.android

import android.content.ContextWrapper
import android.content.Intent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrRuntime
import org.taggr.android.ui.PostShareButton
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostShareUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun sharesOnlyThePostURLThroughTheSystemChooser() {
        var launched: Intent? = null
        compose.setContent {
            val base = LocalContext.current
            val context =
                object : ContextWrapper(base) {
                    override fun startActivity(intent: Intent) {
                        launched = intent
                    }
                }
            CompositionLocalProvider(LocalContext provides context) {
                TaggrTheme { PostShareButton(42) }
            }
        }
        compose.onNodeWithText("Share").assertIsDisplayed().performClick()
        compose.runOnIdle {
            val chooser = requireNotNull(launched)
            assertEquals(Intent.ACTION_CHOOSER, chooser.action)
            assertEquals("Share post", chooser.getCharSequenceExtra(Intent.EXTRA_TITLE))
            @Suppress("DEPRECATION")
            val send = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
            assertEquals(Intent.ACTION_SEND, send.action)
            assertEquals("text/plain", send.type)
            val url = send.getStringExtra(Intent.EXTRA_TEXT)
            assertEquals("https://${TaggrRuntime.domain}/post/42", url)
            assertEquals(TaggrLink.Post(42), TaggrLinks.parse(url!!, TaggrRuntime.domain))
            assertEquals(setOf(Intent.EXTRA_TEXT), send.extras!!.keySet())
        }
    }
}
