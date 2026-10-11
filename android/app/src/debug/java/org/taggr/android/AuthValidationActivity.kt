package org.taggr.android

import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import java.net.URI
import java.time.Duration
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.ic4j.agent.AuthSession
import org.ic4j.agent.android.*

/** Debug-only integration harness. Test roots and identities never enter release builds. */
class AuthValidationActivity : ComponentActivity() {
    private lateinit var authenticator: InternetIdentityAuthenticator
    private lateinit var client: ICClient
    private lateinit var status: TextView
    private var session: AuthSession? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authenticator = InternetIdentityAuthenticator(this)
        val origin = intent.getStringExtra("callbackOrigin") ?: error("callbackOrigin required")
        val ii = intent.getStringExtra("iiOrigin") ?: error("iiOrigin required")
        val root = Base64.getDecoder().decode(intent.getStringExtra("rootKey"))
        val config =
            ICClientConfiguration(
                canisterId = "rdmx6-jaaaa-aaaaa-aaadq-cai",
                derivationOrigin = origin,
                apiBaseURL = URI(ii),
                internetIdentityURL = URI("$ii/authorize"),
                rootKey = root,
                delegationLifetime = Duration.ofMinutes(10),
            )
        client = ICClient(config)
        val callback = URI("$origin/android-auth-callback")
        val store = client.sessionStore(applicationContext, "local-browser-validation")
        val savedQuery = java.io.File(noBackupFilesDir, "local-browser-signed-query.json")
        val layout =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(32, 64, 32, 32)
            }
        status =
            TextView(this).apply {
                textSize = 18f
                text = "Ready: local Internet Identity browser test"
            }
        layout.addView(status)
        fun button(label: String, action: suspend () -> Unit) {
            layout.addView(
                Button(this).apply {
                    text = label
                    setOnClickListener {
                        lifecycleScope.launch {
                            isEnabled = false
                            try {
                                action()
                            } catch (error: Exception) {
                                status.text =
                                    "FAILED: ${error.javaClass.simpleName}: ${error.message}"
                            } finally {
                                isEnabled = true
                            }
                        }
                    }
                }
            )
        }
        button("Sign in with local Internet Identity") {
            status.text = "Waiting for browser callback"
            val authenticated =
                client.signIn(
                    authenticator,
                    callback,
                    ICAuthenticationOptions(),
                )
            withContext(Dispatchers.IO) {
                store.save(authenticated)
                ICClient(config, authenticated).use { signedClient ->
                    savedQuery.writeBytes(
                        signedClient
                            .signQuery(
                                "lookup",
                                CandidArguments(Candid.nat64.encode(10_000uL)).encode(),
                            )
                            .encode()
                    )
                }
            }
            session?.close()
            session = authenticated
            status.text = "AUTHENTICATED and encrypted session saved\n${authenticated.principal()}"
        }
        button("Restore session and verify signed request") {
            val principal =
                withContext(Dispatchers.IO) {
                    val restored = client.loadSession(store) ?: error("No saved session")
                    restored.use {
                        ICClient(config, restored).use { signedClient ->
                            signedClient.restoreSignedRequest(savedQuery.readBytes())
                            val childKey =
                                java.security.KeyPairGenerator.getInstance("EC")
                                    .apply {
                                        initialize(
                                            java.security.spec.ECGenParameterSpec("secp256r1")
                                        )
                                    }
                                    .generateKeyPair()
                                    .public
                                    .encoded
                            val child =
                                restored.childDelegation(
                                    childKey,
                                    ICChildDelegationOptions(
                                        targets = listOf(config.canisterId),
                                        permissions = ICDelegationPermission.QUERIES,
                                    ),
                                )
                            check(child.delegation.targets.single().toString() == config.canisterId)
                            check(child.delegation.permissions == "queries")
                        }
                        restored.principal().toString()
                    }
                }
            status.text =
                "RESTORED: delegation, signed request and narrowed child verified\n$principal"
        }
        button("Send verified authenticated query") {
            val count =
                withContext(Dispatchers.IO) {
                    val restored = client.loadSession(store) ?: error("No saved session")
                    restored.use {
                        ICClient(config, restored).use { signedClient ->
                            signedClient
                                .queryCandid(
                                    "lookup",
                                    CandidArguments(Candid.nat64.encode(10_000uL)),
                                )
                                .values
                                .size
                        }
                    }
                }
            status.text = "QUERY VERIFIED: $count Candid reply value(s)"
        }
        button("Sign out and clear encrypted session") {
            withContext(Dispatchers.IO) {
                store.clear()
                savedQuery.delete()
                check(client.loadSession(store) == null)
            }
            session?.close()
            session = null
            status.text = "SIGNED OUT: encrypted session deleted"
        }
        setContentView(layout)
    }

    override fun onDestroy() {
        authenticator.close()
        client.close()
        session?.close()
        super.onDestroy()
    }
}
