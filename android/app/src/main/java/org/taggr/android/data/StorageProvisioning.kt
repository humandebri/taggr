package org.taggr.android.data

import java.math.BigInteger
import java.security.MessageDigest
import org.ic4j.agent.android.*
import org.ic4j.types.Principal

/** ICP CMC payment protocol, matching TAGGR's Swift adapter and the official cmc.did. */
object StorageProvisioning {
    const val CMC = "rkp4c-7iaaa-aaaaa-aaaca-cai"
    const val BLACKHOLE = "e3mmv-5qaaa-aaaah-aadma-cai"
    const val CREATE_MEMO: ULong = 0x41455243u
    const val TOP_UP_MEMO: ULong = 0x50555054u
    private val none =
        CandidValue(CandidType.Optional(CandidType.Primitive.NULL), CandidOption.None)

    fun creationAccount(controller: String) = ICPAccountIdentifier.account(CMC, controller)

    fun topUpAccount(bucket: String) =
        ICPAccountIdentifier.account(CMC, StorageWire.canonicalBucket(bucket))

    fun createArguments(block: ULong, controller: String): ByteArray {
        val settings =
            LedgerWire.record(
                "controllers" to
                    Candid.optional(Candid.vector(Candid.principal))
                        .encode(listOf(controller, BLACKHOLE).distinct().map(Principal::fromString))
            )
        return CandidArguments(
                LedgerWire.record(
                    "block_index" to Candid.nat64.encode(block),
                    "controller" to Candid.principal.encode(Principal.fromString(controller)),
                    "subnet_type" to Candid.optional(Candid.text).encode(null),
                    "subnet_selection" to none,
                    "settings" to
                        CandidValue(
                            CandidType.Optional(settings.type),
                            CandidOption.Some(settings.value),
                        ),
                )
            )
            .encode()
    }

    fun topUpArguments(block: ULong, bucket: String) =
        CandidArguments(
                LedgerWire.record(
                    "block_index" to Candid.nat64.encode(block),
                    "canister_id" to
                        Candid.principal.encode(
                            Principal.fromString(StorageWire.canonicalBucket(bucket))
                        ),
                )
            )
            .encode()

    fun installArguments(bucket: String, owner: String, wasm: VerifiedStorageWasm): ByteArray {
        val mode =
            CandidValue(
                CandidType.Variant(listOf(CandidField("install", CandidType.Primitive.NULL))),
                CandidVariant(Candid.fieldID("install"), null),
            )
        val init =
            CandidArguments(
                    Candid.vector(Candid.principal).encode(listOf(Principal.fromString(owner)))
                )
                .encode()
        return CandidArguments(
                LedgerWire.record(
                    "mode" to mode,
                    "canister_id" to
                        Candid.principal.encode(
                            Principal.fromString(StorageWire.canonicalBucket(bucket))
                        ),
                    "wasm_module" to Candid.blob.encode(wasm.bytes()),
                    "arg" to Candid.blob.encode(init),
                    "sender_canister_version" to Candid.optional(Candid.nat64).encode(null),
                )
            )
            .encode()
    }

    private fun success(bytes: ByteArray): Any? {
        val reply =
            Candid.decode(bytes).values.single().value as? CandidVariant
                ?: error("Invalid CMC reply")
        if (reply.tag == Candid.fieldID("Ok")) return reply.value
        require(reply.tag == Candid.fieldID("Err"))
        val failure = reply.value as? CandidVariant ?: error("Invalid CMC failure")
        fun text(value: Any?) = value as? String ?: error("Invalid CMC error text")
        throw when (failure.tag) {
            Candid.fieldID("Processing") -> {
                require(failure.value == null)
                CMCFailure(
                    "Processing",
                    "This payment is still being processed. Check the same block before sending any more ICP.",
                    true,
                )
            }
            Candid.fieldID("Refunded") -> {
                val block =
                    when (val value = LedgerWire.field(failure.value, "block_index")) {
                        CandidOption.None -> null
                        is CandidOption.Some -> LedgerWire.uint(value.value)
                        else -> error("Invalid refund block")
                    }
                CMCFailure(
                    "Refunded",
                    text(LedgerWire.field(failure.value, "reason")),
                    refundBlock = block,
                )
            }
            Candid.fieldID("TransactionTooOld") ->
                CMCFailure(
                    "TransactionTooOld",
                    "The payment is too old for CMC notification. Oldest accepted block: ${LedgerWire.uint(failure.value)}",
                )
            Candid.fieldID("InvalidTransaction") ->
                CMCFailure("InvalidTransaction", text(failure.value))
            Candid.fieldID("Other") ->
                CMCFailure(
                    "Other",
                    "${LedgerWire.uint(LedgerWire.field(failure.value,"error_code"))}: ${text(LedgerWire.field(failure.value,"error_message"))}",
                )
            else -> error("Unknown CMC failure")
        }
    }

    fun creationReply(bytes: ByteArray) =
        (success(bytes) as? Principal ?: error("Invalid created canister"))
            .toString()
            .let(StorageWire::canonicalBucket)

    fun topUpReply(bytes: ByteArray) =
        (success(bytes) as? BigInteger ?: error("Invalid minted cycles")).also {
            require(it.signum() >= 0)
        }
}

class CMCFailure(
    val kind: String,
    message: String,
    val retryable: Boolean = false,
    val refundBlock: ULong? = null,
) : IllegalStateException(message)

/** No caller can substitute bytes after verification or request an unbounded direct install. */
class VerifiedStorageWasm private constructor(private val data: ByteArray, val hash: String) {
    fun bytes() = data.clone()

    companion object {
        const val MAX_BYTES = 1_500_000

        fun verify(bytes: ByteArray, hash: String): VerifiedStorageWasm {
            require(bytes.size in 4..MAX_BYTES && hash.matches(Regex("[0-9a-f]{64}"))) {
                "Invalid or oversized storage module"
            }
            require(
                bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0, 0x61, 0x73, 0x6d)) ||
                    (bytes.size >= 10 &&
                        bytes[0] == 0x1f.toByte() &&
                        bytes[1] == 0x8b.toByte() &&
                        bytes[2] == 8.toByte())
            ) {
                "Invalid storage Wasm header"
            }
            val copy = bytes.clone()
            require(DraftImages.hex(MessageDigest.getInstance("SHA-256").digest(copy)) == hash) {
                "Storage module hash mismatch"
            }
            return VerifiedStorageWasm(copy, hash)
        }
    }
}
