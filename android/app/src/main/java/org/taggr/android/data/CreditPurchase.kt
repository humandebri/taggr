package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** One invoice unit, approved with the actual ledger fee and signing account. */
data class CreditPurchaseQuote(
    val userId: Long,
    val credits: ULong,
    val invoice: CreditInvoiceReceipt,
    val transfer: TransferQuote,
) {
    init {
        require(userId >= 0 && credits > 0uL && !invoice.invoice.paid)
        require(
            transfer.owner == invoice.owner &&
                transfer.recipient == invoice.invoice.account &&
                transfer.amount == invoice.invoice.amountE8s
        )
        require(
            transfer.preparedAtMillis >= invoice.receivedAtMillis &&
                transfer.preparedAtMillis - invoice.receivedAtMillis <= 120000
        )
    }
}

data class CreditPurchaseRecord(
    val quote: CreditPurchaseQuote,
    val id: String = UUID.randomUUID().toString(),
    val payment: PendingTransfer? = null,
    val block: ULong? = null,
    val settlement: FinancialCall? = null,
    val rejectedSettlements: List<FinancialCall> = emptyList(),
    val result: ICPInvoice? = null,
    val paymentFailure: String? = null,
) {
    init {
        UUID.fromString(id)
        require(payment == null || payment.quote == quote.transfer)
        require(block == null || payment != null)
        require(rejectedSettlements.size <= 32)
        for (call in rejectedSettlements + listOfNotNull(settlement)) {
            require(
                block != null &&
                    call.method == "mint_credits_with_icp" &&
                    call.arguments.contentEquals("1".toByteArray()) &&
                    call.owner == quote.invoice.owner &&
                    call.network == quote.invoice.network &&
                    call.canister == quote.invoice.canister
            )
        }
        val ids =
            (rejectedSettlements + listOfNotNull(settlement)).map { DraftImages.hex(it.requestId) }
        require(ids.distinct().size == ids.size)
        result?.let {
            require(
                settlement != null &&
                    it.paid &&
                    it.account == quote.transfer.recipient &&
                    it.amountE8s == quote.transfer.amount &&
                    it.paidE8s == quote.transfer.amount
            )
        }
        paymentFailure?.let { require(payment != null && block == null && it.length <= 4096) }
    }

    val finished
        get() = result != null || paymentFailure != null
}

interface CreditPurchaseBackend {
    suspend fun validate(row: CreditPurchaseRecord)

    suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit): ULong

    suspend fun paymentResult(payment: PendingTransfer): ULong?

    suspend fun settle(persist: (FinancialCall) -> Unit): ICPInvoice

    suspend fun settlementResult(call: FinancialCall): ICPInvoice?
}

/** An uncertain ledger or mint reply is inspected by its original ID, never resent. */
class CreditPurchaseWorkflow(private val backend: CreditPurchaseBackend) {
    suspend fun resume(
        initial: CreditPurchaseRecord,
        persist: (CreditPurchaseRecord, CreditPurchaseRecord) -> Unit,
    ): CreditPurchaseRecord {
        var row = initial
        fun save(next: CreditPurchaseRecord) {
            persist(row, next)
            row = next
        }
        if (row.finished) return row
        backend.validate(row)
        if (row.block == null) {
            val block =
                try {
                    if (row.payment == null)
                        backend.pay(row.quote.transfer) { save(row.copy(payment = it)) }
                    else
                        backend.paymentResult(row.payment!!)
                            ?: error(
                                "The credit payment result is unavailable. No payment was resent."
                            )
                } catch (e: TransferRejected) {
                    if (row.payment != null)
                        save(
                            row.copy(paymentFailure = (e.message ?: "Payment rejected").take(4096))
                        )
                    throw e
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    if (row.payment == null) throw e
                    throw IllegalStateException(
                        "The credit payment result is unknown. Use Check / continue credit purchase before making another payment. Nothing was automatically resent.",
                        e,
                    )
                }
            save(row.copy(block = block))
        }
        val invoice =
            try {
                if (row.settlement == null) {
                    require(row.rejectedSettlements.size < 32) {
                        "Too many settlement attempts. Review the recorded results."
                    }
                    backend.settle { save(row.copy(settlement = it)) }
                } else
                    backend.settlementResult(row.settlement!!)
                        ?: error(
                            "The credit mint result is unavailable. No mint or payment was resent."
                        )
            } catch (e: FinancialRejected) {
                row.settlement?.let {
                    save(
                        row.copy(
                            settlement = null,
                            rejectedSettlements = row.rejectedSettlements + it,
                        )
                    )
                }
                throw e
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                if (row.settlement == null) throw e
                throw IllegalStateException(
                    "The credit mint result is unknown. Use Check / continue credit purchase to check the saved result. No payment or mint was automatically repeated.",
                    e,
                )
            }
        save(row.copy(result = invoice))
        return row
    }
}

