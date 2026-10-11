package org.taggr.android.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PostTranslationTest {
    @Test
    fun retainedProseIsReportedWithoutMistakingPreservedCodeForPartialTranslation() = runBlocking {
        val partial =
            PostTranslationBatch.fromMarkdown("Hello\nWorld\n\n```\ncode\n```").translatedResult {
                if (it == "Hello") "こんにちは" else it
            }
        assertTrue(partial.retainedOriginalProse)
        assertTrue(partial.text.contains("World"))
        val complete =
            PostTranslationBatch.fromMarkdown("Hello\n\n```\ncode\n```").translatedResult {
                "こんにちは"
            }
        assertFalse(complete.retainedOriginalProse)
        assertTrue(complete.text.contains("code"))
    }

    @Test
    fun richMarkdownTranslatesProseButKeepsCodeStructureAndNoDestinations() = runBlocking {
        val batch =
            PostTranslationBatch.fromMarkdown(
                """
                # Heading

                A **bold** [label](https://secret.example/destination) and `code()`.

                3. First
                4. Second

                > Quote

                ```kotlin
                val x = "private syntax"
                ```

                ![image caption](https://secret.example/picture.png)
                """
                    .trimIndent()
            )
        val sent = mutableListOf<String>()
        val rendered = batch.translatedBody {
            sent += it
            "<$it>"
        }
        assertTrue(rendered.contains("<A bold label and> code()<.>"))
        assertTrue(rendered.contains("3. <First>\n4. <Second>"))
        assertTrue(rendered.contains("› <Quote>"))
        assertTrue(rendered.contains("val x = \"private syntax\""))
        assertFalse(sent.any { "private syntax" in it || "code()" in it || "https://" in it })
        assertFalse(rendered.contains("secret.example"))
        assertFalse(rendered.contains("image caption"))
    }

    @Test
    fun multilineParagraphsKeepBreaksAndCodeOnlyHasNoTranslateControl() = runBlocking {
        val batch = PostTranslationBatch.fromMarkdown("First line\nSecond **line**\n\nThird line")
        assertEquals(
            "FIRST LINE\nSECOND LINE\n\nTHIRD LINE",
            batch.translatedBody { it.uppercase() },
        )
        assertTrue(PostTranslationBatch.fromMarkdown("```\ncode only\n```").isEmpty)
        assertTrue(PostTranslationBatch.fromMarkdown("![image](/blob/fixture)").isEmpty)
        assertTrue(PostTranslationBatch.fromMarkdown("   ").isEmpty)
    }

    @Test
    fun errorsDoNotReturnAPartialTranslation() = runBlocking {
        var calls = 0
        val result = runCatching {
            PostTranslationBatch.fromMarkdown("One\nTwo").translatedBody {
                if (++calls == 2) error("fixture failure")
                "translated one"
            }
        }
        assertTrue(result.isFailure)
        assertEquals(2, calls)
    }
}
