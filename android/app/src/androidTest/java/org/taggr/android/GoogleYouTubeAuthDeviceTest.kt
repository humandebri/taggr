package org.taggr.android

import android.accounts.Account
import android.app.PendingIntent
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.gms.auth.api.identity.*
import com.google.android.gms.tasks.Tasks
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

/** Actual SDK request/result classes; scripted authorization and HTTP, no Google account action. */
@RunWith(AndroidJUnit4::class)
@Suppress("DEPRECATION")
class GoogleYouTubeAuthDeviceTest {
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val account = Account("test@example.test", "com.google")

    private fun result(
        token: String? = "test-token",
        granted: List<String> = GoogleYouTubeAuth.scopes.map { it.scopeUri },
        pending: PendingIntent? = null,
    ) = AuthorizationResult(null, token, null, granted, null, pending)

    private fun client(handler: (String, Array<out Any>?) -> Any?): AuthorizationClient =
        Proxy.newProxyInstance(
            AuthorizationClient::class.java.classLoader,
            arrayOf(AuthorizationClient::class.java),
        ) { _, method, args ->
            handler(method.name, args)
        } as AuthorizationClient

    private fun transport(requests: MutableList<Request>) =
        YouTubeUploadTransport(
            OkHttpClient.Builder()
                .addInterceptor { chain ->
                    val request = chain.request()
                    requests.add(request)
                    assertEquals("Bearer test-token", request.header("Authorization"))
                    val body =
                        when (request.url.encodedPath) {
                            "/oauth2/v3/userinfo" ->
                                "{\"email\":\"test@example.test\",\"email_verified\":true}"
                            "/youtube/v3/channels" ->
                                "{\"items\":[{\"id\":\"channel-1\",\"snippet\":{\"title\":\"Test channel\"}}]}"
                            else -> error("Unexpected network request")
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

    @Test
    fun accountBoundAuthorizationAndExplicitRefreshRevokeUseActualSdkRequests() = runBlocking {
        val requests = mutableListOf<Request>()
        var revoked = false
        var cleared = false
        val fake = client { method, args ->
            when (method) {
                "authorize" -> {
                    val request = args!![0] as AuthorizationRequest
                    assertEquals(account, request.account)
                    assertEquals(GoogleYouTubeAuth.scopes, request.requestedScopes)
                    assertFalse(request.isOfflineAccessRequested)
                    Tasks.forResult(result())
                }
                "clearToken" -> {
                    assertEquals("test-token", (args!![0] as ClearTokenRequest).token)
                    cleared = true
                    Tasks.forResult<Void>(null)
                }
                "revokeAccess" -> {
                    val request = args!![0] as RevokeAccessRequest
                    assertEquals(account, request.account)
                    assertEquals(GoogleYouTubeAuth.scopes, request.scopes)
                    revoked = true
                    Tasks.forResult<Void>(null)
                }
                else -> error(method)
            }
        }
        val auth = GoogleYouTubeAuth(context, fake, transport(requests))
        val access = auth.authorize(account, "channel-1") as YouTubeAuthorization.Access
        assertEquals(account, access.account)
        assertEquals("channel-1", access.channel.id)
        assertFalse(access.toString().contains("test-token"))
        assertEquals(2, requests.size)
        auth.clearExpiredToken(access)
        auth.revoke(account)
        assertTrue(cleared && revoked)
    }

    @Test
    fun partialScopesNeverFetchAccountOrChannelAndResolutionDoesNotUpload() = runBlocking {
        val requests = mutableListOf<Request>()
        val partial = client { method, _ ->
            check(method == "authorize")
            Tasks.forResult(result(granted = GoogleYouTubeAuth.scopes.drop(1).map { it.scopeUri }))
        }
        try {
            GoogleYouTubeAuth(context, partial, transport(requests)).authorize()
            fail("Partial scopes accepted")
        } catch (_: IllegalArgumentException) {}
        assertTrue(requests.isEmpty())
        val pending =
            PendingIntent.getActivity(
                context,
                39147,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE,
            )
        try {
            val resolution = client { method, _ ->
                check(method == "authorize")
                Tasks.forResult(result(token = null, granted = emptyList(), pending = pending))
            }
            assertEquals(
                pending,
                (GoogleYouTubeAuth(context, resolution, transport(requests)).authorize()
                        as YouTubeAuthorization.Resolution)
                    .pendingIntent,
            )
            assertTrue(requests.isEmpty())
        } finally {
            pending.cancel()
        }
    }

    @Test
    fun changedAccountAndChannelCannotSupplyAccessToOriginalUpload() = runBlocking {
        val requests = mutableListOf<Request>()
        val fake = client { method, _ ->
            check(method == "authorize")
            Tasks.forResult(result())
        }
        val auth = GoogleYouTubeAuth(context, fake, transport(requests))
        try {
            auth.authorize(Account("other@example.test", "com.google"), "channel-1")
            fail("Wrong account accepted")
        } catch (_: IllegalArgumentException) {}
        assertEquals(1, requests.size)
        try {
            auth.authorize(account, "other-channel")
            fail("Wrong channel accepted")
        } catch (_: IllegalArgumentException) {}
        assertEquals(3, requests.size)
    }
}
