package org.taggr.android

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import java.security.MessageDigest

private fun insertionHash(text: String) =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") {
        "%02x".format(it)
    }

internal fun imageInsertionTicket(scope: String, text: String, offset: Int): String =
    "${insertionHash(scope)}:${insertionHash(text)}:${offset.coerceIn(0, text.length)}"

internal fun imageInsertionOffset(ticket: String?, scope: String, text: String): Int? {
    val parts = ticket?.split(':') ?: return null
    if (parts.size != 3 || parts[0] != insertionHash(scope) || parts[1] != insertionHash(text))
        return null
    return parts[2].toIntOrNull()?.takeIf { it in 0..text.length }
}

internal fun insertDraftImages(text: String, markers: List<String>, offset: Int): TextFieldValue {
    val cursor = offset.coerceIn(0, text.length)
    if (markers.isEmpty()) return TextFieldValue(text, TextRange(cursor))
    val before = text.substring(0, cursor)
    val line = before.substringAfterLast('\n')
    val insertion =
        (if (line.isNotEmpty() && !line.startsWith("![")) "\n\n" else "") +
            markers.joinToString("\n") +
            "\n"
    return TextFieldValue(
        before + insertion + text.substring(cursor),
        TextRange(cursor + insertion.length),
    )
}
