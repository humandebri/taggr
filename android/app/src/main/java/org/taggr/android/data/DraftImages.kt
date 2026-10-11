package org.taggr.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import kotlin.math.sqrt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.commonmark.node.Image
import org.commonmark.node.Node
import org.commonmark.parser.Parser

data class DraftImage(val id: String, val bytes: ByteArray, val width: Int, val height: Int) {
    val markdown
        get() = "![${width}x${height}, ${(bytes.size + 1023) / 1024}kb](/blob/$id)"
}

object DraftImages {
    const val MAX_BYTES = 200 * 1024
    const val MAX_PIXELS = 3_000_000
    const val MAX_COUNT = 20

    suspend fun import(context: Context, uri: Uri, usedIds: Set<String>, limit: Int): DraftImage =
        withContext(Dispatchers.IO) {
            require(limit in 1..MAX_BYTES)
            val data =
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val out = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(out.size() + count <= 32 * 1024 * 1024) {
                            "Selected image is too large to import."
                        }
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                } ?: error("Selected image could not be read.")
            normalize(data, usedIds, limit)
        }

    internal fun normalize(data: ByteArray, usedIds: Set<String>, limit: Int): DraftImage {
        require(data.size <= 32 * 1024 * 1024 && limit in 1..MAX_BYTES)
        var bitmap =
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) {
                decoder,
                info,
                _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                val size = info.size
                val scale =
                    sqrt(MAX_PIXELS.toDouble() / (size.width.toDouble() * size.height))
                        .coerceAtMost(1.0)
                decoder.setTargetSize(
                    (size.width * scale).toInt().coerceAtLeast(1),
                    (size.height * scale).toInt().coerceAtLeast(1),
                )
            }
        try {
            while (true) {
                fun encode(quality: Int): ByteArray {
                    val output = ByteArrayOutputStream()
                    @Suppress("DEPRECATION")
                    val format =
                        if (Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSY
                        else Bitmap.CompressFormat.WEBP
                    check(bitmap.compress(format, quality, output)) {
                        "Image could not be converted to WebP."
                    }
                    return output.toByteArray()
                }
                var best = encode(0)
                if (best.size <= limit) {
                    var low = 1
                    var high = 100
                    while (low <= high) {
                        val quality = (low + high) / 2
                        val bytes = encode(quality)
                        if (bytes.size <= limit) {
                            best = bytes
                            low = quality + 1
                        } else high = quality - 1
                    }
                    val prefix = hex(MessageDigest.getInstance("SHA-256").digest(best)).take(8)
                    val id =
                        (listOf(prefix) +
                                (1..255).map { prefix.take(6) + it.toString(16).padStart(2, '0') })
                            .firstOrNull { it !in usedIds }
                            ?: error("Too many images with the same identifier.")
                    return DraftImage(id, best, bitmap.width, bitmap.height)
                }
                require(bitmap.width > 1 || bitmap.height > 1) {
                    "Image could not fit the size limit."
                }
                val smaller =
                    Bitmap.createScaledBitmap(
                        bitmap,
                        (bitmap.width * 0.75).toInt().coerceAtLeast(1),
                        (bitmap.height * 0.75).toInt().coerceAtLeast(1),
                        true,
                    )
                bitmap.recycle()
                bitmap = smaller
            }
            @Suppress("UNREACHABLE_CODE") error("Image conversion failed")
        } finally {
            bitmap.recycle()
        }
    }

    fun storedIds(fileKeys: Set<String>): Set<String> =
        fileKeys.map { it.substringBefore('@') }.toSet()

    fun referenced(
        text: String,
        images: List<DraftImage>,
        existingIds: Set<String>,
    ): List<DraftImage> {
        require(images.all { text.contains(it.markdown) }) {
            "An image marker was changed. Remove and attach that image again."
        }
        val ids = mutableSetOf<String>()
        fun visit(node: Node) {
            if (node is Image && node.destination.startsWith("/blob/"))
                ids += node.destination.removePrefix("/blob/")
            var child = node.firstChild
            while (child != null) {
                visit(child)
                child = child.next
            }
        }
        visit(Parser.builder().build().parse(text))
        require(ids.all { id -> id in existingIds || images.any { it.id == id } }) {
            "A referenced image is no longer attached. Remove it or attach it again."
        }
        return images.filter { it.id in ids }
    }

    internal fun hex(bytes: ByteArray) =
        bytes.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
}

/** App-private, excluded from backup; account and draft slots cannot share attachment files. */
class DraftImageStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-draft-images")
    private val mapper = ObjectMapper()

    private fun directory(scope: String) =
        File(
            root,
            DraftImages.hex(MessageDigest.getInstance("SHA-256").digest(scope.toByteArray())),
        )

    @Synchronized
    fun save(scope: String, images: List<DraftImage>) {
        require(
            images.size <= DraftImages.MAX_COUNT &&
                images.map { it.id }.distinct().size == images.size
        )
        val dir = directory(scope)
        check(dir.mkdirs() || dir.isDirectory)
        for (image in images) {
            require(
                image.width > 0 &&
                    image.height > 0 &&
                    image.width.toLong() * image.height <= DraftImages.MAX_PIXELS
            )
            require(
                image.id.matches(Regex("[0-9a-f]{8}")) &&
                    image.bytes.size in 1..DraftImages.MAX_BYTES
            )
            atomic(File(dir, "${image.id}.webp"), image.bytes)
        }
        atomic(
            File(dir, "images.json"),
            mapper.writeValueAsBytes(
                images.map { mapOf("id" to it.id, "width" to it.width, "height" to it.height) }
            ),
        )
        val used = images.map { "${it.id}.webp" }.toSet() + "images.json"
        dir.listFiles()?.filter { it.name !in used }?.forEach { it.delete() }
    }

    @Synchronized
    fun load(scope: String): List<DraftImage> {
        val dir = directory(scope)
        val file = File(dir, "images.json")
        if (!file.exists()) return emptyList()
        require(file.length() <= 10_000)
        val rows = mapper.readTree(AtomicFile(file).readFully())
        require(rows.isArray && rows.size() <= DraftImages.MAX_COUNT)
        return rows.map { row ->
            val id = row.path("id").asText()
            require(id.matches(Regex("[0-9a-f]{8}")))
            val data = File(dir, "$id.webp")
            require(data.length() in 1..DraftImages.MAX_BYTES.toLong()) {
                "A draft image is missing."
            }
            val width = row.path("width").asInt()
            val height = row.path("height").asInt()
            require(width > 0 && height > 0 && width.toLong() * height <= DraftImages.MAX_PIXELS)
            DraftImage(id, AtomicFile(data).readFully(), width, height)
        }
    }

    @Synchronized
    fun clear(scope: String) {
        directory(scope).deleteRecursively()
    }

    @Synchronized
    fun clearAll() {
        check(root.deleteRecursively() || !root.exists()) {
            "Draft images could not be removed from this device."
        }
    }

    private fun atomic(target: File, bytes: ByteArray) {
        val file = AtomicFile(target)
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }
}
