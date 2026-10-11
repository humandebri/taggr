package org.taggr.android

import android.accounts.Account
import android.app.Application
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.security.SecureRandom
import java.time.Duration
import kotlinx.coroutines.runBlocking
import org.ic4j.agent.android.ICAuthenticationOptions
import org.ic4j.agent.android.ICClient
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

/** Real delegation expiry in one ViewModel/editor, without publishing or Google authorization. */
@RunWith(AndroidJUnit4::class)
class ComposerSessionExpiryUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun expiryDetachesGoogleAndOwnerEditorButRetainsDraftAndPausedUpload() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val config = TaggrRuntime.configuration()
        val client = ICClient(config)
        val sessions = client.sessionStore(context, "taggr-account")
        val videos = YouTubeUploadJobStore(context)
        val models = ViewModelStore()
        val prefs = context.getSharedPreferences("taggr-drafts", Context.MODE_PRIVATE)
        var seeded = false
        var target: YouTubeDraftTarget? = null
        var draftKey: String? = null
        try {
            val existing = client.loadSession(sessions)
            if (existing != null) {
                existing.close()
                fail("Requires the dedicated guest AVD")
            }
            assertNull(runBlocking { videos.discardSnapshot() })
            val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val owner =
                try {
                    client
                        .delegatingSession(seed, ICAuthenticationOptions(Duration.ofSeconds(45)))
                        .use {
                            sessions.save(it)
                            seeded = true
                            it.principal().toString()
                        }
                } finally {
                    seed.fill(0)
                }
            lateinit var account: AccountViewModel
            compose.runOnIdle {
                account =
                    ViewModelProvider(
                        models,
                        ViewModelProvider.AndroidViewModelFactory(
                            context.applicationContext as Application
                        ),
                    )[AccountViewModel::class.java]
            }
            compose.waitUntil(15000) { !account.state.value.restoring }
            assertEquals(owner, account.state.value.principal)
            val parent = System.currentTimeMillis() + 9000000000000L
            val body = "Expiry preserves original owner draft $parent"
            draftKey = "${config.canisterId}/$owner/$parent"
            val ownedTarget =
                YouTubeDraftTarget(
                    owner,
                    financialNetwork(config),
                    config.canisterId,
                    "fixture-channel",
                    "reply/$parent",
                )
            target = ownedTarget
            val paused = runBlocking {
                val pending =
                    videos.create(
                        ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                        ownedTarget,
                        YouTubeUploadMetadata(
                            "Expiry fixture",
                            madeForKids = false,
                            communityGuidelinesAccepted = true,
                        ),
                        "video/mp4",
                        googleAccountEmail = "test@example.test",
                    )
                pending
                    .copy(
                        phase = YouTubeJobPhase.CHECKING,
                        acknowledgedBytes = 1,
                        sessionUrl =
                            "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=expiry-fixture",
                    )
                    .also { videos.save(it, pending) }
            }
            compose.runOnIdle {
                account.saveDraft(parent, body)
                account.setYouTubeAccess(
                    owner,
                    YouTubeAuthorization.Access(
                        "fixture-token",
                        Account("test@example.test", "com.google"),
                        YouTubeChannel("fixture-channel", "Fixture channel"),
                    ),
                )
            }
            compose.setContent {
                TaggrTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        PostComposer(
                            account,
                            parent,
                            null,
                            {},
                            inline = true,
                            completed = { error("Unexpected publication") },
                        )
                    }
                }
            }
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithText(body, substring = true)
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            compose.onNode(hasSetTextAction()).assertTextContains(body)
            compose.waitUntil(60000) { account.state.value.principal == null }
            compose.waitUntil(10000) {
                account.youtubeAccess.value == null &&
                    compose
                        .onAllNodes(hasSetTextAction() and isEnabled())
                        .fetchSemanticsNodes()
                        .size == 1
            }
            compose.onNodeWithText(body, substring = true).assertDoesNotExist()
            assertTrue(account.state.value.error.orEmpty().contains("expired", ignoreCase = true))
            assertEquals(body, prefs.getString(draftKey, null))
            assertEquals(paused, runBlocking { videos.progress(ownedTarget) })
            compose.waitUntil(10000) { client.loadSession(sessions)?.also { it.close() } == null }
        } finally {
            compose.runOnIdle { models.clear() }
            target?.let { runBlocking { videos.clear(it) } }
            draftKey?.let { YouTubeDraftInsertion.clear(prefs, it) }
            if (seeded) sessions.clear()
            client.close()
        }
    }
}
