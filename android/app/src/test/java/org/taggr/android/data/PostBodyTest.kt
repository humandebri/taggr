package org.taggr.android.data

import org.junit.Assert.*
import org.junit.Test

class PostBodyTest {
    @Test
    fun videosKeepTextOrderNormalizeLinesAndDeduplicateIds() {
        val blocks =
            PostBodyParser.blocks(
                "Before\r\n\r\nhttps://www.youtube.com/watch?feature=share&v=M7lc1UVf-VE&x=1\r\nAfter\nhttps://youtu.be/M7lc1UVf-VE\nhttps://youtu.be/abcdefghijk"
            )
        assertEquals(
            listOf(
                PostBodyBlock.Markdown("Before"),
                PostBodyBlock.YouTube("M7lc1UVf-VE"),
                PostBodyBlock.Markdown("After"),
                PostBodyBlock.YouTube("abcdefghijk"),
            ),
            blocks,
        )
    }

    @Test
    fun codeAndExplicitMarkdownLinksAreNotReplaced() {
        for (text in
            listOf(
                "`https://youtu.be/abcdefghijk`",
                "```\nhttps://youtu.be/abcdefghijk\n```",
                "~~~\nhttps://youtu.be/abcdefghijk\n~~~",
                "    https://youtu.be/abcdefghijk",
                "[Link](https://youtu.be/abcdefghijk)",
                "![Photo](https://youtu.be/abcdefghijk)",
            )) {
            assertEquals(listOf(PostBodyBlock.Markdown(text)), PostBodyParser.blocks(text))
        }
        assertEquals(
            listOf(PostBodyBlock.Markdown("https://youtube.com.evil/watch?v=abcdefghijk")),
            PostBodyParser.blocks("https://youtube.com.evil/watch?v=abcdefghijk"),
        )
    }

    @Test
    fun requestOnlyUsesCanonicalTrustedEmbedAndApplicationReferer() {
        val video = PostBodyBlock.YouTube("M7lc1UVf-VE")
        assertEquals(
            "https://www.youtube.com/embed/M7lc1UVf-VE?playsinline=1&rel=0",
            video.embedUrl,
        )
        assertEquals(
            mapOf("Referer" to "https://org.taggr.android"),
            video.headers("org.taggr.android"),
        )
        assertThrows(IllegalArgumentException::class.java) {
            PostBodyBlock.YouTube("../bad<script>")
        }
        assertThrows(IllegalArgumentException::class.java) { video.headers("example.com/evil") }
    }
}
