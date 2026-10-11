package org.taggr.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/** Public help links stay available independently of identity and account state. */
@Composable
internal fun PolicyLinks(open: ((Uri) -> Unit)? = null) {
    val context = LocalContext.current
    val navigate = open ?: { uri: Uri -> context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
    FlowRow {
        for ((label, url) in
            listOf(
                "Terms of Use" to "https://taggr.kasane.network/terms",
                "Privacy Policy" to "https://taggr.kasane.network/privacy-policy",
                "Contact @FF on TAGGR" to "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF",
            )) {
            TextButton(onClick = { navigate(Uri.parse(url)) }) { Text(label) }
        }
    }
}