object CreditPurchaseCodec {
    private val mapper = ObjectMapper()

    private fun call(value: FinancialCall?) = value?.let {
        mapOf(
            "requestId" to DraftImages.hex(it.requestId),
            "arguments" to it.arguments.toString(Charsets.UTF_8),
        )
    }

    fun encode(row: CreditPurchaseRecord): ByteArray {
        val q = row.quote
        val t = q.transfer
        return mapper.writeValueAsBytes(
            mapOf(
                "version" to 1,
                "id" to row.id,
                "userId" to q.userId,
                "credits" to q.credits.toString(),
                "invoice" to mapper.readTree(CreditInvoiceCodec.encode(q.invoice)),
                "ledgerNetwork" to t.network,
                "preparedAtMillis" to t.preparedAtMillis,
                "fee" to t.fee.toString(),
                "payment" to
                    row.payment?.let {
                        mapOf(
                            "requestId" to DraftImages.hex(it.requestId),
                            "createdAtNanos" to it.createdAtNanos.toString(),
                            "memo" to it.memo.toString(),
                            "replays" to it.replayRequestIds.map(DraftImages::hex),
                        )
                    },
                "block" to row.block?.toString(),
                "settlement" to call(row.settlement),
                "rejectedSettlements" to row.rejectedSettlements.map { call(it) },
                "result" to
                    row.result?.let {
                        mapper.readTree(CreditInvoiceCodec.encode(q.invoice.copy(invoice = it)))
                    },
                "paymentFailure" to row.paymentFailure,
            )
        )
    }

    fun decode(bytes: ByteArray, owner: String, network: String): CreditPurchaseRecord {
        require(bytes.size <= 32768)
        val n = mapper.readTree(bytes)
        fun text(node: JsonNode, key: String) =
            node.required(key).also { require(it.isTextual) }.asText()
        fun long(key: String) =
            n.required(key).also { require(it.isIntegralNumber && it.canConvertToLong()) }.asLong()
        fun id(value: String): ByteArray {
            require(value.matches(Regex("[0-9a-f]{64}")))
            return value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
        require(n.required("version").isIntegralNumber && n["version"].asInt() == 1)
        val invoice = CreditInvoiceCodec.decode(mapper.writeValueAsBytes(n.required("invoice")))
        require(invoice.owner == owner && invoice.network == network)
        val transfer =
            TransferQuote(
                owner,
                text(n, "ledgerNetwork"),
                invoice.invoice.account,
                invoice.invoice.amountE8s,
                text(n, "fee").toULong(),
                long("preparedAtMillis"),
            )
        val quote =
            CreditPurchaseQuote(long("userId"), text(n, "credits").toULong(), invoice, transfer)
        fun call(value: JsonNode) =
            FinancialCall(
                owner,
                invoice.canister,
                network,
                "mint_credits_with_icp",
                id(text(value, "requestId")),
                text(value, "arguments").toByteArray(),
            )
        val payment =
            n.required("payment")
                .takeUnless { it.isNull }
                ?.let {
                    val replays = it.required("replays")
                    require(replays.isArray && replays.size() <= 32)
                    PendingTransfer(
                        transfer,
                        id(text(it, "requestId")),
                        text(it, "createdAtNanos").toULong(),
                        text(it, "memo").toULong(),
                        replays.map { value ->
                            require(value.isTextual)
                            id(value.asText())
                        },
                    )
                }
        val rejected = n.required("rejectedSettlements")
        require(rejected.isArray && rejected.size() <= 32)
        return CreditPurchaseRecord(
            quote,
            text(n, "id"),
            payment,
            n.required("block")
                .takeUnless { it.isNull }
                ?.also { require(it.isTextual) }
                ?.asText()
                ?.toULong(),
            n.required("settlement").takeUnless { it.isNull }?.let(::call),
            rejected.map(::call),
            n.required("result")
                .takeUnless { it.isNull }
                ?.let {
                    CreditInvoiceCodec.decode(mapper.writeValueAsBytes(it))
                        .also { value ->
                            require(
                                value.owner == owner &&
                                    value.network == network &&
                                    value.canister == invoice.canister
                            )
                        }
                        .invoice
                },
            n.required("paymentFailure")
                .takeUnless { it.isNull }
                ?.also { require(it.isTextual) }
                ?.asText(),
        )
    }
}

class CreditPurchaseStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-credit-purchases")

    private fun scope(owner: String, network: String) =
        DraftImages.hex(
            MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
        )

