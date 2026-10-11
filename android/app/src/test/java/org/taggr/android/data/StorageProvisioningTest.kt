package org.taggr.android.data

import java.math.BigInteger
import java.security.MessageDigest
import org.ic4j.agent.android.*
import org.ic4j.types.Principal
import org.junit.Assert.*
import org.junit.Test

class StorageProvisioningTest {
    private fun hash(bytes: ByteArray) =
        DraftImages.hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun variant(name: String, value: CandidValue) =
        CandidValue(
            CandidType.Variant(listOf(CandidField(name, value.type))),
            CandidVariant(Candid.fieldID(name), value.value),
        )

    @Test
    fun createPaymentAndNotificationRetainControllerAndLedgerBlock() {
        val owner = "2vxsx-fae"
        val args =
            Candid.decode(StorageProvisioning.createArguments(ULong.MAX_VALUE, owner))
                .values
                .single()
                .value
        assertEquals(ULong.MAX_VALUE, LedgerWire.uint(LedgerWire.field(args, "block_index")))
        assertEquals(Principal.fromString(owner), LedgerWire.field(args, "controller"))
        val settings = LedgerWire.field(args, "settings") as CandidOption.Some
        val controllers = LedgerWire.field(settings.value, "controllers") as CandidOption.Some
        assertEquals(
            listOf(owner, StorageProvisioning.BLACKHOLE),
            (controllers.value as List<*>).map { (it as Principal).toString() },
        )
        assertArrayEquals(
            ICPAccountIdentifier.account(StorageProvisioning.CMC, owner),
            StorageProvisioning.creationAccount(owner),
        )
        assertNotEquals(StorageProvisioning.CREATE_MEMO, StorageProvisioning.TOP_UP_MEMO)
        val success =
            CandidArguments(
                    variant(
                        "Ok",
                        Candid.principal.encode(Principal.fromString("rrkah-fqaaa-aaaaa-aaaaq-cai")),
                    )
                )
                .encode()
        assertEquals("rrkah-fqaaa-aaaaa-aaaaq-cai", StorageProvisioning.creationReply(success))
    }

    @Test
    fun processingAndRefundRemainDistinctWithoutSendingAnotherPayment() {
        val processing =
            CandidArguments(variant("Err", variant("Processing", Candid.nullValue.encode(Unit))))
                .encode()
        val pending =
            assertThrows(CMCFailure::class.java) { StorageProvisioning.creationReply(processing) }
        assertTrue(pending.retryable)
        val refund =
            LedgerWire.record(
                "reason" to Candid.text.encode("Not allowed"),
                "block_index" to Candid.optional(Candid.nat64).encode(99uL),
            )
        val error =
            assertThrows(CMCFailure::class.java) {
                StorageProvisioning.creationReply(
                    CandidArguments(variant("Err", variant("Refunded", refund))).encode()
                )
            }
        assertFalse(error.retryable)
        assertEquals(99uL, error.refundBlock)
        val cycles = BigInteger.ONE.shiftLeft(100)
        assertEquals(
            cycles,
            StorageProvisioning.topUpReply(
                CandidArguments(variant("Ok", Candid.nat.encode(cycles))).encode()
            ),
        )
    }

    @Test
    fun immutableVerifiedWasmAndInstallModeProtectExistingCode() {
        val bytes = byteArrayOf(0, 0x61, 0x73, 0x6d, 1, 0, 0, 0)
        val wasm = VerifiedStorageWasm.verify(bytes, hash(bytes))
        bytes[4] = 9
        val exposed = wasm.bytes()
        exposed[4] = 7
        assertEquals(1.toByte(), wasm.bytes()[4])
        assertThrows(IllegalArgumentException::class.java) {
            VerifiedStorageWasm.verify(bytes, wasm.hash)
        }
        val args =
            Candid.decode(
                    StorageProvisioning.installArguments(
                        "rrkah-fqaaa-aaaaa-aaaaq-cai",
                        "2vxsx-fae",
                        wasm,
                    )
                )
                .values
                .single()
                .value
        assertEquals(
            Candid.fieldID("install"),
            (LedgerWire.field(args, "mode") as CandidVariant).tag,
        )
        val init =
            Candid.decode(LedgerWire.field(args, "arg") as ByteArray).values.single().value
                as List<*>
        assertEquals(listOf(Principal.fromString("2vxsx-fae")), init)
    }
}
