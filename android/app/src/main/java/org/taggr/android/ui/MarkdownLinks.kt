package org.taggr.android.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.withLink
import java.net.URI
import java.net.URLEncoder
import java.util.Locale
import org.taggr.android.TaggrLinks

private val proseLink =
    Regex(
        "(?i)https?://[^\\p{Z}\\x09-\\x0D\\x85<>\\[\\]]+|www\\.[^\\p{Z}\\x09-\\x0D\\x85<>\\[\\]]+|[@#$/](?:[-_]|[\\p{L}\\p{N}]\\p{M}*+)++"
    )

/** Called only for prose AST nodes, never explicit links, images, code or raw HTML. */
internal fun AnnotatedString.Builder.appendLinkedProse(value: String, leadingCharacter: Char?) {
    var cursor = 0
    for (match in proseLink.findAll(value)) {
        val start = match.range.first
        val previous = if (start > 0) value[start - 1] else leadingCharacter
        if (
            previous != null &&
                !(previous.isWhitespace() || previous == 0x0085.toChar()) &&
                previous != '('
        )
            continue
        val bareURL = match.value.startsWith("http", true) || match.value.startsWith("www.", true)
        val token =
            if (bareURL) match.value.trimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}', '\'', '"')
            else match.value.trimEnd('-', '_')
        if (token.length <= 1) continue
        val destination =
            if (bareURL) safeLink(if (token.startsWith("www.", true)) "https://$token" else token)
            else {
                if (token.first() == '$' && !Character.isLetter(token.codePointAt(1))) continue
                val name = URLEncoder.encode(token.substring(1), "UTF-8").replace("+", "%20")
                val path =
                    when (token.first()) {
                        '@' -> "/user/$name"
                        '/' -> "/realm/$name"
                        else -> "/#/feed/$name"
                    }
                "https://${TaggrLinks.productionHost}$path"
            }
        append(value.substring(cursor, start))
        if (destination != null) {
            val label =
                if (bareURL) URI(destination).host?.uppercase(Locale.ROOT) ?: token else token
            withLink(LinkAnnotation.Url(destination)) { append(label) }
        } else append(token)
        cursor = start + token.length
    }
    append(value.substring(cursor))
}
