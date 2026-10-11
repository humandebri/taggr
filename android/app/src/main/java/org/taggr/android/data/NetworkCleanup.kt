package org.taggr.android.data

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** TLS socket disposal can perform network IO. It must outlive the cleared ViewModel scope. */
internal fun closeNetworkResources(vararg resources: AutoCloseable) {
    CoroutineScope(Dispatchers.IO).launch {
        resources.forEach { resource ->
            try {
                resource.close()
            } catch (_: Exception) {
                Log.e("TAGGR", "Network resource cleanup failed")
            }
        }
    }
}
