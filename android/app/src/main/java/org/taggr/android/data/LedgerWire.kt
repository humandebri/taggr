package org.taggr.android.data

import java.math.BigInteger
import org.ic4j.agent.android.*

/** Legacy ICP transfer shape, shared with Swift, with an explicit deduplication timestamp. */
object LedgerWire {
    const val CANISTER = "ryjl3-tyaaa-aaaaa-aaaba-cai"

    fun record(vararg fields: Pair<String, CandidValue>): CandidValue =
        CandidValue(
            CandidType.Record(fields.map { CandidField(it.first, it.second.type) }),
            fields.associate { Candid.fieldID(it.first) to it.second.value },
        )

    fun balanceArguments(account: ByteArray): ByteArray {
        require(account.size == 32)
        return CandidArguments(record("account" to Candid.blob.encode(account))).encode()
    }

    fun transferArguments(
        to: ByteArray,
        amount: ULong,
        fee: ULong,
        memo: ULong,
        createdAtNanos: ULong,
    ): ByteArray {
        require(to.size == 32 && amount > 0uL && createdAtNanos > 0uL)
        require(
            BigInteger(amount.toString()) + BigInteger(fee.toString()) <=
                BigInteger(ULong.MAX_VALUE.toString())
        ) {
            "Amount plus fee exceeds the supported range."
        }
        val time = record("timestamp_nanos" to Candid.nat64.encode(createdAtNanos))
        return CandidArguments(
                record(
                    "to" to Candid.blob.encode(to),
                    "amount" to record("e8s" to Candid.nat64.encode(amount)),
                    "fee" to record("e8s" to Candid.nat64.encode(fee)),
                    "memo" to Candid.nat64.encode(memo),
                    "from_subaccount" to Candid.optional(Candid.blob).encode(null),
                    "created_at_time" to
                        CandidValue(CandidType.Optional(time.type), CandidOption.Some(time.value)),
                )
            )
            .encode()
    }

    fun uint(value: Any?): ULong {
        val number = value as? BigInteger ?: error("Invalid ledger amount")
        require(number.signum() >= 0 && number.bitLength() <= 64) { "Invalid ledger amount" }
        return number.toString().toULong()
    }

    fun field(value: Any?, name: String): Any? =
        (value as? Map<*, *>)?.get(Candid.fieldID(name)) ?: error("Missing ledger field: $name")

    fun balanceReply(bytes: ByteArray) =
        uint(field(Candid.decode(bytes).values.single().value, "e8s"))

    fun feeReply(bytes: ByteArray) = uint(Candid.decode(bytes).values.single().value)

    fun transferReply(bytes: ByteArray): LedgerTransferResult {
        val result =
            Candid.decode(bytes).values.single().value as? CandidVariant
                ?: error("Invalid transfer reply")
        if (result.tag == Candid.fieldID("Ok"))
            return LedgerTransferResult.Completed(uint(result.value))
        require(result.tag == Candid.fieldID("Err")) { "Unknown transfer reply" }
        val failure = result.value as? CandidVariant ?: error("Invalid transfer error")
        return when (failure.tag) {
            Candid.fieldID("TxDuplicate") ->
                LedgerTransferResult.Completed(uint(field(failure.value, "duplicate_of")), true)
            Candid.fieldID("BadFee") ->
                LedgerTransferResult.BadFee(
                    uint(field(field(failure.value, "expected_fee"), "e8s"))
                )
            Candid.fieldID("InsufficientFunds") ->
                LedgerTransferResult.InsufficientFunds(
                    uint(field(field(failure.value, "balance"), "e8s"))
                )
            Candid.fieldID("TxTooOld") ->
                LedgerTransferResult.TooOld(uint(field(failure.value, "allowed_window_nanos")))
            Candid.fieldID("TxCreatedInFuture") -> {
                require(failure.value == null)
                LedgerTransferResult.CreatedInFuture
            }
            else -> error("Unknown ledger transfer error")
        }
    }
}

sealed interface LedgerTransferResult {
    data class Completed(val block: ULong, val duplicate: Boolean = false) : LedgerTransferResult

    data class BadFee(val expected: ULong) : LedgerTransferResult

    data class InsufficientFunds(val balance: ULong) : LedgerTransferResult

    data class TooOld(val allowedWindowNanos: ULong) : LedgerTransferResult

    data object CreatedInFuture : LedgerTransferResult
}

data class WalletSnapshot(
    val owner: String,
    val balanceE8s: ULong,
    val feeE8s: ULong,
    val tokenDecimals: Int,
)
