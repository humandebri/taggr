package org.taggr.android.data

import android.accounts.Account
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.api.identity.*
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

internal sealed interface YouTubeAuthorization {
    class Resolution(val pendingIntent: PendingIntent) : YouTubeAuthorization

    class Access(val token: String, val account: Account, val channel: YouTubeChannel) :
        YouTubeAuthorization {
        override fun toString() = "YouTubeAuthorization.Access(redacted)"
    }
}

/** Called only for explicit YouTube actions. Google tokens stay in memory, never in upload jobs. */
internal class GoogleYouTubeAuth(
    context: Context,
    private val client: AuthorizationClient = Identity.getAuthorizationClient(context),
    private val transport: YouTubeUploadTransport = YouTubeUploadTransport(),
) {
    suspend fun authorize(
        account: Account? = null,
        expectedChannel: String? = null,
    ): YouTubeAuthorization {
        val builder = AuthorizationRequest.builder().setRequestedScopes(scopes)
        if (account != null) {
            require(account.type == "com.google")
            builder.setAccount(account)
        }
        return consume(
            client.authorize(builder.build()).awaitAuthorization(),
            account,
            expectedChannel,
        )
    }

    suspend fun finish(
        data: Intent,
        expectedAccount: Account? = null,
        expectedChannel: String? = null,
    ): YouTubeAuthorization =
        consume(client.getAuthorizationResultFromIntent(data), expectedAccount, expectedChannel)

    /** A worker must return authorization-required instead of launching this resolution itself. */
    private suspend fun consume(
        result: AuthorizationResult,
        expectedAccount: Account?,
        expectedChannel: String?,
    ): YouTubeAuthorization {
        if (result.hasResolution())
            return YouTubeAuthorization.Resolution(requireNotNull(result.pendingIntent))
        require(result.grantedScopes.containsAll(scopes.map { it.scopeUri })) {
            "Allow YouTube upload, channel access and account email to connect."
        }
        val token =
            requireNotNull(result.accessToken?.takeIf { it.isNotBlank() }) {
                "Google returned no access token."
            }
        val account = Account(transport.googleAccountEmail(token), "com.google")
        require(expectedAccount == null || account == expectedAccount) {
            "Connect the Google account selected for this upload."
        }
        return YouTubeAuthorization.Access(
            token,
            account,
            transport.channel(token, expectedChannel),
        )
    }

    suspend fun clearExpiredToken(access: YouTubeAuthorization.Access) {
        client
            .clearToken(ClearTokenRequest.builder().setToken(access.token).build())
            .awaitAuthorization()
    }

    suspend fun revoke(account: Account) {
        require(account.type == "com.google")
        client
            .revokeAccess(
                RevokeAccessRequest.builder().setAccount(account).setScopes(scopes).build()
            )
            .awaitAuthorization()
    }

    companion object {
        val scopes =
            listOf(
                Scope("https://www.googleapis.com/auth/youtube.upload"),
                Scope("https://www.googleapis.com/auth/youtube.readonly"),
                Scope("https://www.googleapis.com/auth/userinfo.email"),
            )
    }
}

private suspend fun <T> Task<T>.awaitAuthorization(): T =
    suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
        addOnFailureListener { if (continuation.isActive) continuation.resumeWithException(it) }
        addOnCanceledListener { continuation.cancel() }
    }
