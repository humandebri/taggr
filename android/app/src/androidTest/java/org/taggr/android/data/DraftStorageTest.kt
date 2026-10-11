package org.taggr.android.data

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DraftStorageTest {
    private val base by lazy { ApplicationProvider.getApplicationContext<Context>() }
    private val directory by lazy {
        File(base.cacheDir, "draft-tests-${UUID.randomUUID()}").apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(base) {
                override fun getNoBackupFilesDir(): File = directory
            }

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun normalizesAndRestoresImagesWithoutSharingDrafts() {
        val bitmap = Bitmap.createBitmap(2400, 1800, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.RED)
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
        bitmap.recycle()
        val image = DraftImages.normalize(output.toByteArray(), emptySet(), 200 * 1024)
        assertTrue(image.bytes.size <= 200 * 1024)
        assertTrue(image.width.toLong() * image.height <= 3_000_000)
        assertEquals("RIFF", String(image.bytes.copyOfRange(0, 4)))
        assertEquals("WEBP", String(image.bytes.copyOfRange(8, 12)))
        val colliding = DraftImages.normalize(output.toByteArray(), setOf(image.id), 200 * 1024)
        assertNotEquals(image.id, colliding.id)
        val store = DraftImageStore(context)
        val slot = "test/account-a/new"
        val other = "test/account-b/new"
        try {
            store.save(slot, listOf(image))
            assertTrue(store.load(other).isEmpty())
            val restored = DraftImageStore(context).load(slot).single()
            assertEquals(image.markdown, restored.markdown)
            assertArrayEquals(image.bytes, restored.bytes)
            store.save(slot, emptyList())
            assertTrue(store.load(slot).isEmpty())
        } finally {
            store.clear(slot)
            store.clear(other)
        }
    }

    @Test
    fun pendingEditsKeepRecoveryMethodAndAccountBinding() {
        val store = PendingPostStore(context)
        try {
            store.save(
                PendingPost(
                    "principal",
                    "canister",
                    ByteArray(32) { it.toByte() },
                    "edit_post",
                    42,
                    "edit/42",
                )
            )
            val restored = store.load("principal", "canister")!!
            assertEquals("edit_post", restored.method)
            assertEquals(42L, restored.postId)
            assertEquals("edit/42", restored.draftSlot)
            assertThrows(IllegalArgumentException::class.java) { store.load("other", "canister") }
            store.clear()
            assertNull(store.load("principal", "canister"))
        } finally {
            store.clear()
        }
    }
}
