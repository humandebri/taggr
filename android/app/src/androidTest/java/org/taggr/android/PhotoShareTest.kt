package org.taggr.android

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PhotoShareTest {
    @Test
    fun originalPngIsExportedThroughPrivateProviderWithOnlyReadPermission() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.BLUE)
        val bytes =
            ByteArrayOutputStream()
                .also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                .toByteArray()
        bitmap.recycle()
        val intent =
            preparedPhotoShareIntent(
                context,
                AccountPhoto(7, 0, "https://images.example/test.png", "", 0),
                bytes,
            )
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
        assertEquals("content", uri.scheme)
        assertEquals("${context.packageName}.images", uri.authority)
        assertEquals("image/png", intent.type)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, intent.flags)
        assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
        context.contentResolver.openInputStream(uri)!!.use {
            assertArrayEquals(bytes, it.readBytes())
        }
        assertFalse(context.packageManager.resolveContentProvider(uri.authority!!, 0)!!.exported)
        assertThrows(IllegalArgumentException::class.java) {
            FileProvider.getUriForFile(
                context,
                uri.authority!!,
                File(context.cacheDir, "outside-share.bin"),
            )
        }
        assertThrows(IllegalStateException::class.java) {
            preparedPhotoShareIntent(
                context,
                AccountPhoto(7, 0, "https://images.example/not-image", "", 0),
                "not an image".toByteArray(),
            )
        }
    }
}