    private fun file(owner: String, network: String) =
        AtomicFile(File(root, scope(owner, network) + ".json"))

    private fun read(file: AtomicFile, owner: String, network: String): CreditPurchaseRecord? {
        val backup = File(file.baseFile.path + ".bak")
        if (!file.baseFile.exists() && !backup.exists()) return null
        require(file.baseFile.length() <= 32768 && backup.length() <= 32768)
        return CreditPurchaseCodec.decode(file.readFully(), owner, network)
    }

    fun load(owner: String, network: String) =
        synchronized(gate) { read(file(owner, network), owner, network) }

    private fun write(target: AtomicFile, row: CreditPurchaseRecord) {
        check(target.baseFile.parentFile!!.mkdirs() || target.baseFile.parentFile!!.isDirectory)
        val bytes = CreditPurchaseCodec.encode(row)
        require(bytes.size <= 32768)
        val stream = target.startWrite()
        try {
            stream.write(bytes)
            target.finishWrite(stream)
        } catch (e: Exception) {
            target.failWrite(stream)
            throw e
        }
    }

    fun create(row: CreditPurchaseRecord) =
        synchronized(gate) {
            require(row.payment == null && row.block == null && !row.finished)
            require(load(row.quote.invoice.owner, row.quote.invoice.network) == null)
            write(file(row.quote.invoice.owner, row.quote.invoice.network), row)
        }

    fun update(expected: CreditPurchaseRecord, next: CreditPurchaseRecord) =
        synchronized(gate) {
            val current =
                load(expected.quote.invoice.owner, expected.quote.invoice.network)
                    ?: error("Purchase record missing")
            require(
                CreditPurchaseCodec.encode(current)
                    .contentEquals(CreditPurchaseCodec.encode(expected))
            )
            require(
                !expected.finished &&
                    expected.id == next.id &&
                    CreditPurchaseCodec.encode(
                            expected.copy(
                                payment = null,
                                block = null,
                                settlement = null,
                                rejectedSettlements = emptyList(),
                            )
                        )
                        .contentEquals(
                            CreditPurchaseCodec.encode(
                                next.copy(
                                    payment = null,
                                    block = null,
                                    settlement = null,
                                    rejectedSettlements = emptyList(),
                                    result = null,
                                    paymentFailure = null,
                                )
                            )
                        )
            )
            require(expected.payment == null || next.payment?.matches(expected.payment) == true)
            require(expected.block == null || next.block == expected.block)
            require(
                next.rejectedSettlements.size >= expected.rejectedSettlements.size &&
                    expected.rejectedSettlements.zip(next.rejectedSettlements).all { (a, b) ->
                        a.matches(b)
                    }
            )
            require(
                expected.settlement == null ||
                    next.settlement?.matches(expected.settlement) == true ||
                    (next.settlement == null &&
                        next.rejectedSettlements.lastOrNull()?.matches(expected.settlement) == true)
            )
            write(file(next.quote.invoice.owner, next.quote.invoice.network), next)
        }

    fun discardUnpaid(expected: CreditPurchaseRecord) =
        synchronized(gate) {
            require(expected.payment == null)
            remove(expected)
        }

    fun archive(expected: CreditPurchaseRecord) =
        synchronized(gate) {
            require(expected.finished)
            val current =
                load(expected.quote.invoice.owner, expected.quote.invoice.network)
                    ?: return@synchronized
            require(
                CreditPurchaseCodec.encode(current)
                    .contentEquals(CreditPurchaseCodec.encode(expected))
            )
            write(
                AtomicFile(
                    File(
                        root,
                        "receipts/${scope(expected.quote.invoice.owner, expected.quote.invoice.network)}/${expected.id}.json",
                    )
                ),
                expected,
            )
            remove(expected)
        }

    fun latestReceipt(owner: String, network: String): CreditPurchaseRecord? =
        synchronized(gate) {
            val latest =
                File(root, "receipts/${scope(owner, network)}")
                    .listFiles()
                    ?.filter { it.extension == "json" }
                    ?.maxByOrNull { it.lastModified() } ?: return@synchronized null
            read(AtomicFile(latest), owner, network)?.also { require(it.finished) }
        }

    private fun remove(expected: CreditPurchaseRecord) {
        val current = load(expected.quote.invoice.owner, expected.quote.invoice.network) ?: return
        require(
            CreditPurchaseCodec.encode(current).contentEquals(CreditPurchaseCodec.encode(expected))
        )
        val target = file(expected.quote.invoice.owner, expected.quote.invoice.network)
        target.delete()
        check(!target.baseFile.exists() && !File(target.baseFile.path + ".bak").exists())
    }

    companion object {
        private val gate = Any()
    }
}
