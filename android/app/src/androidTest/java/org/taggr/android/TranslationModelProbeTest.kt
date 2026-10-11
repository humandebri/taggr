package org.taggr.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.MlKitPostTranslator
import org.taggr.android.data.PostTranslationBatch

@RunWith(AndroidJUnit4::class)
class TranslationModelProbeTest {
    @Test
    fun recordDirectAndBatchedEnglishToJapaneseOutputs() =
        runBlocking(Dispatchers.IO) {
            val texts =
                listOf(
                    "Hello world.",
                    "Thank you.",
                    "Thank you for reading this post.",
                    "We hope you have a wonderful day.",
                    "Welcome to the TAGGR community. Thank you for reading this post.",
                )
            val identifier = LanguageIdentification.getClient()
            val translator =
                Translation.getClient(
                    TranslatorOptions.Builder()
                        .setSourceLanguage("en")
                        .setTargetLanguage("ja")
                        .build()
                )
            val results = JSONArray()
            try {
                Tasks.await(
                    translator.downloadModelIfNeeded(
                        DownloadConditions.Builder().requireWifi().build()
                    ),
                    60,
                    TimeUnit.SECONDS,
                )
                for (text in texts) {
                    val batch = PostTranslationBatch.fromMarkdown(text)
                    results.put(
                        JSONObject()
                            .put("source", text)
                            .put(
                                "detected_language",
                                Tasks.await(
                                    identifier.identifyLanguage(text),
                                    30,
                                    TimeUnit.SECONDS,
                                ),
                            )
                            .put(
                                "pieces",
                                JSONArray(
                                    batch.pieces.map {
                                        JSONObject()
                                            .put("text", it.text)
                                            .put("translate", it.translatable)
                                    }
                                ),
                            )
                            .put(
                                "direct_output",
                                Tasks.await(translator.translate(text), 30, TimeUnit.SECONDS),
                            )
                            .put(
                                "batch_output",
                                runCatching { MlKitPostTranslator.translate(batch, "ja").text }
                                    .getOrElse { "ERROR: ${it.message}" },
                            )
                    )
                }
            } finally {
                translator.close()
                identifier.close()
            }
            val run =
                InstrumentationRegistry.getArguments().getString("ui_capture_run")
                    ?: return@runBlocking
            require(run.matches(Regex("[0-9]{8}-[0-9]{6}")))
            val dir =
                File(
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation()
                            .targetContext
                            .getExternalFilesDir(null)
                    ),
                    "ui-checks/$run",
                )
            check(dir.isDirectory || dir.mkdirs())
            File(dir, "translation-model-probe.json").writeText(results.toString(2))
        }
}
