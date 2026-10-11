package org.taggr.android.data

import com.google.android.gms.tasks.Task
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout

internal object MlKitPostTranslator : PostTranslator {
    // A single active engine bounds native model memory across all visible posts.
    private val engines = Semaphore(1)

    override suspend fun translate(
        batch: PostTranslationBatch,
        targetLanguage: String,
    ): PostTranslationResult = engines.withPermit {
        withTimeout(180_000) {
            val target =
                TranslateLanguage.fromLanguageTag(targetLanguage)
                    ?: error("Translation is unavailable for your device language.")
            val identifier = LanguageIdentification.getClient()
            val source =
                try {
                    TranslateLanguage.fromLanguageTag(
                        identifier.identifyLanguage(batch.sourceText).awaitResult()
                    ) ?: error("Could not detect a supported language. Try a longer passage.")
                } finally {
                    identifier.close()
                }
            if (source == target)
                return@withTimeout PostTranslationResult(
                    batch.translatedBody { it },
                    alreadyInTargetLanguage = true,
                )
            val translator =
                Translation.getClient(
                    TranslatorOptions.Builder()
                        .setSourceLanguage(source)
                        .setTargetLanguage(target)
                        .build()
                )
            try {
                translator
                    .downloadModelIfNeeded(DownloadConditions.Builder().requireWifi().build())
                    .awaitResult()
                batch.translatedResult { translator.translate(it).awaitResult() }
            } finally {
                translator.close()
            }
        }
    }
}

private suspend fun <T> Task<T>.awaitResult(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
    addOnFailureListener { if (continuation.isActive) continuation.resumeWithException(it) }
    addOnCanceledListener { continuation.cancel() }
}
