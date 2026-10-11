package org.taggr.android.data

import java.lang.reflect.Proxy
import java.time.Duration
import org.ic4j.agent.AgentBuilder
import org.ic4j.agent.AuthSession
import org.ic4j.agent.ReplicaTransport
import org.ic4j.agent.android.ICClientConfiguration
import org.junit.Assert.*
import org.junit.Test

class TaggrApiSessionTest {
    @Test
    fun expiredDelegationCannotBeUsedOrSilentlyBecomeAnonymous() {
        // Real local Ed25519 delegation, no II credential and no transport request.
        val transport =
            Proxy.newProxyInstance(
                ReplicaTransport::class.java.classLoader,
                arrayOf(ReplicaTransport::class.java),
            ) { _, method, _ ->
                if (method.name == "close") null
                else error("Unexpected network operation: ${method.name}")
            } as ReplicaTransport
        val trust = AgentBuilder().transport(transport).build()
        val config = ICClientConfiguration("aaaaa-aa", "https://example.com")
        val session =
            AuthSession.delegating(
                ByteArray(32) { 7 },
                config.context,
                Duration.ofSeconds(1),
                listOf("aaaaa-aa"),
                trust,
            )
        val api = TaggrApi(config)
        try {
            api.setSession(session)
            assertSame(session, api.session)
            Thread.sleep(
                sessionRemainingMillis(session.expiration(), System.currentTimeMillis()) + 20
            )
            assertThrows(SessionExpiredException::class.java) { api.session }
            assertThrows(SessionExpiredException::class.java) { api.session }
            api.setSession(null)
            assertNull(api.session)
        } finally {
            api.close()
            session.close()
            transport.close()
        }
    }
}
