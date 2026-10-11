package org.taggr.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.time.Duration
import java.util.UUID
import org.ic4j.agent.android.ICAuthenticationOptions
import org.ic4j.agent.android.ICClient
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.PasswordIdentity
import org.taggr.android.data.TaggrRuntime
import org.taggr.android.data.sessionRemainingMillis

@RunWith(AndroidJUnit4::class)
class PasswordSessionStorageTest {
    @Test
    fun restoresFreshSessionKeyWithoutPasswordOrRootThenSignsOut() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        ICClient(TaggrRuntime.configuration()).use { client ->
            val store = client.sessionStore(app, "password-test-${UUID.randomUUID()}")
            val root = PasswordIdentity.privateKey("taggr-test-only-seed")
            try {
                client.delegatingSession(root).use { candidate ->
                    store.save(candidate)
                    client.loadSession(store)!!.use { restored ->
                        assertEquals(
                            "b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe",
                            restored.principal(),
                        )
                        assertArrayEquals(candidate.encode(), restored.encode())
                        assertTrue(
                            sessionRemainingMillis(
                                restored.expiration(),
                                System.currentTimeMillis(),
                            ) > Duration.ofDays(29).toMillis()
                        )
                    }
                    store.clear()
                    assertNull(client.loadSession(store))
                }
            } finally {
                root.fill(0)
                store.clear()
            }
        }
    }

    @Test
    fun expiredPasswordDelegationIsRejectedAndCleared() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        ICClient(TaggrRuntime.configuration()).use { client ->
            val store = client.sessionStore(app, "password-expiry-test-${UUID.randomUUID()}")
            val root = PasswordIdentity.privateKey("expiry-test-only")
            try {
                client
                    .delegatingSession(
                        root,
                        ICAuthenticationOptions(lifetime = Duration.ofSeconds(2)),
                    )
                    .use { candidate ->
                        store.save(candidate)
                        Thread.sleep(
                            sessionRemainingMillis(
                                candidate.expiration(),
                                System.currentTimeMillis(),
                            ) + 50
                        )
                        try {
                            client.loadSession(store)
                            fail("Expired password delegation was restored")
                        } catch (_: Exception) {}
                        assertNull(client.loadSession(store))
                    }
            } finally {
                root.fill(0)
                store.clear()
            }
        }
    }
}
