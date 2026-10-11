package org.taggr.android.ui

import android.content.Intent
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import org.taggr.android.TaggrLinks
import org.taggr.android.data.TaggrRuntime

@Composable
internal fun PostShareButton(postId: Long) {
    val context = LocalContext.current
    TextButton(
        onClick = {
            val send =
                Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, TaggrLinks.postURL(postId, TaggrRuntime.domain))
                }
            context.startActivity(Intent.createChooser(send, "Share post"))
        }
    ) {
        Text("Share")
    }
}
