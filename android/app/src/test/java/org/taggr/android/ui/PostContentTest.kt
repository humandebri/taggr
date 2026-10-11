package org.taggr.android.ui

import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.data.TaggrPost

class PostContentTest {
    @Test
    fun imageOnlyParagraphsDoNotLeaveBlankSpaceBeforeText() {
        assertEquals("Caption", markdownText("![photo](/blob/abc)\n\nCaption").text)
        assertEquals("", markdownText("![photo](/blob/abc)").text)
        assertEquals("  indented", markdownText("```\n  indented\n```").text)
    }

    @Test
    fun rendersNestedMarkdownAndPreservesCodeAndNewlines() {
        val parsed =
            markdownText(
                "**bold _italic_**\nnext\n\n`literal *`\n\n```\na < b\n```\n\n![photo](/blob/abc)"
            )
        assertTrue(parsed.text.contains("bold italic\nnext"))
        assertTrue(parsed.text.contains("literal *"))
        assertTrue(parsed.text.contains("a < b"))
        assertFalse(parsed.text.contains("/blob/abc"))
        assertFalse(parsed.spanStyles.isEmpty())
    }

    @Test
    fun rejectsExecutableAndCredentialLinks() {
        assertNull(safeLink("javascript:alert(1)"))
        assertNull(safeLink("intent://danger"))
        assertNull(safeLink("https://user:secret@example.com"))
        assertEquals("https://example.com", safeLink("https://example.com"))
    }

    @Test
    fun resolvesBlobMetadataAndDeduplicatesReferences() {
        val post =
            TaggrPost(
                1,
                "A",
                "",
                null,
                0,
                emptyList(),
                0,
                0,
                null,
                files = mapOf("abc@aaaaa-aa" to (42L to 80)),
            )
        assertEquals(
            listOf("https://aaaaa-aa.raw.icp0.io/image?offset=42&len=80"),
            postImageUrls(post, "![a](/blob/abc) ![b](/blob/abc) ![c](/blob/missing)", null),
        )
        assertEquals(emptyList<String>(), postImageUrls(post, "![x](javascript:bad)"))
        assertEquals(
            listOf("https://localhost/image?canisterId=aaaaa-aa&offset=42&len=80"),
            postImageUrls(post, "![a](/blob/abc)", java.net.URI("https://localhost")),
        )
        assertThrows(IllegalArgumentException::class.java) {
            postImageUrls(post, "![a](/blob/abc)", java.net.URI("https://user:secret@localhost"))
        }
    }
}
