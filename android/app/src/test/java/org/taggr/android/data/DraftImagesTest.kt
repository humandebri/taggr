package org.taggr.android.data

import org.junit.Assert.*
import org.junit.Test

class DraftImagesTest {
    private val image = DraftImage("0123abcd", byteArrayOf(1, 2), 100, 80)

    @Test
    fun editingRetainsStoredImagesWithoutUploadingThemAgain() {
        val ids = DraftImages.storedIds(setOf("ff001122@aaaaa-aa", "deadbeef"))
        assertEquals(setOf("ff001122", "deadbeef"), ids)
        assertTrue(
            DraftImages.referenced("Edited\n![old](/blob/ff001122)", emptyList(), ids).isEmpty()
        )
        assertThrows(IllegalArgumentException::class.java) {
            DraftImages.referenced("![unknown](/blob/ff001123)", emptyList(), ids)
        }
    }

    @Test
    fun onlyActualMarkdownImagesBecomeUploadReferences() {
        assertEquals(
            listOf(image),
            DraftImages.referenced(image.markdown, listOf(image), emptySet()),
        )
        assertTrue(
            DraftImages.referenced("`${image.markdown}`", listOf(image), emptySet()).isEmpty()
        )
        assertTrue(
            DraftImages.referenced("![old](/blob/ff001122)", emptyList(), setOf("ff001122"))
                .isEmpty()
        )
    }

    @Test
    fun missingOrChangedAttachmentsAreRejectedBeforeUploading() {
        assertThrows(IllegalArgumentException::class.java) {
            DraftImages.referenced("![missing](/blob/0123abcd)", emptyList(), emptySet())
        }
        assertThrows(IllegalArgumentException::class.java) {
            DraftImages.referenced("![changed](/blob/0123abcd)", listOf(image), emptySet())
        }
    }
}
