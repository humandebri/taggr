package org.taggr.android

import android.accounts.Account
import android.content.Context
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.gms.auth.api.identity.*
import com.google.android.gms.tasks.Tasks
import java.io.ByteArrayInputStream
import java.lang.reflect.Proxy
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

/** Scripted SDK/HTTP replies with real sheet, Keystore store and draft persistence. */
@RunWith(AndroidJUnit4::class)
@Suppress("DEPRECATION")
class YouTubeUploadCompletionUITest {
    @get:Rule val compose = createComposeRule()
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val target = YouTubeDraftTarget("owner", "network", "canister", "channel", "reply/42")
    private val revoked = AtomicInteger()
    private val httpCalls = AtomicInteger()

    private fun auth(): GoogleYouTubeAuth {
        val client =
            Proxy.newProxyInstance(
                AuthorizationClient::class.java.classLoader,
                arrayOf(AuthorizationClient::class.java),
            ) { _, method, args ->
                when (method.name) {
                    "authorize" ->
                        Tasks.forResult(
                            AuthorizationResult(
                                null,
                                "fixture-token",
                                null,
                                GoogleYouTubeAuth.scopes.map { it.scopeUri },
                                null,
                                null,
                            )
                        )
                    "revokeAccess" -> {
                        val request = args!![0] as RevokeAccessRequest
                        Assert.assertEquals(
                            Account("test@example.test", "com.google"),
                            request.account,
                        )
                        Assert.assertEquals(GoogleYouTubeAuth.scopes, request.scopes)
                        revoked.incrementAndGet()
                        Tasks.forResult<Void>(null)
                    }
                    else -> error("Unexpected Google call ${method.name}")
                }
            } as AuthorizationClient
        val api =
            YouTubeUploadTransport(
                OkHttpClient.Builder()
                    .addInterceptor { chain ->
                        val request = chain.request()
                        httpCalls.incrementAndGet()
                        val body =
                            when (request.url.encodedPath) {
                                "/oauth2/v3/userinfo" ->
                                    "{\"email\":\"test@example.test\",\"email_verified\":true}"
                                "/youtube/v3/channels" ->
                                    "{\"items\":[{\"id\":\"channel\",\"snippet\":{\"title\":\"Test channel\"}}]}"
                                else -> error("Unexpected upload request")
                            }
                        Response.Builder()
                            .request(request)
                            .protocol(Protocol.HTTP_1_1)
                            .code(200)
                            .message("fixture")
                            .body(body.toResponseBody())
                            .build()
                    }
                    .build()
            )
        return GoogleYouTubeAuth(context, client, api)
    }

    private fun receipt(store: YouTubeUploadJobStore) = runBlocking {
        val initial =
            store.create(
                ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                target,
                YouTubeUploadMetadata(
                    "Completed video",
                    madeForKids = false,
                    communityGuidelinesAccepted = true,
                ),
                "video/mp4",
            )
        val done =
            initial.copy(
                phase = YouTubeJobPhase.COMPLETED,
                acknowledgedBytes = 3,
                sessionUrl = "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=done",
                videoId = "M7lc1UVf-VE",
            )
        store.save(done, initial)
        done
    }

