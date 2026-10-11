package org.taggr.android

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.*
import org.junit.Test

class MarkdownEditTest {
    @Test
    fun unicodeSelectionAndCaretMatchSwiftUtf16Edits() {
        val text = "前🧡後"
        val bold = markdownEdit(TextFieldValue(text, TextRange(1, 3)), MarkdownAction.BOLD)
        assertEquals("前**🧡**後", bold.text)
        assertEquals(TextRange(3, 5), bold.selection)
        val empty = markdownEdit(TextFieldValue("ab", TextRange(1)), MarkdownAction.ITALIC)
        assertEquals("a__b", empty.text)
        assertEquals(TextRange(2), empty.selection)
    }

    @Test
    fun reversedSelectionListQuoteAndLinkPreserveSurroundingText() {
        val value = TextFieldValue("xone\ntwoz", TextRange(8, 1))
        assertEquals("x- one\n- twoz", markdownEdit(value, MarkdownAction.LIST).text)
        assertEquals("x> one\ntwoz", markdownEdit(value, MarkdownAction.QUOTE).text)
        assertEquals(
            "x[one\ntwo](https://example.test)z",
            markdownEdit(value, MarkdownAction.LINK, "https://example.test").text,
        )
        val empty =
            markdownEdit(
                TextFieldValue("ab", TextRange(1)),
                MarkdownAction.LINK,
                "https://example.test",
            )
        assertEquals("a[](https://example.test)b", empty.text)
        assertEquals(TextRange(2), empty.selection)
        assertEquals(value, markdownEdit(value, MarkdownAction.LINK))
    }
}
