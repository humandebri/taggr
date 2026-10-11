package org.taggr.android

import android.content.Intent
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import org.taggr.android.data.TaggrRuntime

class IncomingLinksViewModel(private val saved: SavedStateHandle) : ViewModel() {
    val pending = saved.getStateFlow<String?>("pending-link", null)

    fun accept(intent: Intent?) {
        val url = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString ?: return
        if (TaggrLinks.parse(url, TaggrRuntime.domain) != null) saved["pending-link"] = url
    }

    fun consumed(url: String) {
        if (pending.value == url) saved["pending-link"] = null
    }
}
