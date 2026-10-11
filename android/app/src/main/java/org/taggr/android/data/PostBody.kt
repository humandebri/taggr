package org.taggr.android.data

import org.commonmark.node.*
import org.commonmark.parser.IncludeSourceSpans
import org.commonmark.parser.Parser

sealed interface PostBodyBlock {
    data class Markdown(val text: String) : PostBodyBlock

    data class YouTube(val id: String) : PostBodyBlock {
        init {
            require(id.matches(Regex("[A-Za-z0-9_-]{6,}")))
        }

        val embedUrl
            get() = "https://www.youtube.com/embed/$id?playsinline=1&rel=0"

        fun headers(packageName: String): Map<String, String> {
            require(packageName.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")))
            return mapOf("Referer" to "https://${packageName.lowercase(java.util.Locale.ROOT)}")
        }
    }
}

object PostBodyParser {
    private val parser =
        Parser.builder().includeSourceSpans(IncludeSourceSpans.BLOCKS_AND_INLINES).build()
    private val videos =
        Regex(
            "https?://(?:www\\.)?(?:youtube\\.com/watch\\?[^ \\n\\)]*v=|youtu\\.be/)([A-Za-z0-9_-]{6,})(?:[?&][^ \\n\\)]*)?"
        )

    fun blocks(raw: String): List<PostBodyBlock> {
        val text = raw.replace("\r\n", "\n").replace('\r', '\n')
        val protected = mutableListOf<IntRange>()
        fun visit(node: Node) {
            if (
                node is Code ||
                    node is FencedCodeBlock ||
                    node is IndentedCodeBlock ||
                    node is Link ||
                    node is Image ||
                    node is HtmlBlock ||
                    node is HtmlInline
            ) {
                node.sourceSpans.forEach {
                    protected += it.inputIndex until (it.inputIndex + it.length)
                }
                return
            }
            var child = node.firstChild
            while (child != null) {
                visit(child)
                child = child.next
            }
        }
        visit(parser.parse(text))
        val matches =
            videos
                .findAll(text)
                .filter { match ->
                    protected.none { it.first <= match.range.last && match.range.first <= it.last }
                }
                .toList()
        if (matches.isEmpty()) return listOf(PostBodyBlock.Markdown(text))
        val seen = mutableSetOf<String>()
        val blocks = mutableListOf<PostBodyBlock>()
        var cursor = 0
        matches.forEach { match ->
            text
                .substring(cursor, match.range.first)
                .trim()
                .takeIf { it.isNotEmpty() }
                ?.let { blocks += PostBodyBlock.Markdown(it) }
            val id = match.groupValues[1]
            if (seen.add(id)) blocks += PostBodyBlock.YouTube(id)
            cursor = match.range.last + 1
        }
        text
            .substring(cursor)
            .trim()
            .takeIf { it.isNotEmpty() }
            ?.let { blocks += PostBodyBlock.Markdown(it) }
        return blocks.ifEmpty { listOf(PostBodyBlock.Markdown(text)) }
    }
}
