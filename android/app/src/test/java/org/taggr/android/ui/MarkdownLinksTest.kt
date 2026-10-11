package org.taggr.android.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.TaggrLink
import org.taggr.android.TaggrLinks

class MarkdownLinksTest {
    private fun links(text: AnnotatedString) =
        text.getLinkAnnotations(0, text.length).map { (it.item as LinkAnnotation.Url).url }

    @Test
    fun unicodeMentionsRealmsTagsAndTokenSuffixesUseNativeRoutes() {
        val body = "Hi @Alice- and (/日本語_Realm), #ICP \$TAGGR $123 #tag-- word foo@other /realm_"
        val parsed = markdownText(body)
        assertEquals(body, parsed.text)
        assertEquals(
            listOf(
                TaggrLink.Profile("Alice"),
                TaggrLink.Realm("日本語_Realm"),
                TaggrLink.Tags(listOf("ICP")),
                TaggrLink.Tags(listOf("TAGGR")),
                TaggrLink.Tags(listOf("tag")),
                TaggrLink.Realm("realm"),
            ),
            links(parsed).map { TaggrLinks.parse(it) },
        )
    }

    @Test
    fun codeImagesExplicitLinksAndRawHtmlKeepTheirDestinationsUntouched() {
        val body =
            "`@code #code /code`\n\n```\n@fenced #fenced /fenced\n```\n\n    @indented\n\n[@label #label](https://example.org/real?q=@query) ![@image](/blob/x)\n\n<a title=\"@attribute\">"
        val parsed = markdownText(body)
        assertEquals(listOf("https://example.org/real?q=@query"), links(parsed))
        assertTrue(parsed.text.contains("@code #code /code"))
        assertFalse(parsed.text.contains("@image"))
        assertTrue(parsed.text.contains("@attribute"))
        assertEquals(
            emptyList<String>(),
            links(markdownText("[unsafe @name](javascript:alert(1))")),
        )
    }

    @Test
    fun bareUrlsUseHostLabelsAndKeepTrailingPunctuationOutsideTheLink() {
        val parsed =
            markdownText(
                "Visit https://example.org/path?q=1, www.example.net/help! https://user:pass@example.com/no."
            )
        assertEquals(
            "Visit EXAMPLE.ORG, WWW.EXAMPLE.NET! https://user:pass@example.com/no.",
            parsed.text,
        )
        assertEquals(
            listOf("https://example.org/path?q=1", "https://www.example.net/help"),
            links(parsed),
        )
        assertTrue(links(parsed).none { "user:pass" in it })
    }

    @Test
    fun inlineStyleBoundariesDoNotCreateLinksInsideWords() {
        val parsed = markdownText("word**@notlinked** and **@linked** then _#tag_")
        assertEquals(
            listOf(TaggrLink.Profile("linked"), TaggrLink.Tags(listOf("tag"))),
            links(parsed).map { TaggrLinks.parse(it) },
        )
        assertFalse(parsed.spanStyles.isEmpty())
    }

    @Test
    fun orderedListsKeepStartNumberAndNestedCountersAndTightSpacing() {
        val parsed =
            markdownText(
                "7. Seven\n8. Eight\n   1. Nested one\n   2. Nested two\n9. Nine\n\n- Bullet\n- Next"
            )
        assertEquals(
            "7. Seven\n8. Eight\n1. Nested one\n2. Nested two\n9. Nine\n\n• Bullet\n• Next",
            parsed.text,
        )
    }

    @Test
    fun decomposedLettersAndUnicodeWhitespaceMatchSwiftTokenBoundaries() {
        val name = "cafe" + 0x0301.toChar()
        val wide = 0x3000.toChar()
        val noBreak = 0x00a0.toChar()
        val source = "@$name${wide}#$name${wide}https://example.org/path${noBreak}#ICP"
        val parsed = markdownText(source)
        assertEquals("@$name${wide}#$name${wide}EXAMPLE.ORG${noBreak}#ICP", parsed.text)
        assertEquals(
            listOf(
                TaggrLink.Profile(name),
                TaggrLink.Tags(listOf(name)),
                null,
                TaggrLink.Tags(listOf("ICP")),
            ),
            links(parsed).map { TaggrLinks.parse(it) },
        )
        assertEquals("https://example.org/path", links(parsed)[2])
        val afterNextLine = markdownText("before" + 0x0085.toChar() + "@$name")
        assertEquals(TaggrLink.Profile(name), TaggrLinks.parse(links(afterNextLine).single()))
    }

    @Test
    fun longTokensRemainRenderableWithoutRegexStackOverflow() {
        for (name in listOf("a".repeat(6000), ("e" + 0x0301.toChar()).repeat(6000))) {
            val source = "@$name"
            val parsed = markdownText(source)
            assertEquals(source, parsed.text)
            assertEquals(1, links(parsed).size)
        }
    }
}
