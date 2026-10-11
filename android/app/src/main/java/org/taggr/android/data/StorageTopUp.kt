package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.math.BigInteger
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CancellationException

data class StorageTopUpQuote(
    val userId: Long,
    val taggr: String,
    val network: String,
    val bucket: String,
    val transfer: TransferQuote,
) {
    init {
        require(userId >= 0 && network.matches(Regex("[0-9a-f]{64}")))
        require(StorageWire.canonicalBucket(taggr) == taggr)
        require(StorageWire.canonicalBucket(bucket) == bucket)
        require(transfer.recipient == DraftImages.hex(StorageProvisioning.topUpAccount(bucket)))
        require(transfer.amount > transfer.fee) {
            "Enter an ICP amount greater than the ledger fee."
        }
    }
}

data class StorageTopUpFailure(
    val kind: String,
    val reason: String,
    val refundBlock: ULong? = null,
) {
    init {
        require(
            kind in listOf("PaymentRejected", "Refunded", "InvalidTransaction", "TransactionTooOld")
        )
        require(reason.length <= 4096)
        require(kind == "Refunded" || refundBlock == null)
    }
}

/** One immutable payment target and original block survive process death and sign-out. */
data class StorageTopUpRecord(
    val quote: StorageTopUpQuote,
    val id: String = UUID.randomUUID().toString(),
    val payment: PendingTransfer? = null,
    val block: ULong? = null,
    val cmcRequests: List<ByteArray> = emptyList(),
    val cycles: BigInteger? = null,
    val failure: StorageTopUpFailure? = null,
) {
    init {
        UUID.fromString(id)
        require(
            payment == null ||
                (payment.quote == quote.transfer && payment.memo == StorageProvisioning.TOP_UP_MEMO)
        )
        require(block == null || payment != null)
        require(cmcRequests.isEmpty() || block != null)
        require(cmcRequests.size <= 32 && cmcRequests.all { it.size == 32 })
        require(cmcRequests.map { DraftImages.hex(it) }.distinct().size == cmcRequests.size)
        require(
            cycles == null || (cycles.signum() >= 0 && cmcRequests.isNotEmpty() && failure == null)
        )
        failure?.let {
            require(payment != null && cycles == null)
            if (it.kind == "PaymentRejected") require(block == null && cmcRequests.isEmpty())
            else require(block != null && cmcRequests.isNotEmpty())
        }
    }

    val finished
        get() = cycles != null || failure != null
}

interface StorageTopUpBackend {
    suspend fun validate(row: StorageTopUpRecord)

    suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit): ULong

    suspend fun paymentResult(payment: PendingTransfer): ULong?

    suspend fun notify(block: ULong, bucket: String, persist: (ByteArray) -> Unit): BigInteger
}

/** Explicit continuation notifies the same CMC block, never creates a second payment. */
class StorageTopUpWorkflow(private val backend: StorageTopUpBackend) {
    suspend fun resume(
        initial: StorageTopUpRecord,
        persist: (StorageTopUpRecord, StorageTopUpRecord) -> Unit,
    ): StorageTopUpRecord {
        var row = initial
        fun save(next: StorageTopUpRecord) {
            persist(row, next)
            row = next
        }
        backend.validate(row)
        if (row.finished) return row
        if (row.block == null) {
            val block =
                try {
                    if (row.payment == null)
                        backend.pay(row.quote.transfer) { save(row.copy(payment = it)) }
                    else
                        backend.paymentResult(row.payment!!)
                            ?: error(
                                "The storage top-up payment result is unavailable. No payment was resent."
                            )
                } catch (e: TransferRejected) {
                    if (row.payment != null)
                        save(
                            row.copy(
                                failure =
                                    StorageTopUpFailure(
                                        "PaymentRejected",
                                        (e.message ?: "Payment rejected").take(4096),
                                    )
                            )
                        )
                    throw e
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    if (row.payment == null) throw e
                    throw IllegalStateException(
                        "The top-up payment result is unknown. Use Check and continue before making another payment. Nothing was automatically resent.",
                        e,
                    )
                }
            save(row.copy(block = block))
        }
        val cycles =
            try {
                backend.notify(row.block!!, row.quote.bucket) {
                    save(row.copy(cmcRequests = row.cmcRequests + it.clone()))
                }
            } catch (e: CMCFailure) {
                if (e.kind in listOf("Refunded", "InvalidTransaction", "TransactionTooOld"))
                    save(
                        row.copy(
                            failure =
                                StorageTopUpFailure(
                                    e.kind,
                                    (e.message ?: "Top-up failed").take(4096),
                                    e.refundBlock,
                                )
                        )
                    )
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                if (row.cmcRequests.isEmpty()) throw e
                throw IllegalStateException(
                    "The storage top-up result is unknown. Use Check and continue with the recorded payment. No new ICP payment will be sent.",
                    e,
                )
            }
        save(row.copy(cycles = cycles))
        return row
    }
}

