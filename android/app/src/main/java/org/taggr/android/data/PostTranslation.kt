package org.taggr.android.data

import org.commonmark.node.*
import org.commonmark.parser.Parser

internal data class TranslationPiece(val text: String, val translatable: Boolean)

internal data class PostTranslationResult(
    val text: String,
    val retainedOriginalProse: Boolean = false,
    val alreadyInTargetLanguage: Boolean = false,
)

/** Plain display prose and verbatim structure, with no Markdown destinations or image payloads. */
internal class PostTranslationBatch private constructor(val pieces: List<TranslationPiece>) {
    val sourceText
        get() = pieces.filter { it.translatable }.joinToString("\n") { it.text }

    val isEmpty
        get() = pieces.none { it.translatable }

    suspend fun translatedBody(translate: suspend (String) -> String): String = buildString {
        for (piece in pieces) append(if (piece.translatable) translate(piece.text) else piece.text)
    }

    suspend fun translatedResult(translate: suspend (String) -> String): PostTranslationResult {
        var retained = false
        val text = translatedBody { source ->
            translate(source).also { if (it == source) retained = true }
        }
        return PostTranslationResult(text, retainedOriginalProse = retained)
    }

    companion object {
        fun fromMarkdown(markdown: String): PostTranslationBatch {
            val pieces = mutableListOf<TranslationPiece>()
            val prose = StringBuilder()
            fun flush() {
                val text = prose.toString()
                prose.clear()
                for ((index, line) in text.split('\n').withIndex()) {
                    if (index > 0) pieces += TranslationPiece("\n", false)
                    val start = line.indexOfFirst { !it.isWhitespace() }
                    if (start < 0) {
                        if (line.isNotEmpty()) pieces += TranslationPiece(line, false)
                    } else {
                        val end = line.indexOfLast { !it.isWhitespace() } + 1
                        if (start > 0) pieces += TranslationPiece(line.substring(0, start), false)
                        pieces += TranslationPiece(line.substring(start, end), true)
                        if (end < line.length)
                            pieces += TranslationPiece(line.substring(end), false)
                    }
                }
            }
            fun verbatim(text: String) {
                flush()
                if (text.isNotEmpty()) pieces += TranslationPiece(text, false)
            }
            val ordinals = mutableMapOf<OrderedList, Long>()
            fun children(node: Node, visit: (Node) -> Unit) {
                var child = node.firstChild
                while (child != null) {
                    visit(child)
                    child = child.next
                }
            }
            fun render(node: Node) {
                when (node) {
                    is Text -> prose.append(node.literal)
                    is SoftLineBreak,
                    is HardLineBreak -> verbatim("\n")
                    is Code -> verbatim(node.literal)
                    is FencedCodeBlock -> verbatim(node.literal + "\n")
                    is IndentedCodeBlock -> verbatim(node.literal + "\n")
                    is Image -> Unit
                    is HtmlInline -> verbatim(node.literal)
                    is HtmlBlock -> verbatim(node.literal)
                    is Paragraph -> {
                        children(node, ::render)
                        val list = node.parent?.parent as? ListBlock
                        verbatim(
                            if (node.parent is ListItem && list?.isTight == true) "\n" else "\n\n"
                        )
                    }
                    is Heading -> {
                        children(node, ::render)
                        verbatim("\n\n")
                    }
                    is ListItem -> {
                        val ordered = node.parent as? OrderedList
                        val prefix =
                            if (ordered == null) "• "
                            else {
                                val ordinal =
                                    ordinals[ordered] ?: (ordered.markerStartNumber ?: 1).toLong()
                                ordinals[ordered] = ordinal + 1
                                "$ordinal. "
                            }
                        verbatim(prefix)
                        children(node, ::render)
                    }
                    is ListBlock -> {
                        children(node, ::render)
                        if (node.parent !is ListItem) verbatim("\n")
                    }
                    is BlockQuote -> {
                        verbatim("› ")
                        children(node, ::render)
                    }
                    is ThematicBreak -> verbatim("────────\n")
                    else -> children(node, ::render)
                }
            }
            render(Parser.builder().build().parse(markdown.take(200_000)))
            flush()
            // Remove only synthetic outer blank lines, retaining author content/code spaces.
            while (
                pieces.lastOrNull()?.let { !it.translatable && it.text.all { c -> c == '\n' } } ==
                    true
            ) pieces.removeAt(pieces.lastIndex)
            return PostTranslationBatch(pieces)
        }
    }
}

internal fun interface PostTranslator {
    suspend fun translate(
        batch: PostTranslationBatch,
        targetLanguage: String,
    ): PostTranslationResult
}
