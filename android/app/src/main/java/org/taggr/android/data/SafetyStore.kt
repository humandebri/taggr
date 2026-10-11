package org.taggr.android.data

import android.content.Context
import com.fasterxml.jackson.databind.ObjectMapper
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class SafetyStore(context: Context) {
    private val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
    private val mapper = ObjectMapper()
    private val http = OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).build()
    @Volatile private var hiddenPosts = emptySet<Long>()
    @Volatile private var hiddenUsers = emptySet<Long>()
    @Volatile private var remoteBlocked = emptySet<Long>()
    private var principal = "guest"
    private val canister = TaggrRuntime.configuration().canisterId
    private val scope
        get() = "$canister/$principal"

    val accepted
        get() = prefs.getString("terms/$canister", null) == "2026-09-09"

    fun accept() {
        prefs.edit().putString("terms/$canister", "2026-09-09").apply()
    }

    fun account(value: String?) {
        principal = value ?: "guest"
        remoteBlocked = emptySet()
    }

    fun remoteUser(user: com.fasterxml.jackson.databind.JsonNode?) {
        remoteBlocked = user?.let { UserBlockState.decode(it).blocked } ?: emptySet()
    }

    fun blocked(id: Long): Boolean {
        val key = "block/$scope/$id"
        return if (prefs.contains(key)) prefs.getBoolean(key, false) else id in remoteBlocked
    }

    fun block(id: Long, blocked: Boolean = true) {
        prefs.edit().putBoolean("block/$scope/$id", blocked).apply()
    }

    fun allowedUser(id: Long) = id !in hiddenUsers && !blocked(id)

    fun allowed(post: TaggrPost) =
        post.id !in hiddenPosts && post.authorId !in hiddenUsers && !blocked(post.authorId)

    suspend fun refresh() =
        withContext(Dispatchers.IO) {
            try {
                val request =
                    Request.Builder()
                        .url("https://taggr.kasane.network/api/moderation?canisterID=$canister")
                        .build()
                http.newCall(request).execute().use { response ->
                    check(response.isSuccessful)
                    val body = response.body?.string() ?: error("Missing moderation response")
                    require(body.length < 1_000_000)
                    val value = mapper.readTree(body)
                    require(
                        value.path("canisterID").asText() == canister &&
                            value.path("version").asInt(-1) >=
                                prefs.getInt("moderation-version/$canister", -1)
                    )
                    val posts = value.path("postIDs").map { it.asLong(-1) }.toSet()
                    val users = value.path("userIDs").map { it.asLong(-1) }.toSet()
                    require(posts.all { it >= 0 } && users.all { it >= 0 })
                    hiddenPosts = posts
                    hiddenUsers = users
                    prefs
                        .edit()
                        .putString("moderation/$canister", body)
                        .putInt("moderation-version/$canister", value.path("version").asInt())
                        .apply()
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                /* Keep the cached moderation list if the service is unavailable. */
            }
        }

    init {
        prefs.getString("moderation/$canister", null)?.let { body ->
            runCatching {
                val value = mapper.readTree(body)
                if (value.path("canisterID").asText() == canister) {
                    hiddenPosts = value.path("postIDs").map { it.asLong() }.toSet()
                    hiddenUsers = value.path("userIDs").map { it.asLong() }.toSet()
                }
            }
        }
    }

    suspend fun report(id: String, user: Long, post: Long?, reason: String) =
        withContext(Dispatchers.IO) {
            require(reason.trim().length >= 10) {
                "Describe the concern in at least 10 characters."
            }
            UUID.fromString(id)
            val payload =
                mapper.writeValueAsBytes(
                    mapOf(
                        "id" to id,
                        "canisterID" to canister,
                        "userID" to user,
                        "postID" to post,
                        "reason" to reason.trim(),
                    )
                )
            http
                .newCall(
                    Request.Builder()
                        .url("https://taggr.kasane.network/api/reports")
                        .post(payload.toRequestBody("application/json".toMediaType()))
                        .build()
                )
                .execute()
                .use { response ->
                    check(response.isSuccessful) { "Report could not be sent (${response.code})." }
                    val result =
                        mapper.readTree(response.body?.string() ?: error("Missing report receipt"))
                    check(
                        result.path("id").asText().equals(id, true) &&
                            result.path("status").asText() == "received"
                    ) {
                        "Report could not be confirmed."
                    }
                }
        }
}
