package org.taggr.android

import org.junit.Assert.*
import org.junit.Test

class ImageInsertionTest {
    @Test
    fun ticketRejectsChangedBodyAndOwnerButSurvivesStringRestoration() {
        val ticket = imageInsertionTicket("owner/reply/1", "AB", 1)
        assertEquals(
            1,
            imageInsertionOffset(ticket.toCharArray().concatToString(), "owner/reply/1", "AB"),
        )
        assertNull(imageInsertionOffset(ticket, "other/reply/1", "AB"))
        assertNull(imageInsertionOffset(ticket, "owner/reply/1", "AC"))
        assertNull(imageInsertionOffset("bad", "owner/reply/1", "AB"))
    }

    @Test
    fun selectedTextIsRetainedAndMarkersInsertInOrderAtCursor() {
        val edit = insertDraftImages("AB", listOf("![a](/blob/a)", "![b](/blob/b)"), 1)
        assertEquals("A\n\n![a](/blob/a)\n![b](/blob/b)\nB", edit.text)
        assertEquals(edit.text.length - 1, edit.selection.start)
        assertEquals(edit.selection.start, edit.selection.end)
    }

    @Test
    fun blankAndImageLinesMatchSwiftSpacingAndUtf16Offsets() {
        assertEquals("![a](/blob/a)\n", insertDraftImages("", listOf("![a](/blob/a)"), 0).text)
        assertEquals(
            "🧡\n![a](/blob/a)\nTail",
            insertDraftImages("🧡\nTail", listOf("![a](/blob/a)"), 3).text,
        )
        assertEquals(
            "![a](/blob/a)![b](/blob/b)\n",
            insertDraftImages("![a](/blob/a)", listOf("![b](/blob/b)"), 13).text,
        )
        assertEquals("body", insertDraftImages("body", emptyList(), 999).text)
    }
}
