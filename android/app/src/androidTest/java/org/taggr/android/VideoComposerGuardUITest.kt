package org.taggr.android

import android.os.PersistableBundle
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.YouTubeBackground
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class VideoComposerGuardUITest {
    @get:Rule val compose = createComposeRule()
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun values(slot: String) =
        PersistableBundle().apply {
            putString("owner", "owner")
            putString("network", "network")
            putString("canister", "canister")
            putString("draft", slot)
        }

    private fun running(slot: String) =
        YouTubeBackground.isRunningForDraft(context, "owner", "network", "canister", slot)

    @Test
    fun matchingDraftCannotSubmitUntilSendingStopsWhileAnotherDraftCan() {
        val key = "fixture-" + UUID.randomUUID()
        val work = Job()
        YouTubeBackground.track(key, values("reply/42"), work)
        var submissions = 0
        var otherSubmissions = 0
        val uploading = mutableStateOf(running("reply/42"))
        try {
            compose.setContent {
                TaggrTheme {
                    Column {
                        PostSubmitAction("Submit", true, uploading.value) { submissions++ }
                        PostSubmitAction("Other post", true, running("new")) { otherSubmissions++ }
                    }
                }
            }
            compose.onNodeWithText("Submit").assertIsNotEnabled().performClick()
            compose.onNodeWithText("Other post").assertIsEnabled().performClick()
            compose.runOnIdle {
                assertEquals(0, submissions)
                assertEquals(1, otherSubmissions)
            }
            YouTubeBackground.untrack(key, work)
            compose.runOnIdle { uploading.value = running("reply/42") }
            compose.onNodeWithText("Submit").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(1, submissions) }
        } finally {
            YouTubeBackground.untrack(key, work)
            work.cancel()
        }
    }

    @Test
    fun staleCompletionCannotRemoveReplacementDraftOwnership() {
        val key = "fixture-" + UUID.randomUUID()
        val old = Job()
        val replacement = Job()
        try {
            YouTubeBackground.track(key, values("reply/42"), old)
            YouTubeBackground.track(key, values("edit/43"), replacement)
            YouTubeBackground.untrack(key, old)
            assertFalse(running("reply/42"))
            assertTrue(running("edit/43"))
            YouTubeBackground.untrack(key, replacement)
            assertFalse(running("edit/43"))
        } finally {
            YouTubeBackground.untrack(key, replacement)
            old.cancel()
            replacement.cancel()
        }
    }
}
