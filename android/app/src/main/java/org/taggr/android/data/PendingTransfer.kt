package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.math.BigInteger
import java.security.MessageDigest
import org.ic4j.agent.android.ICClientConfiguration
import org.ic4j.agent.android.ICPAccountIdentifier
import org.ic4j.agent.android.ICPAmount

// Gateways and application contexts may change; the wallet's ledger and trust root define its
// chain.
fun transferNetwork(configuration: ICClientConfiguration): String =
    DraftImages.hex(
        MessageDigest.getInstance("SHA-256")
            .digest(
                (DraftImages.hex(configuration.rootKey) + "/" + LedgerWire.CANISTER).toByteArray()
            )
    )

data class TransferQuote(
    val owner: String,
    val network: String,
    val recipient: String,
    val amount: ULong,
    val fee: ULong,
    val preparedAtMillis: Long,
) {
    init {
        require(
            owner.isNotBlank() &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                recipient.matches(Regex("[0-9a-f]{64}")) &&
                amount > 0uL
        )
        ICPAccountIdentifier.parse(recipient)
        require(
            BigInteger(amount.toString()) + BigInteger(fee.toString()) <=
                BigInteger(ULong.MAX_VALUE.toString())
        )
    }

    fun validate(snapshot: WalletSnapshot, nowMillis: Long) {
        require(snapshot.owner == owner) {
            "The wallet identity changed. Prepare the transfer again."
        }
        require(nowMillis >= preparedAtMillis && nowMillis - preparedAtMillis <= 120_000) {
            "This confirmation expired. Review the transfer again."
        }
        require(snapshot.feeE8s == fee) { "The fee changed. Review the transfer again." }
        require(
            BigInteger(amount.toString()) + BigInteger(fee.toString()) <=
                BigInteger(snapshot.balanceE8s.toString())
        ) {
            "Insufficient ICP for the amount and fee."
        }
    }

    companion object {
        fun prepare(
            recipient: String,
            amount: String,
            snapshot: WalletSnapshot,
            network: String,
            nowMillis: Long,
        ): TransferQuote {
            val value = ICPAmount.parse(amount)
            require(value != null && value > 0uL) {
                "Enter a valid positive ICP amount with at most eight decimal places."
            }
            val to =
                try {
                    ICPAccountIdentifier.parse(recipient)
                } catch (e: org.ic4j.types.PrincipalError) {
                    throw IllegalArgumentException(
                        "Enter a valid Principal or ICP account identifier.",
                        e,
                    )
                }
            return TransferQuote(
                    snapshot.owner,
                    network,
                    DraftImages.hex(to),
                    value,
                    snapshot.feeE8s,
                    nowMillis,
                )
                .also { it.validate(snapshot, nowMillis) }
        }
    }
}

data class PendingTransfer(
    val quote: TransferQuote,
    val requestId: ByteArray,
    val createdAtNanos: ULong,
    val memo: ULong,
    val replayRequestIds: List<ByteArray> = emptyList(),
) {
    init {
        require(requestId.size == 32 && createdAtNanos > 0uL)
        require(replayRequestIds.size <= 32 && replayRequestIds.all { it.size == 32 })
        require(
            allRequestIds
                .map { java.util.Base64.getEncoder().encodeToString(it) }
                .distinct()
                .size == allRequestIds.size
        )
    }

    fun arguments(): ByteArray =
        LedgerWire.transferArguments(
            ICPAccountIdentifier.parse(quote.recipient),
            quote.amount,
            quote.fee,
            memo,
            createdAtNanos,
        )

    val allRequestIds
        get() = listOf(requestId) + replayRequestIds

    fun validateReplay(nowNanos: ULong) {
        require(nowNanos >= createdAtNanos && nowNanos - createdAtNanos <= 82_800_000_000_000uL) {
            "This transfer is too old for safe replay. Keep its record and verify the transaction history."
        }
        require(replayRequestIds.size < 32) {
            "Too many replay attempts. Check the recorded results before retrying."
        }
    }

    fun matches(other: PendingTransfer): Boolean =
        quote == other.quote &&
            createdAtNanos == other.createdAtNanos &&
            memo == other.memo &&
            allRequestIds.size == other.allRequestIds.size &&
            allRequestIds.zip(other.allRequestIds).all { (a, b) -> a.contentEquals(b) }
}

