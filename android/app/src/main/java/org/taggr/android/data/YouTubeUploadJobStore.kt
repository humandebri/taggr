package org.taggr.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class YouTubeUploadDiscardSnapshot(
    val fingerprint: String,
    val privateBytes: Long,
)

/**
 * One active upload, as on iOS. Atomic metadata and private immutable source are excluded from
 * backup.
 */
internal class YouTubeUploadJobStore(context: Context, namespace: String = "main") {
    private val scope = context.packageName + "/youtube-upload/v1/" + namespace
    private val name = hex(MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()))
    private val root = File(context.noBackupFilesDir, "taggr-youtube-$name")
    private val record = AtomicFile(File(root, "job.bin"))
    private val alias = "taggr-youtube-$name"

    suspend fun create(
        input: InputStream,
        target: YouTubeDraftTarget,
        metadata: YouTubeUploadMetadata,
        mimeType: String,
        nowMillis: Long = System.currentTimeMillis(),
        googleAccountEmail: String? = null,
    ): YouTubeUploadJob = input.use { source ->
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                require(
                    metadata.validationMessage() == null &&
                        Regex("video/[A-Za-z0-9.+-]+").matches(mimeType)
                )
                require(!record.baseFile.exists() && !File(root, "job.bin.bak").exists()) {
                    "Another YouTube upload is already saved."
                }
                check(root.isDirectory || root.mkdirs())
                val id = UUID.randomUUID().toString()
                val destination = File(root, "$id.video")
                try {
                    val digest = MessageDigest.getInstance("SHA-256")
                    var size = 0L
                    destination.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            coroutineContext.ensureActive()
                            val count = source.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            size = Math.addExact(size, count.toLong())
                        }
                        output.fd.sync()
                    }
                    val job =
                        YouTubeUploadJob(
                            id,
                            target,
                            size,
                            hex(digest.digest()),
                            mimeType,
                            metadata,
                            nowMillis,
                            googleAccountEmail = googleAccountEmail,
                        )
                    write(job)
                    job
                } catch (e: Exception) {
                    destination.delete()
                    throw e
                }
            }
        }
    }

    suspend fun load(
        target: YouTubeDraftTarget,
        nowMillis: Long = System.currentTimeMillis(),
    ): YouTubeUploadJob? =
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                val job = read(target) ?: return@synchronized null
                require(
                    nowMillis >= job.createdAtMillis &&
                        nowMillis - job.createdAtMillis <= YouTubeUploadJobCodec.MAX_AGE_MILLIS
                ) {
                    "The saved upload expired. Cancel it before starting another upload."
                }
                if (job.phase !in listOf(YouTubeJobPhase.COMPLETED, YouTubeJobPhase.CANCELLED)) {
                    val file = source(job)
                    require(file.isFile && file.length() == job.byteCount) {
                        "The saved video is unavailable."
                    }
                    val digest = MessageDigest.getInstance("SHA-256")
                    file.inputStream().use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = input.read(buffer)
                            if (n < 0) break
                            digest.update(buffer, 0, n)
                        }
                    }
                    require(hex(digest.digest()) == job.sourceSha256) { "The saved video changed." }
                }
                job
            }
        }

    /** Progress observation does not reread/hash a multi-gigabyte source each poll. */
    suspend fun progress(target: YouTubeDraftTarget): YouTubeUploadJob? =
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                read(target)?.also {
                    val now = System.currentTimeMillis()
                    require(
                        now >= it.createdAtMillis &&
                            now - it.createdAtMillis <= YouTubeUploadJobCodec.MAX_AGE_MILLIS
                    )
                }
            }
        }

    suspend fun save(job: YouTubeUploadJob, expected: YouTubeUploadJob? = null) =
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                val old = requireNotNull(read(job.target)) { "The saved upload is unavailable." }
                require(expected == null || old == expected) {
                    "The saved upload changed. Reload its state."
                }
                require(
                    old.id == job.id &&
                        old.byteCount == job.byteCount &&
                        old.sourceSha256 == job.sourceSha256 &&
                        old.mimeType == job.mimeType &&
                        old.metadata == job.metadata &&
                        old.createdAtMillis == job.createdAtMillis
                ) {
                    "The upload identity changed."
                }
                require(
                    old.googleAccountEmail == null ||
                        old.googleAccountEmail == job.googleAccountEmail
                ) {
                    "The upload Google account changed."
                }
                require(
                    old.phase !in listOf(YouTubeJobPhase.COMPLETED, YouTubeJobPhase.CANCELLED) ||
                        old == job
                ) {
                    "This upload already finished."
                }
                write(job)
                if (job.phase in listOf(YouTubeJobPhase.COMPLETED, YouTubeJobPhase.CANCELLED)) {
                    val file = source(job)
                    check(!file.exists() || file.delete()) { "Could not remove the saved video." }
                }
            }
        }

    suspend fun clear(target: YouTubeDraftTarget, expected: YouTubeUploadJob? = null) =
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                val job = read(target) ?: return@synchronized
                require(expected == null || job == expected) {
                    "The saved upload changed. Reload its state."
                }
                val file = source(job)
                check(!file.exists() || file.delete()) { "Could not remove the saved video." }
                record.delete()
                KeyStore.getInstance("AndroidKeyStore").apply {
                    load(null)
                    deleteEntry(alias)
                }
            }
        }

    fun source(job: YouTubeUploadJob): File = File(root, job.sourceFileName)

    /**
     * Does not decrypt or infer ownership: the UI must explain that this resets the app's upload.
     */
    suspend fun discardSnapshot(): YouTubeUploadDiscardSnapshot? =
        withContext(Dispatchers.IO) {
            synchronized(lock) { snapshot() }
        }

    suspend fun discardConfirmed(expected: YouTubeUploadDiscardSnapshot) =
        withContext(Dispatchers.IO) {
            synchronized(lock) {
                require(snapshot() == expected) {
                    "The saved upload changed. Review it again before discarding."
                }
                for (file in ownedFiles()) check(file.delete()) {
                    "Could not remove saved upload data."
                }
                KeyStore.getInstance("AndroidKeyStore").apply {
                    load(null)
                    deleteEntry(alias)
                }
                check(!root.exists() || root.delete()) {
                    "Could not remove the empty upload directory."
                }
            }
        }

    private fun ownedFiles(): List<File> {
        require(!Files.isSymbolicLink(root.toPath())) { "The upload directory is invalid." }
        if (!root.exists()) return emptyList()
        val files = requireNotNull(root.listFiles()).sortedBy { it.name }
        require(
            files.all { file ->
                file.isFile &&
                    !Files.isSymbolicLink(file.toPath()) &&
                    (file.name in listOf("job.bin", "job.bin.bak", "job.bin.new") ||
                        runCatching {
                                UUID.fromString(file.name.removeSuffix(".video")).toString() +
                                    ".video" == file.name
                            }
                            .getOrDefault(false))
            }
        ) {
            "The upload directory contains unexpected data."
        }
        return files
    }

    private fun snapshot(): YouTubeUploadDiscardSnapshot? {
        val files = ownedFiles()
        if (files.isEmpty()) return null
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(scope.toByteArray(Charsets.UTF_8))
        var bytes = 0L
        for (file in files) {
            bytes = Math.addExact(bytes, file.length())
            digest.update(
                "\n${file.name}:${file.length()}:${file.lastModified()}".toByteArray(Charsets.UTF_8)
            )
            if (!file.name.endsWith(".video"))
                file.inputStream().use { input ->
                    // Even an oversized corrupt record has bounded inspection cost.
                    val buffer = ByteArray(YouTubeUploadJobCodec.MAX_BYTES + 65)
                    var offset = 0
                    while (offset < buffer.size) {
                        val count = input.read(buffer, offset, buffer.size - offset)
                        if (count < 0) break
                        if (count == 0) continue
                        offset += count
                    }
                    digest.update(buffer, 0, offset)
                }
        }
        return YouTubeUploadDiscardSnapshot(hex(digest.digest()), bytes)
    }

    private fun aad(target: YouTubeDraftTarget) =
        com.fasterxml.jackson.databind
            .ObjectMapper()
            .writeValueAsBytes(
                listOf(
                    scope,
                    target.owner,
                    target.network,
                    target.canister,
                    target.channelId,
                    target.draftSlot,
                )
            )

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let {
            return it
        }
        check(create) { "The saved upload key is unavailable." }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            alias,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build()
                )
            }
            .generateKey()
    }

    private fun read(target: YouTubeDraftTarget): YouTubeUploadJob? {
        if (!record.baseFile.exists() && !File(root, "job.bin.bak").exists()) return null
        require(
            maxOf(record.baseFile.length(), File(root, "job.bin.bak").length()) <=
                YouTubeUploadJobCodec.MAX_BYTES + 64
        )
        val bytes = record.readFully()
        require(bytes.size >= 28 && bytes.size <= YouTubeUploadJobCodec.MAX_BYTES + 64)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(false),
            GCMParameterSpec(128, bytes.copyOfRange(0, 12)),
        )
        cipher.updateAAD(aad(target))
        val clear = cipher.doFinal(bytes.copyOfRange(12, bytes.size))
        return try {
            YouTubeUploadJobCodec.decode(clear, target)
        } finally {
            clear.fill(0)
        }
    }

    private fun write(job: YouTubeUploadJob) {
        val clear = YouTubeUploadJobCodec.encode(job)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val encrypted =
            try {
                cipher.init(Cipher.ENCRYPT_MODE, key(true))
                cipher.updateAAD(aad(job.target))
                cipher.iv + cipher.doFinal(clear)
            } finally {
                clear.fill(0)
            }
        val stream = record.startWrite()
        try {
            stream.write(encrypted)
            record.finishWrite(stream)
        } catch (e: Exception) {
            record.failWrite(stream)
            throw e
        }
    }

    companion object {
        private val lock = Any()

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }
}
