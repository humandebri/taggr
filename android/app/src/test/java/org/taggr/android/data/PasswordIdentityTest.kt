package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.lang.reflect.Proxy
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.ic4j.agent.*
import org.ic4j.agent.android.*
import org.junit.Assert.*
import org.junit.Test

class PasswordIdentityTest {
    @Test
    fun runtimeRequestsSwiftLifetime() {
        assertEquals(java.time.Duration.ofDays(30), TaggrRuntime.configuration().delegationLifetime)
    }

    private val config = ICClientConfiguration("aaaaa-aa", "https://example.com")

    private fun client() =
        ICClient(
            config,
            transport =
                Proxy.newProxyInstance(
                    ReplicaTransport::class.java.classLoader,
                    arrayOf(ReplicaTransport::class.java),
                ) { _, method, _ ->
                    if (method.name == "close") null else error("Unexpected network operation")
                } as ReplicaTransport,
        )

    @Test
    fun matchesWebAndSwiftIncludingWhitespaceAndUnicode() {
        val fixtures =
            listOf(
                Triple(
                    "taggr-test-only-seed",
                    "9a6e0a77607f916df171a390a22e2d766cdf6bae3f018e33fe02aeacda63f060",
                    "b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe",
                ),
                Triple(
                    "  日本語 Seed 🔑  ",
                    "b93b548230ec12a78512e2a10d0fc07e603e8a601dfc4868ca4d61f672973023",
                    "nssj6-ror7n-uquzu-3sagw-q6owa-g2kmk-x67qv-hyw4a-4dmen-ptb2m-xqe",
                ),
                Triple(
                    "\u00e9",
                    "fb6e8cc5715e77484458c6cfc56b56ae1c6f696cf5a147fd4fdab4bf3e23298a",
                    "uygcv-4rp3k-wcl7g-spjwk-srcos-tryii-45k2e-au6lp-aagit-g5hld-6qe",
                ),
                Triple(
                    "e\u0301",
                    "747ee6f75d1248e5b3148edf646db988ec10af2d091ee4ae9b7aa3060554f798",
                    "apd3n-ikdy6-6mabl-heurf-viczv-s3tld-wwgtx-vkqvq-pakrd-urv6p-lae",
                ),
            )
        client().use { c ->
            fixtures.forEach { (phrase, expectedSeed, principal) ->
                val key = PasswordIdentity.privateKey(phrase)
                try {
                    assertEquals(expectedSeed, key.joinToString("") { "%02x".format(it) })
                    c.delegatingSession(key).use { session ->
                        assertEquals(principal, session.principal())
                        assertFalse(
                            String(session.encode(), Charsets.UTF_8)
                                .contains(Base64.getEncoder().encodeToString(key))
                        )
                    }
                } finally {
                    key.fill(0)
                }
            }
        }
        assertThrows(IllegalArgumentException::class.java) { PasswordIdentity.privateKey("") }
    }

    @Test
    fun onlyValidatedExistingUserReturnsSessionAndRootIsCleared() =
        runBlocking<Unit> {
            client().use { c ->
                var root: ByteArray? = null
                val user = ObjectMapper().readTree("{\"id\":1,\"name\":\"alice\"}")
                val (session, loaded) =
                    PasswordIdentity.authenticate(
                        "taggr-test-only-seed",
                        {
                            root = it
                            c.delegatingSession(it)
                        },
                        { user },
                    )
                session.use {
                    assertSame(user, loaded)
                    assertTrue(root!!.all { it == 0.toByte() })
                    assertEquals(
                        "b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe",
                        it.principal(),
                    )
                    c.restoreSession(it.encode()).use { restored ->
                        assertEquals(it.principal(), restored.principal())
                    }
                }
            }
        }

    @Test
    fun unknownUserClosesCandidateBeforeStorageCanReceiveIt() =
        runBlocking<Unit> {
            client().use { c ->
                var candidate: AuthSession? = null
                try {
                    PasswordIdentity.authenticate(
                        "not-a-real-password",
                        { c.delegatingSession(it).also { candidate = it } },
                        { null },
                    )
                    fail("Unknown account was accepted")
                } catch (e: IllegalStateException) {
                    assertTrue(e.message!!.startsWith("No TAGGR account"))
                }
                assertThrows(IllegalStateException::class.java) { candidate!!.validate() }
            }
        }

    @Test
    fun rejectedOrCancelledUserLookupClosesCandidate() =
        runBlocking<Unit> {
            client().use { c ->
                for ((cancel, response) in
                    listOf(
                        false to "{\"id\":-1,\"name\":\"alice\"}",
                        false to "{\"id\":18446744073709551617,\"name\":\"alice\"}",
                        false to "{\"id\":1}",
                        false to "[]",
                        true to "{}",
                    )) {
                    var candidate: AuthSession? = null
                    try {
                        PasswordIdentity.authenticate(
                            "test-only",
                            { c.delegatingSession(it).also { candidate = it } },
                            {
                                if (cancel) throw CancellationException("test cancellation")
                                ObjectMapper().readTree(response)
                            },
                        )
                        fail("Invalid account was accepted")
                    } catch (e: CancellationException) {
                        assertTrue(cancel)
                    } catch (e: IllegalArgumentException) {
                        assertFalse(cancel)
                    }
                    assertThrows(IllegalStateException::class.java) { candidate!!.validate() }
                }
            }
        }
}
