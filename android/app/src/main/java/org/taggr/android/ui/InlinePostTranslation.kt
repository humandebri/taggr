package org.taggr.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import org.taggr.android.data.*

internal val LocalPostTranslator = staticCompositionLocalOf<PostTranslator> { MlKitPostTranslator }

@Composable
internal fun InlinePostTranslation(postId: Long, body: String) {
    val viewer = LocalPostViewer.current
    val locale = LocalConfiguration.current.locales[0]
    val batch = remember(body) { PostTranslationBatch.fromMarkdown(body) }
    if (batch.isEmpty) return
    // Results/jobs never outlive their source or viewer, and are not placed in saved state.
    key(postId, body, viewer, locale.toLanguageTag()) {
        val translator = LocalPostTranslator.current
        var requested by remember { mutableStateOf(false) }
        var translated by remember { mutableStateOf<PostTranslationResult?>(null) }
        var error by remember { mutableStateOf<String?>(null) }
        var busy by remember { mutableStateOf(false) }
        var showHelp by remember { mutableStateOf(false) }
        LaunchedEffect(requested) {
            if (!requested) return@LaunchedEffect
            busy = true
            error = null
            try {
                translated = translator.translate(batch, locale.toLanguageTag())
            } catch (_: TimeoutCancellationException) {
                error = "Translation timed out. Connect to Wi-Fi and try again."
                requested = false
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                error =
                    "Translation unavailable. Connect to Wi-Fi to download language models, then try again."
                requested = false
            } finally {
                busy = false
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            translated?.let { result ->
                Text(
                    if (result.alreadyInTargetLanguage) "Already in device language"
                    else "Translated",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                )
                SelectionContainer {
                    Text(
                        result.text,
                        Modifier.testTag("post-translation-$postId"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (result.retainedOriginalProse)
                    Text(
                        "Some original text was retained by Google Translate.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                Image(
                    painterResource(
                        if (MaterialTheme.colorScheme.surface.luminance() < 0.5f)
                            org.taggr.android.R.drawable.google_translate_white
                        else org.taggr.android.R.drawable.google_translate_color
                    ),
                    contentDescription = "Powered by Google Translate",
                    modifier = Modifier.width(176.dp).height(16.dp),
                )
            }
            error?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                if (busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                TextButton(
                    onClick = {
                        if (requested) {
                            requested = false
                            translated = null
                            error = null
                        } else requested = true
                    },
                    modifier = Modifier.heightIn(min = 44.dp).testTag("translate-post-$postId"),
                ) {
                    Text(
                        if (busy) "Cancel translation"
                        else if (translated != null) "Hide translation" else "Translate with Google"
                    )
                }
                IconButton(
                    onClick = { showHelp = true },
                    modifier = Modifier.semantics { contentDescription = "About translation" },
                ) {
                    Text("ⓘ", Modifier.clearAndSetSemantics {})
                }
            }
        }
        if (showHelp) {
            val uriHandler = LocalUriHandler.current
            AlertDialog(
                onDismissRequest = { showHelp = false },
                title = { Text("About translation") },
                text = {
                    Column(
                        Modifier.verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            "Google Translate powers translation on this device. Language models download over Wi-Fi when needed. Automatic translations can contain errors; refer to the original post."
                        )
                        Text(
                            "Text and translation results stay on this device. Google receives ML Kit performance and usage metrics and may provide model updates.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        TextButton(
                            onClick = {
                                uriHandler.openUri("https://developers.google.com/ml-kit/terms")
                            }
                        ) {
                            Text("Translation privacy information")
                        }
                        Text(
                            "THIS SERVICE MAY CONTAIN TRANSLATIONS POWERED BY GOOGLE. GOOGLE DISCLAIMS ALL WARRANTIES RELATED TO THE TRANSLATIONS, EXPRESS OR IMPLIED, INCLUDING ANY WARRANTIES OF ACCURACY, RELIABILITY, AND ANY IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        TextButton(
                            onClick = { uriHandler.openUri("https://cloud.google.com/translate") }
                        ) {
                            Text("Google Translate information")
                        }
                    }
                },
                confirmButton = { TextButton(onClick = { showHelp = false }) { Text("Close") } },
            )
        }
    }
}
