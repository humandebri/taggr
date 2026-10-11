package org.taggr.android

import android.accounts.Account
import android.app.Application
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.security.SecureRandom
import kotlinx.coroutines.runBlocking
import org.ic4j.agent.android.ICClient
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

/** Real SDK self-delegation, Keystore, ViewModels and composer; public IC reads only. */
@RunWith(AndroidJUnit4::class)
class ComposerAutomaticVideoUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun composerAutomaticallyConsumesReceiptAndSeparatesOwnerWithoutPublishing() {
        val config = TaggrRuntime.configuration()
        val client = ICClient(config)
        val sessions = client.sessionStore(context, "taggr-account")
        val existing = client.loadSession(sessions)
        if (existing != null) {
            existing.close()
            client.close()
            fail("This fixture requires the dedicated guest AVD")
        }
        val videoStore = YouTubeUploadJobStore(context)
        assertNull(runBlocking { videoStore.discardSnapshot() })
        val firstStore = ViewModelStore()
        val secondStore = ViewModelStore()
        val application = context.applicationContext as Application
        val factory = ViewModelProvider.AndroidViewModelFactory(application)
        val parent = System.currentTimeMillis() + 9000000000000L
        val prefs = context.getSharedPreferences("taggr-drafts", Context.MODE_PRIVATE)
        val keys = mutableListOf<String>()
        var target: YouTubeDraftTarget? = null
        var seeded = false
        fun seed(): String {
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            try {
                client.delegatingSession(bytes).use {
                    sessions.save(it)
                    seeded = true
                    return it.principal().toString()
                }
            } finally {
                bytes.fill(0)
            }
        }
        try {
            val firstOwner = seed()
            lateinit var first: AccountViewModel
            compose.runOnIdle {
                first = ViewModelProvider(firstStore, factory)[AccountViewModel::class.java]
            }
            compose.waitUntil(30000) { !first.state.value.restoring }
            assertEquals(firstOwner, first.state.value.principal)
            target =
                YouTubeDraftTarget(
                    firstOwner,
                    financialNetwork(config),
                    config.canisterId,
                    "fixture-channel",
                    "reply/$parent",
                )
            val originalTarget = target!!
            val key = "${config.canisterId}/$firstOwner/$parent"
            keys += key
            runBlocking {
                val pending =
                    videoStore.create(
                        ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                        originalTarget,
                        YouTubeUploadMetadata(
                            "Fixture",
                            madeForKids = false,
                            communityGuidelinesAccepted = true,
                        ),
                        "video/mp4",
                        googleAccountEmail = "test@example.test",
                    )
                videoStore.save(
                    pending.copy(
                        phase = YouTubeJobPhase.COMPLETED,
                        acknowledgedBytes = 3,
                        sessionUrl =
                            "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=composer-fixture",
                        videoId = "M7lc1UVf-VE",
                    ),
                    pending,
                )
            }
            compose.runOnIdle {
                first.saveDraft(parent, "Retained reply")
                first.setYouTubeAccess(
                    firstOwner,
                    YouTubeAuthorization.Access(
                        "fixture-token",
                        Account("test@example.test", "com.google"),
                        YouTubeChannel("fixture-channel", "Fixture channel"),
                    ),
                )
            }
            val selected = mutableStateOf(first)
            compose.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        PostComposer(
                            selected.value,
                            parent,
                            null,
                            {},
                            inline = true,
                            completed = { error("Unexpected publication") },
                        )
                    }
                }
            }
            val body = "Retained reply\n\nhttps://www.youtube.com/watch?v=M7lc1UVf-VE"
            compose.waitUntil(15000) { prefs.getString(key, null) == body }
            compose.onNode(hasSetTextAction()).assertTextContains(body)
            compose.waitUntil(10000) { runBlocking { videoStore.progress(originalTarget) } == null }
            val secondOwner = seed()
            lateinit var second: AccountViewModel
            compose.runOnIdle {
                second = ViewModelProvider(secondStore, factory)[AccountViewModel::class.java]
            }
            compose.waitUntil(30000) { !second.state.value.restoring }
            assertEquals(secondOwner, second.state.value.principal)
            keys += "${config.canisterId}/$secondOwner/$parent"
            compose.runOnIdle { selected.value = second }
            compose.waitUntil(10000) {
                compose.onAllNodes(hasSetTextAction() and isEnabled()).fetchSemanticsNodes().size ==
                    1
            }
            compose
                .onNodeWithText("https://www.youtube.com/watch?v=M7lc1UVf-VE", substring = true)
                .assertDoesNotExist()
            compose.onNode(hasSetTextAction()).performTextReplacement("Second owner draft")
            compose.runOnIdle {
                assertEquals("Second owner draft", second.readDraft(parent))
                assertEquals(body, prefs.getString(key, null))
                selected.value = first
            }
            try {
                compose.waitUntil(10000) {
                    compose
                        .onAllNodesWithText(body, substring = true)
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
            } catch (failure: androidx.compose.ui.test.ComposeTimeoutException) {
                throw AssertionError(
                    "Retained body: ${prefs.getString(key, null)}\n" +
                        compose.onRoot(useUnmergedTree = true).printToString(),
                    failure,
                )
            }
            compose.onNode(hasSetTextAction()).assertTextContains(body)
            assertEquals(body, prefs.getString(key, null))
        } finally {
            compose.runOnIdle {
                firstStore.clear()
                secondStore.clear()
            }
            target?.let { runBlocking { videoStore.clear(it) } }
            keys.forEach { YouTubeDraftInsertion.clear(prefs, it) }
            if (seeded) sessions.clear()
            client.close()
        }
    }
}