/** Survives sign-out; an unresolved payment cannot be silently dropped on reauthentication. */
class PendingTransferStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-pending-transfers")
    private val mapper = ObjectMapper()

    private fun file(owner: String, network: String) =
        AtomicFile(
            File(
                root,
                DraftImages.hex(
                    MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
                ) + ".json",
            )
        )

    fun save(value: PendingTransfer) =
        synchronized(gate) {
            require(load(value.quote.owner, value.quote.network) == null) {
                "A previous transfer must be confirmed first."
            }
            write(value)
        }

    private fun write(value: PendingTransfer) {
        check(root.mkdirs() || root.isDirectory)
        val file = file(value.quote.owner, value.quote.network)
        val bytes =
            mapper.writeValueAsBytes(
                mapOf(
                    "owner" to value.quote.owner,
                    "network" to value.quote.network,
                    "recipient" to value.quote.recipient,
                    "amount" to value.quote.amount.toString(),
                    "fee" to value.quote.fee.toString(),
                    "preparedAtMillis" to value.quote.preparedAtMillis,
                    "requestId" to java.util.Base64.getEncoder().encodeToString(value.requestId),
                    "createdAtNanos" to value.createdAtNanos.toString(),
                    "memo" to value.memo.toString(),
                    "replayRequestIds" to
                        value.replayRequestIds.map {
                            java.util.Base64.getEncoder().encodeToString(it)
                        },
                )
            )
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (e: Exception) {
            file.failWrite(stream)
            throw e
        }
    }

    fun load(owner: String, network: String): PendingTransfer? =
        synchronized(gate) {
            val file = file(owner, network)
            val backup = File(file.baseFile.path + ".bak")
            if (!file.baseFile.exists() && !backup.exists()) return@synchronized null
            require(file.baseFile.length() <= 8192 && backup.length() <= 8192) {
                "Invalid pending transfer"
            }
            val bytes = file.readFully()
            require(bytes.size <= 8192)
            val row = mapper.readTree(bytes)
            require(
                row.required("owner").asText() == owner &&
                    row.required("network").asText() == network
            ) {
                "Transfer belongs to a different wallet or network."
            }
            val quote =
                TransferQuote(
                    owner,
                    network,
                    row.required("recipient").asText(),
                    row.required("amount").asText().toULong(),
                    row.required("fee").asText().toULong(),
                    row.required("preparedAtMillis").asLong(),
                )
            return@synchronized PendingTransfer(
                quote,
                java.util.Base64.getDecoder().decode(row.required("requestId").asText()),
                row.required("createdAtNanos").asText().toULong(),
                row.required("memo").asText().toULong(),
                row["replayRequestIds"]?.let { ids ->
                    require(ids.isArray && ids.size() <= 32)
                    ids.map { java.util.Base64.getDecoder().decode(it.asText()) }
                } ?: emptyList(),
            )
        }

    fun appendReplay(expected: PendingTransfer, requestId: ByteArray): PendingTransfer =
        synchronized(gate) {
            val current =
                load(expected.quote.owner, expected.quote.network)
                    ?: error("Pending transfer missing")
            require(current.matches(expected)) { "The pending transfer changed. Check it again." }
            val updated =
                current.copy(
                    replayRequestIds = current.replayRequestIds + listOf(requestId.copyOf())
                )
            write(updated)
            updated
        }

    fun clear(value: PendingTransfer) =
        synchronized(gate) {
            val existing = load(value.quote.owner, value.quote.network) ?: return@synchronized
            require(existing.matches(value)) {
                "The pending transfer changed."
            }
            val file = file(value.quote.owner, value.quote.network)
            file.delete()
            check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) {
                "Transfer record could not be cleared."
            }
        }

    companion object {
        private val gate = Any()
    }
}

class TransferRejected(message: String) : IllegalStateException(message)

fun confirmedTransfer(result: LedgerTransferResult): ULong =
    when (result) {
        is LedgerTransferResult.Completed -> result.block
        is LedgerTransferResult.BadFee ->
            throw TransferRejected(
                "The ledger fee is now ${ICPAmount.format(result.expected)}. Review the transfer again."
            )
        is LedgerTransferResult.InsufficientFunds ->
            throw TransferRejected(
                "Insufficient funds. Ledger balance: ${ICPAmount.format(result.balance)}."
            )
        is LedgerTransferResult.TooOld ->
            throw TransferRejected("This transfer timestamp is too old. The ledger rejected it.")
        LedgerTransferResult.CreatedInFuture ->
            throw TransferRejected(
                "The transfer timestamp is in the future. Check your device clock."
            )
    }

sealed interface TransferProbe {
    data class Paid(val block: ULong) : TransferProbe

    data class Rejected(val reason: String) : TransferProbe

    data object Unknown : TransferProbe
}

fun resolveTransferProbes(results: List<TransferProbe>): ULong? {
    results.filterIsInstance<TransferProbe.Paid>().firstOrNull()?.let {
        return it.block
    }
    if (results.isNotEmpty() && results.all { it is TransferProbe.Rejected })
        throw TransferRejected((results.first() as TransferProbe.Rejected).reason)
    return null
}