object StorageTopUpCodec {
    private val mapper = ObjectMapper()

    private fun ids(v: List<ByteArray>) = v.map { Base64.getEncoder().encodeToString(it) }

    fun encode(row: StorageTopUpRecord): ByteArray {
        val q = row.quote
        val t = q.transfer
        return mapper.writeValueAsBytes(
            linkedMapOf(
                "version" to 1,
                "id" to row.id,
                "owner" to t.owner,
                "network" to q.network,
                "taggr" to q.taggr,
                "bucket" to q.bucket,
                "userId" to q.userId,
                "ledgerNetwork" to t.network,
                "recipient" to t.recipient,
                "amount" to t.amount.toString(),
                "fee" to t.fee.toString(),
                "preparedAtMillis" to t.preparedAtMillis,
                "payment" to
                    row.payment?.let {
                        linkedMapOf(
                            "requestId" to ids(listOf(it.requestId)).single(),
                            "createdAtNanos" to it.createdAtNanos.toString(),
                            "memo" to it.memo.toString(),
                            "replays" to ids(it.replayRequestIds),
                        )
                    },
                "block" to row.block?.toString(),
                "cmcRequests" to ids(row.cmcRequests),
                "cycles" to row.cycles?.toString(),
                "failure" to
                    row.failure?.let {
                        linkedMapOf(
                            "kind" to it.kind,
                            "reason" to it.reason,
                            "refundBlock" to it.refundBlock?.toString(),
                        )
                    },
            )
        )
    }

    fun decode(bytes: ByteArray, owner: String, network: String): StorageTopUpRecord {
        require(bytes.size <= 32768)
        val n = mapper.readTree(bytes)
        require(n.isObject && n.required("version").isInt && n["version"].asInt() == 1)
        fun text(k: String) = n.required(k).also { require(it.isTextual) }.asText()
        fun long(k: String) =
            n.required(k).also { require(it.isIntegralNumber && it.canConvertToLong()) }.asLong()
        require(text("owner") == owner && text("network") == network) {
            "Top-up belongs to a different wallet or network."
        }
        fun nullable(k: String) =
            n.required(k).takeUnless { it.isNull }?.also { require(it.isTextual) }?.asText()
        fun requestIds(node: com.fasterxml.jackson.databind.JsonNode): List<ByteArray> {
            require(node.isArray && node.size() <= 32)
            return node.map {
                require(it.isTextual)
                Base64.getDecoder().decode(it.asText()).also { require(it.size == 32) }
            }
        }
        val transfer =
            TransferQuote(
                owner,
                text("ledgerNetwork"),
                text("recipient"),
                text("amount").toULong(),
                text("fee").toULong(),
                long("preparedAtMillis"),
            )
        val quote =
            StorageTopUpQuote(long("userId"), text("taggr"), network, text("bucket"), transfer)
        val payment =
            n.required("payment")
                .takeUnless { it.isNull }
                ?.let {
                    fun pt(k: String) = it.required(k).also { require(it.isTextual) }.asText()
                    PendingTransfer(
                        transfer,
                        Base64.getDecoder().decode(pt("requestId")),
                        pt("createdAtNanos").toULong(),
                        pt("memo").toULong(),
                        requestIds(it.required("replays")),
                    )
                }
        val failure =
            n.required("failure")
                .takeUnless { it.isNull }
                ?.let {
                    require(
                        it.isObject &&
                            it.required("kind").isTextual &&
                            it.required("reason").isTextual
                    )
                    val refund =
                        it.required("refundBlock")
                            .takeUnless { it.isNull }
                            ?.also { require(it.isTextual) }
                            ?.asText()
                            ?.toULong()
                    StorageTopUpFailure(it["kind"].asText(), it["reason"].asText(), refund)
                }
        return StorageTopUpRecord(
            quote,
            text("id"),
            payment,
            nullable("block")?.toULong(),
            requestIds(n.required("cmcRequests")),
            nullable("cycles")?.toBigInteger(),
            failure,
        )
    }
}

