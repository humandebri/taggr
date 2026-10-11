package org.taggr.android.data

import java.nio.ByteBuffer
import java.util.zip.CRC32
import org.junit.Assert.*
import org.junit.Test

class TransferReplayTest {
    private val recipient =
        ByteArray(32)
            .also { bytes ->
                ByteBuffer.allocate(4)
                    .putInt(CRC32().apply { update(bytes, 4, 28) }.value.toInt())
                    .array()
                    .copyInto(bytes)
            }
            .let { DraftImages.hex(it) }

    private fun pending() =
        PendingTransfer(
            TransferQuote("2vxsx-fae", "a".repeat(64), recipient, 123000000u, 10000u, 1),
            ByteArray(32),
            1000000000u,
            1234u,
        )

    @Test
    fun replayNeverChangesTheOriginalWireArguments() {
        val original = pending()
        val replay = original.copy(replayRequestIds = listOf(ByteArray(32) { 1 }))
        assertArrayEquals(original.arguments(), replay.arguments())
        assertEquals(2, replay.allRequestIds.size)
        assertFalse(original.matches(replay))
    }

    @Test
    fun onlyAnySuccessOrEveryConfirmedRejectionResolvesPayment() {
        assertNull(
            resolveTransferProbes(
                listOf(TransferProbe.Unknown, TransferProbe.Rejected("Replay rejected"))
            )
        )
        assertEquals(
            7uL,
            resolveTransferProbes(listOf(TransferProbe.Unknown, TransferProbe.Paid(7u))),
        )
        assertThrows(TransferRejected::class.java) {
            resolveTransferProbes(
                listOf(
                    TransferProbe.Rejected("First rejected"),
                    TransferProbe.Rejected("Second rejected"),
                )
            )
        }
        assertNull(resolveTransferProbes(emptyList()))
    }

    @Test
    fun replayRequiresOriginalWindowAndDistinctRequestIds() {
        val pending = pending()
        pending.validateReplay(pending.createdAtNanos + 82_800_000_000_000u)
        assertThrows(IllegalArgumentException::class.java) {
            pending.validateReplay(pending.createdAtNanos + 82_800_000_000_001u)
        }
        assertThrows(IllegalArgumentException::class.java) {
            pending.validateReplay(pending.createdAtNanos - 1u)
        }
        assertThrows(IllegalArgumentException::class.java) {
            pending.copy(replayRequestIds = listOf(ByteArray(32)))
        }
        val exhausted =
            pending.copy(replayRequestIds = (1..32).map { n -> ByteArray(32) { n.toByte() } })
        assertThrows(IllegalArgumentException::class.java) {
            exhausted.validateReplay(exhausted.createdAtNanos)
        }
    }
}
