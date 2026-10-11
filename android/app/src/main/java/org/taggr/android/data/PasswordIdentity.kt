package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.ic4j.agent.AuthSession

internal object PasswordIdentity {
    fun privateKey(phrase: String): ByteArray {
        require(phrase.isNotEmpty()) { "Enter your password." }
        val digest = MessageDigest.getInstance("SHA-256")
        var seed = phrase.toByteArray(Charsets.UTF_8)
        try {
            repeat(15_000) {
                val next = digest.digest(seed)
                seed.fill(0)
                seed = next
            }
            return seed.copyOf()
        } finally {
            seed.fill(0)
        }
    }

    /** Caller owns the validated candidate; an unknown user never reaches storage/installation. */
    suspend fun authenticate(
        phrase: String,
        createSession: (ByteArray) -> AuthSession,
        loadUser: suspend (AuthSession) -> JsonNode?,
    ): Pair<AuthSession, JsonNode> {
        var created: AuthSession? = null
        val candidate =
            try {
                withContext(Dispatchers.Default) {
                    val seed = privateKey(phrase)
                    try {
                        createSession(seed).also { created = it }
                    } finally {
                        seed.fill(0)
                    }
                }
            } catch (error: Throwable) {
                created?.close()
                throw error
            }
        try {
            val user =
                loadUser(candidate)
                    ?: error(
                        "No TAGGR account was found for this password. Check the password, including spaces and capitalization."
                    )
            require(
                user.isObject &&
                    user.path("id").isIntegralNumber &&
                    user.path("id").bigIntegerValue().bitLength() <= 63 &&
                    user.path("id").asLong(-1) >= 0 &&
                    user.path("name").isTextual
            ) {
                "The account response could not be validated. Try again."
            }
            return candidate to user
        } catch (error: Throwable) {
            candidate.close()
            throw error
        }
    }
}
