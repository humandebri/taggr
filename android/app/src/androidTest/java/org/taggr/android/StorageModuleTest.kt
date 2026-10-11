package org.taggr.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrApi

@RunWith(AndroidJUnit4::class)
class StorageModuleTest {
    @Test
    fun downloadsActualMainnetStorageWasmWithVerifiedHash() = runBlocking {
        TaggrApi().use { api ->
            val wasm = api.verifiedStorageWasm()
            check(wasm.bytes().isNotEmpty() && wasm.hash.length == 64)
        }
    }
}
