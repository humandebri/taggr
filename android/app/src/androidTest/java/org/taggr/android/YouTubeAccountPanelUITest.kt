package org.taggr.android

import android.accounts.Account
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.gms.auth.api.identity.*
import com.google.android.gms.tasks.*
import java.lang.reflect.Proxy
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

/** Real panel/SDK classes, scripted Google replies; never changes a real Google account. */
@RunWith(AndroidJUnit4::class)
@Suppress("DEPRECATION")
class YouTubeAccountPanelUITest {
    @get:Rule val compose = createComposeRule()
    private val connected = mutableStateOf<YouTubeAuthorization.Access?>(null)
    private val calls = AtomicInteger()
    private val revoked = AtomicInteger()
    private val changes = AtomicInteger()
    private var currentOwner: String? = "owner"

    private fun result() =
        AuthorizationResult(
            null,
            "fixture-token",
            null,
            GoogleYouTubeAuth.scopes.map { it.scopeUri },
            null,
            null,
        )

    private fun show(
        reply: Task<AuthorizationResult> = Tasks.forResult(result()),
        owner: String? = "owner",
    ) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val client =
            Proxy.newProxyInstance(
                AuthorizationClient::class.java.classLoader,
                arrayOf(AuthorizationClient::class.java),
            ) { _, method, args ->
                when (method.name) {
                    "authorize" -> {
                        calls.incrementAndGet()
                        reply
                    }
                    "revokeAccess" -> {
                        val request = args!![0] as RevokeAccessRequest
                        assertEquals(Account("test@example.test", "com.google"), request.account)
                        assertEquals(GoogleYouTubeAuth.scopes, request.scopes)
                        revoked.incrementAndGet()
                        Tasks.forResult<Void>(null)
                    }
                    else -> error("Unexpected Google call: ${method.name}")
                }
            } as AuthorizationClient
        val transport =
            YouTubeUploadTransport(
                OkHttpClient.Builder()
                    .addInterceptor { chain ->
                        val request = chain.request()
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
        val auth = GoogleYouTubeAuth(context, client, transport)
        compose.setContent {
            TaggrTheme {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                    YouTubeAccountPanel(
                        owner,
                        { currentOwner },
                        connected.value,
                        {
                            changes.incrementAndGet()
                            connected.value = it
                        },
                        auth,
                    )
                }
            }
        }
    }

    @Test
    fun connectDisplaysChannelAndDisconnectRequiresConfirmation() {
        show()
        compose.runOnIdle { assertEquals(0, calls.get()) }
        compose.onNodeWithText("Connect YouTube").performClick()
        compose.waitUntil(10000) { connected.value != null }
        compose.onNodeWithText("Test channel").assertIsDisplayed()
        compose.onNodeWithText("Disconnect YouTube").performClick()
        compose.runOnIdle { assertEquals(0, revoked.get()) }
        compose.onNodeWithText("Keep connected").performClick()
        compose.runOnIdle {
            assertNotNull(connected.value)
            assertEquals(0, revoked.get())
        }
        compose.onNodeWithText("Disconnect YouTube").performClick()
        compose.onNodeWithText("Disconnect", substring = false).performClick()
        compose.waitUntil(10000) { connected.value == null }
        compose.onNodeWithText("Connect YouTube").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(1, revoked.get())
            assertEquals(2, changes.get())
        }
    }

    @Test
    fun guestCanExplicitlyConnectWithoutCreatingTaggrIdentity() {
        currentOwner = null
        show(owner = null)
        compose.runOnIdle {
            assertEquals(0, calls.get())
            assertNull(currentOwner)
        }
        compose.onNodeWithText("Connect YouTube").performClick()
        compose.waitUntil(10000) { connected.value != null }
        compose.onNodeWithText("Test channel").assertIsDisplayed()
        compose.runOnIdle {
            assertNull(currentOwner)
            assertEquals(1, calls.get())
            assertEquals(0, revoked.get())
        }
    }

    @Test
    fun failedAuthorizationShowsRetryWithoutConnectionOrRevocation() {
        show(Tasks.forException(IllegalStateException("fixture")))
        compose.onNodeWithText("Connect YouTube").performClick()
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("YouTube connection could not be updated.", substring = true)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithText("Connect YouTube").assertIsEnabled()
        compose.runOnIdle {
            assertNull(connected.value)
            assertEquals(0, changes.get())
            assertEquals(0, revoked.get())
        }
    }

    @Test
    fun lateAuthorizationForPreviousTaggrOwnerDoesNotInstallConnection() {
        val pending = TaskCompletionSource<AuthorizationResult>()
        show(pending.task)
        compose.onNodeWithText("Connect YouTube").performClick()
        compose.runOnIdle {
            currentOwner = "different-owner"
            pending.setResult(result())
        }
        compose.waitUntil(10000) {
            compose
                .onAllNodesWithText("YouTube connection could not be updated.", substring = true)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.runOnIdle {
            assertNull(connected.value)
            assertEquals(0, changes.get())
            assertEquals(0, revoked.get())
        }
    }
}