    @Test
    fun unreadableWrongAccountRecordRequiresExplicitDiscardAndKeepPreservesIt() {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val done = receipt(store)
        val auth = auth()
        try {
            compose.setContent {
                TaggrTheme {
                    YouTubeUploadScreen(
                        "other-owner",
                        "network",
                        "canister",
                        "reply/42",
                        { "other-owner" },
                        { error("Unexpected insertion") },
                        {},
                        auth,
                        store,
                    )
                }
            }
            compose.onNodeWithText("Connect YouTube").performClick()
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Discard saved upload").fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithText("Choose video").assertDoesNotExist()
            compose.onNodeWithText("Discard saved upload").performScrollTo().performClick()
            compose.onNodeWithText("Keep saved upload").performClick()
            Assert.assertEquals(done, runBlocking { store.load(target) })
            compose.onNodeWithText("Discard saved upload").performScrollTo().performClick()
            compose.onNodeWithText("Discard local upload").performClick()
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Choose video").fetchSemanticsNodes().size == 1
            }
            Assert.assertNull(runBlocking { store.load(target) })
            Assert.assertEquals(2, httpCalls.get())
            Assert.assertEquals(0, revoked.get())
        } finally {
            runBlocking { store.clear(target) }
        }
    }

    @Test
    fun restoredReceiptInsertsOriginalReplyDraftAndClearsOnlyItsUpload() {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val done = receipt(store)
        val prefsName = "youtube-ui-draft-" + UUID.randomUUID()
        val drafts = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val key = "canister/owner/reply/42"
        Assert.assertTrue(
            drafts
                .edit()
                .putString(key, "Retained reply")
                .putString("canister/owner/new", "Other draft")
                .commit()
        )
        val open = mutableStateOf(true)
        val auth = auth()
        try {
            compose.setContent {
                TaggrTheme {
                    if (open.value)
                        YouTubeUploadScreen(
                            "owner",
                            "network",
                            "canister",
                            "reply/42",
                            { "owner" },
                            {
                                YouTubeDraftInsertion.insert(
                                    drafts,
                                    key,
                                    it,
                                    target,
                                    "stale fallback",
                                )
                            },
                            { open.value = false },
                            auth,
                            YouTubeUploadJobStore(context, namespace),
                        )
                }
            }
            compose.onNodeWithText("Connect YouTube").performClick()
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Use video in post").fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithText("Use video in post").performScrollTo().performClick()
            compose.waitUntil(10000) { !open.value }
            Assert.assertEquals(
                "Retained reply\n\nhttps://www.youtube.com/watch?v=M7lc1UVf-VE",
                drafts.getString(key, null),
            )
            Assert.assertEquals("Other draft", drafts.getString("canister/owner/new", null))
            Assert.assertNull(runBlocking { store.load(target, System.currentTimeMillis()) })
            Assert.assertEquals(
                drafts.getString(key, null),
                YouTubeDraftInsertion.insert(drafts, key, done, target, "stale fallback"),
            )
            Assert.assertEquals(2, httpCalls.get())
            Assert.assertEquals(0, revoked.get())
        } finally {
            runBlocking { store.clear(target) }
            context.deleteSharedPreferences(prefsName)
        }
    }

    @Test
    fun sharedConnectionRestoresCompletedUploadWithoutAnotherAuthorization() {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val done = receipt(store)
        val auth = auth()
        var inserted: YouTubeUploadJob? = null
        try {
            compose.setContent {
                TaggrTheme {
                    YouTubeUploadScreen(
                        "owner",
                        "network",
                        "canister",
                        "reply/42",
                        { "owner" },
                        { inserted = it },
                        {},
                        auth,
                        store,
                        initialAccess =
                            YouTubeAuthorization.Access(
                                "fixture-token",
                                Account("test@example.test", "com.google"),
                                YouTubeChannel("channel", "Test channel"),
                            ),
                    )
                }
            }
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Use video in post").fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithText("Connect YouTube").assertDoesNotExist()
            compose.onNodeWithText("Use video in post").performScrollTo().performClick()
            compose.waitUntil(10000) { inserted != null }
            Assert.assertEquals(done, inserted)
            Assert.assertEquals(0, httpCalls.get())
            Assert.assertEquals(0, revoked.get())
        } finally {
            runBlocking { store.clear(target) }
        }
    }

    @Test
    fun disconnectRequiresConfirmationAndPreservesSavedReceipt() {
        val store = YouTubeUploadJobStore(context, "test-" + UUID.randomUUID())
        val done = receipt(store)
        val auth = auth()
        try {
            compose.setContent {
                TaggrTheme {
                    YouTubeUploadScreen(
                        "owner",
                        "network",
                        "canister",
                        "reply/42",
                        { "owner" },
                        { error("Unexpected insertion") },
                        {},
                        auth,
                        store,
                    )
                }
            }
            compose.onNodeWithText("Connect YouTube").performClick()
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Disconnect YouTube").fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithText("Disconnect YouTube").performClick()
            compose.onNodeWithText("Keep connected").performClick()
            Assert.assertEquals(0, revoked.get())
            compose.onNodeWithText("Disconnect YouTube").performClick()
            compose.onNodeWithText("Disconnect", substring = false).performClick()
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Connect YouTube").fetchSemanticsNodes().size == 1
            }
            Assert.assertEquals(1, revoked.get())
            Assert.assertEquals(
                done,
                runBlocking { store.load(target, System.currentTimeMillis()) },
            )
            Assert.assertEquals(2, httpCalls.get())
        } finally {
            runBlocking { store.clear(target) }
        }
    }
}
