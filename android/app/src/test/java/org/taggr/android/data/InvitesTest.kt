package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.net.URI
import org.junit.Assert.*
import org.junit.Test

class InvitesTest {
    private val invite = TaggrInvite("abcdef1234", 100uL, 50uL, listOf(7), "TEST", 1)

    @Test
    fun reservationsCannotOverspendAndUnusedInviteCannotStop() {
        InviteDraft(50uL, 50uL, "TEST").validate(invite, listOf(invite), 50uL, 50uL)
        assertThrows(IllegalArgumentException::class.java) {
            InviteDraft(100uL, 50uL, "").validate(null, listOf(invite), 150uL, 50uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            InviteDraft(0uL, 50uL, "")
                .validate(
                    invite.copy(joined = emptyList()),
                    listOf(invite.copy(joined = emptyList())),
                    100uL,
                    50uL,
                )
        }
        assertThrows(IllegalArgumentException::class.java) {
            InviteDraft(75uL, 50uL, "").validate(null, emptyList(), 100uL, 50uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            InviteDraft(10uL, 10uL, "").validate(null, emptyList(), 100uL, 50uL)
        }
        assertThrows(IllegalArgumentException::class.java) {
            InviteDraft(50uL, 50uL, "")
                .validate(invite, listOf(invite.copy(credits = 50uL)), 100uL, 50uL)
        }
    }

    @Test
    fun decodeAndSignedArgumentsPreserveUnsignedPrecisionAndRejectMalformedData() {
        val mapper = ObjectMapper()
        val row =
            mapper.readTree(
                """[["abcdef1234",{"credits":18446744073709551615,"credits_per_user":1,"joined_user_ids":[7,7],"realm_id":null,"inviter_user_id":1}]]"""
            )
        val decoded = Invites.decode(row).single()
        assertEquals(ULong.MAX_VALUE, decoded.credits)
        assertEquals(listOf(7L), decoded.joined)
        val args = InviteDraft(ULong.MAX_VALUE, 1uL, "").arguments(null)
        assertTrue(InviteArguments.valid("create_invite", args))
        assertEquals(ULong.MAX_VALUE.toString(), mapper.readTree(args)[0].asText())
        assertTrue(
            InviteArguments.valid(
                "update_invite",
                InviteDraft(0uL, 50uL, "").arguments(invite.code),
            )
        )
        assertFalse(InviteArguments.valid("create_invite", "[100,0,null]".toByteArray()))
        assertFalse(
            InviteArguments.valid("update_invite", """["abcdef1234",-1,null]""".toByteArray())
        )
        FinancialCall("owner", "canister", "a".repeat(64), "create_invite", ByteArray(32), args)
        assertTrue(FinancialReply.decode("create_invite", """{"Ok":null}""".toByteArray()).isNull)
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode("update_invite", """{"Err":"Rejected"}""".toByteArray())
        }
        assertThrows(IllegalArgumentException::class.java) {
            Invites.decode(mapper.readTree("""[["bad",{}]]"""))
        }
    }

    @Test
    fun sharedCodeAndQRResolveToSameInviteURLOnConfiguredOrigin() {
        assertEquals("abcdef1234", Invites.code(" ABCDEF1234 "))
        assertEquals("TEST", Invites.realm(" /test/ "))
        val url = Invites.url(invite.code, URI("https://example.com"))
        assertEquals("https://example.com/#/welcome/abcdef1234", url)
        val matrix = InviteQR.matrix(url)
        val scale = 8
        val side = matrix.width * scale
        val pixels =
            IntArray(side * side) { index ->
                if (matrix[(index % side) / scale, (index / side) / scale]) 0xff000000.toInt()
                else 0xffffffff.toInt()
            }
        val decoded =
            MultiFormatReader()
                .decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(side, side, pixels))))
        assertEquals(url, decoded.text)
        assertThrows(IllegalArgumentException::class.java) {
            Invites.url(invite.code, URI("javascript:alert(1)"))
        }
    }
}
