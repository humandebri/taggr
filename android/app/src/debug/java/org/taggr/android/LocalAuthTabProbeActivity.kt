package org.taggr.android

import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.browser.auth.AuthTabIntent

/** Debug-only loopback ownership probe. Carries no identity or delegation material. */
class LocalAuthTabProbeActivity : ComponentActivity() {
    private lateinit var status: TextView
    private val browser =
        AuthTabIntent.registerActivityResultLauncher(this) { result ->
            val url = result.resultUri
            val matched =
                result.resultCode == AuthTabIntent.RESULT_OK &&
                    url?.scheme == "https" &&
                    url.host == "localhost" &&
                    url.path == "/android-auth-callback" &&
                    url.fragment == "probe=local"
            status.text = "Local AuthTab result: ${result.resultCode}; callback matched: $matched"
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status =
            TextView(this).apply {
                text = "Ready: localhost HTTPS ownership probe"
                textSize = 18f
            }
        val layout =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(32, 64, 32, 32)
            }
        layout.addView(status)
        layout.addView(
            Button(this).apply {
                text = "Open local AuthTab"
                setOnClickListener {
                    AuthTabIntent.Builder()
                        .build()
                        .launch(
                            browser,
                            Uri.parse("https://localhost/probe"),
                            "localhost",
                            "/android-auth-callback",
                        )
                }
            }
        )
        setContentView(layout)
    }

    override fun onDestroy() {
        browser.unregister()
        super.onDestroy()
    }
}
