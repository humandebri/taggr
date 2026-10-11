package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Test

class ProposalsTest {
    private val mapper = ObjectMapper()

    private fun reply(payload: String) =
        mapper.readTree(
            """{"Ok":{"id":7,"proposer":1,"timestamp":1000000000,"post_id":8,"status":"Open","payload":$payload,"bulletins":[[1,true,50]],"voting_power":100}}"""
        )

    @Test
    fun payloadsMatchBackendShapesAndRejectWrongProposalOrTruncatedAmounts() {
        val funding =
            TaggrProposal.decode(reply("""{"Funding":["2vxsx-fae",18446744073709551615]}"""), 7)
        assertEquals(ULong.MAX_VALUE, funding.payload.amount)
        assertEquals("FUNDING", funding.payload.title)
        val realm = TaggrProposal.decode(reply("""{"AddRealmController":["TEST",2]}"""), 7)
        assertEquals(2L, realm.payload.user)
        assertEquals("TEST", realm.payload.realm)
        assertEquals("Unsupported", TaggrProposal.decode(reply("\"Noop\""), 7).payload.kind)
        assertThrows(IllegalArgumentException::class.java) {
            TaggrProposal.decode(reply("""{"Funding":["2vxsx-fae",-1]}"""), 7)
        }
        assertThrows(IllegalArgumentException::class.java) {
            TaggrProposal.decode(reply("""{"Rewards":{"receiver":"2vxsx-fae","minted":1}}"""), 8)
        }
        assertThrows(IllegalArgumentException::class.java) {
            TaggrProposal.decode(reply("""{"ICPTransfer":[[256],{"e8s":1}]}"""), 7)
        }
    }

    @Test
    fun percentagesAndDeadlinesUseExactArithmeticWithoutUnsignedWraparound() {
        val proposal =
            TaggrProposal.decode(reply("""{"Release":{"commit":"abc","hash":"def"}}"""), 7)
        assertEquals("50%", proposal.percentage(true))
        assertEquals(BigInteger.valueOf(25), proposal.executionDays(66))
        assertEquals(BigInteger.ONE, TaggrProposal.displayedPower(BigInteger.valueOf(50), 2))
        val maximum =
            proposal.copy(
                votingPower = ULong.MAX_VALUE,
                bulletins =
                    listOf(
                        ProposalBulletin(1, true, ULong.MAX_VALUE),
                        ProposalBulletin(2, true, ULong.MAX_VALUE),
                    ),
            )
        assertEquals(BigInteger(ULong.MAX_VALUE.toString()) * BigInteger.TWO, maximum.power(true))
        assertEquals("200%", maximum.percentage(true))
        assertEquals("0%", proposal.copy(votingPower = 0uL).percentage(true))
        assertNull(proposal.copy(status = "Executed").executionDays(66))
        assertNull(proposal.executionDays(100))
    }
}