/** Atomic compare-and-update prevents a stale continuation from overwriting newer receipts. */
class StorageTopUpStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-storage-top-up")

    private fun file(owner: String, network: String) =
        AtomicFile(
            File(
                root,
                DraftImages.hex(
                    MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
                ) + ".json",
            )
        )

    fun load(owner: String, network: String): StorageTopUpRecord? =
        synchronized(gate) {
            val f = file(owner, network)
            val backup = File(f.baseFile.path + ".bak")
            if (!f.baseFile.exists() && !backup.exists()) return@synchronized null
            require(f.baseFile.length() <= 32768 && backup.length() <= 32768)
            StorageTopUpCodec.decode(f.readFully(), owner, network)
        }

    fun create(row: StorageTopUpRecord) =
        synchronized(gate) {
            require(row.payment == null && !row.finished)
            require(load(row.quote.transfer.owner, row.quote.network) == null) {
                "Check the previous storage top-up first."
            }
            write(row)
        }

    fun update(old: StorageTopUpRecord, next: StorageTopUpRecord) =
        synchronized(gate) {
            require(!old.finished && old.id == next.id && old.quote == next.quote)
            val current =
                load(old.quote.transfer.owner, old.quote.network) ?: error("Top-up record missing")
            require(
                StorageTopUpCodec.encode(current).contentEquals(StorageTopUpCodec.encode(old))
            ) {
                "Top-up changed. Reload its progress."
            }
            require(old.block == null || old.block == next.block)
            require(old.payment == null || next.payment?.matches(old.payment) == true)
            require(
                next.cmcRequests.size >= old.cmcRequests.size &&
                    old.cmcRequests.zip(next.cmcRequests).all { (a, b) -> a.contentEquals(b) }
            )
            write(next)
        }

    private fun write(row: StorageTopUpRecord) {
        check(root.mkdirs() || root.isDirectory)
        val bytes = StorageTopUpCodec.encode(row)
        require(bytes.size <= 32768)
        val f = file(row.quote.transfer.owner, row.quote.network)
        val stream = f.startWrite()
        try {
            stream.write(bytes)
            f.finishWrite(stream)
        } catch (e: Exception) {
            f.failWrite(stream)
            throw e
        }
    }

    fun discardUnpaid(row: StorageTopUpRecord) =
        synchronized(gate) {
            require(row.payment == null)
            delete(row)
        }

    fun acknowledge(row: StorageTopUpRecord) =
        synchronized(gate) {
            require(row.finished)
            val current =
                load(row.quote.transfer.owner, row.quote.network) ?: error("Top-up record missing")
            require(StorageTopUpCodec.encode(current).contentEquals(StorageTopUpCodec.encode(row)))
            // Retain the confirmed receipt separately before allowing another payment.
            val receipt =
                File(file(row.quote.transfer.owner, row.quote.network).baseFile.path + ".receipt")
            val f = AtomicFile(receipt)
            val stream = f.startWrite()
            try {
                stream.write(StorageTopUpCodec.encode(row))
                f.finishWrite(stream)
            } catch (e: Exception) {
                f.failWrite(stream)
                throw e
            }
            delete(row)
        }

    fun latestReceipt(owner: String, network: String): StorageTopUpRecord? =
        synchronized(gate) {
            val target = AtomicFile(File(file(owner, network).baseFile.path + ".receipt"))
            val backup = File(target.baseFile.path + ".bak")
            if (!target.baseFile.exists() && !backup.exists()) return@synchronized null
            require(target.baseFile.length() <= 32768 && backup.length() <= 32768)
            StorageTopUpCodec.decode(target.readFully(), owner, network).also {
                require(it.finished)
            }
        }

    private fun delete(row: StorageTopUpRecord) {
        val current =
            load(row.quote.transfer.owner, row.quote.network) ?: error("Top-up record missing")
        require(StorageTopUpCodec.encode(current).contentEquals(StorageTopUpCodec.encode(row)))
        val f = file(row.quote.transfer.owner, row.quote.network)
        f.delete()
        check(!f.baseFile.exists() && !File(f.baseFile.path + ".bak").exists())
    }

    companion object {
        private val gate = Any()
    }
}
