package org.taggr.android

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.taggr.android.ui.ImageLoader

internal suspend fun photoShareIntent(context: Context, photo: AccountPhoto): Intent =
    withContext(Dispatchers.IO) {
        val bytes = ImageLoader.download(photo.url)
        preparedPhotoShareIntent(context, photo, bytes)
    }

internal fun preparedPhotoShareIntent(
    context: Context,
    photo: AccountPhoto,
    bytes: ByteArray,
): Intent {
    require(bytes.size in 1..(10 * 1024 * 1024))
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    check(bounds.outWidth > 0 && bounds.outHeight > 0) { "The source is not an image." }
    val (extension, mime) =
        when {
            bytes.take(4) == listOf(0x89.toByte(), 0x50.toByte(), 0x4e.toByte(), 0x47.toByte()) ->
                "png" to "image/png"
            bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte() ->
                "jpg" to "image/jpeg"
            bytes.size >= 12 &&
                String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP" -> "webp" to "image/webp"
            bytes.size >= 6 && String(bytes, 0, 3, Charsets.US_ASCII) == "GIF" ->
                "gif" to "image/gif"
            else -> "img" to "application/octet-stream"
        }
    val directory =
        File(context.cacheDir, "taggr-shared-images").apply { check(mkdirs() || isDirectory) }
    val hash =
        MessageDigest.getInstance("SHA-256").digest(photo.url.toByteArray()).take(12).joinToString(
            ""
        ) {
            "%02x".format(it)
        }
    val target = File(directory, "taggr-${photo.postId}-$hash.$extension")
    val temp = File.createTempFile("photo-", ".tmp", directory)
    try {
        temp.outputStream().use { it.write(bytes) }
        check(temp.renameTo(target)) { "The image could not be prepared for sharing." }
    } finally {
        temp.delete()
    }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.images", target)
    return Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        clipData = ClipData.newRawUri("TAGGR photo", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
