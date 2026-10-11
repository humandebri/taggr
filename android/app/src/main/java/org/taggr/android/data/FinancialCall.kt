package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.security.MessageDigest
import org.ic4j.agent.android.ICClientConfiguration
import org.ic4j.agent.android.ICPAmount

fun financialNetwork(configuration: ICClientConfiguration) =
    DraftImages.hex(
        MessageDigest.getInstance("SHA-256")
            .digest(
                (DraftImages.hex(configuration.rootKey) + "/" + configuration.canisterId)
                    .toByteArray()
            )
    )

data class WithdrawQuote(
    val owner: String,
    val userId: Long,
    val recipient: String,
    val grossE8s: ULong,
    val feeE8s: ULong,
    val network: String,
    val preparedAtMillis: Long,
) {
    init {
        require(grossE8s > feeE8s) { "Rewards must exceed the withdrawal fee." }
    }

    val netE8s
        get() = grossE8s - feeE8s

    fun validate(user: JsonNode, fee: ULong, nowMillis: Long) {
        require(nowMillis >= preparedAtMillis && nowMillis - preparedAtMillis <= 120000) {
            "This confirmation expired. Review the withdrawal again."
        }
        require(
            user.path("id").asLong(-1) == userId &&
                user.path("principal").asText() == recipient &&
                unsigned(user, "treasury_e8s") == grossE8s
        ) {
            "The account or rewards changed. Review the withdrawal again."
        }
        require(fee == feeE8s && fee == ICPAmount.feeE8s) {
            "The backend withdrawal fee differs from the current ledger fee. Withdrawal is unavailable."
        }
        require(grossE8s > feeE8s) { "Rewards must exceed the withdrawal fee." }
    }

    companion object {
        fun unsigned(user: JsonNode, field: String): ULong {
            val node = user.path(field)
            require(
                node.isIntegralNumber &&
                    node.bigIntegerValue().signum() >= 0 &&
                    node.bigIntegerValue().bitLength() <= 64
            ) {
                "Invalid $field amount"
            }
            return node.asText().toULong()
        }

        fun prepare(owner: String, user: JsonNode, fee: ULong, network: String, nowMillis: Long) =
            WithdrawQuote(
                    owner,
                    user.path("id").asLong(-1),
                    user.path("principal").asText(),
                    unsigned(user, "treasury_e8s"),
                    fee,
                    network,
                    nowMillis,
                )
                .also {
                    require(it.userId >= 0)
                    try {
                        org.ic4j.types.Principal.fromString(it.recipient)
                    } catch (e: org.ic4j.types.PrincipalError) {
                        throw IllegalArgumentException("Invalid withdrawal recipient", e)
                    }
                    it.validate(user, fee, nowMillis)
                }
    }
}

data class FinancialCall(
    val owner: String,
    val canister: String,
    val network: String,
    val method: String,
    val requestId: ByteArray,
    val arguments: ByteArray,
) {
    init {
        require(
            owner.isNotBlank() &&
                canister.isNotBlank() &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                requestId.size == 32
        )
        require(
            (method == "withdraw_rewards" && arguments.contentEquals("null".toByteArray())) ||
                (method == "mint_credits_with_icp" &&
                    arguments.toString(Charsets.UTF_8) in listOf("0", "1")) ||
                (method in listOf("create_invite", "update_invite") &&
                    InviteArguments.valid(method, arguments)) ||
                (method in listOf("vote_on_proposal", "toggle_following_post") &&
                    ProposalVotes.validArguments(method, arguments)) ||
                (method == "vote_on_poll" && PollVotes.validArguments(arguments)) ||
                (method == "transfer_credits" && CreditTransferQuote.validArguments(arguments)) ||
                (method == "edit_realm" && RealmSettings.validArguments(arguments)) ||
                (method == "create_realm" && RealmCreation.validArguments(arguments)) ||
                (method == "toggle_realm_membership" && RealmMembership.validArguments(arguments))
        ) {
            "Unsupported financial operation"
        }
    }

    fun matches(other: FinancialCall) =
        owner == other.owner &&
            canister == other.canister &&
            network == other.network &&
            method == other.method &&
            requestId.contentEquals(other.requestId) &&
            arguments.contentEquals(other.arguments)
}

class FinancialRejected(message: String) : IllegalStateException(message)

object FinancialReply {
    private val mapper =
        ObjectMapper()
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS)

    fun decode(method: String, bytes: ByteArray): JsonNode {
        val reply = mapper.readTree(bytes) ?: error("Missing financial reply")
        if (method in listOf("toggle_following_post", "toggle_realm_membership")) {
            require(reply.isBoolean)
            return reply
        }
        require(reply.isObject && reply.size() == 1) { "Invalid financial reply" }
        reply["Err"]?.let {
            require(it.isTextual)
            throw FinancialRejected(it.asText())
        }
        require(reply.has("Ok")) { "Invalid financial reply" }
        val result = reply["Ok"]
        if (
            method in
                listOf(
                    "transfer_credits",
                    "withdraw_rewards",
                    "create_invite",
                    "update_invite",
                    "vote_on_proposal",
                    "vote_on_poll",
                    "edit_realm",
                    "create_realm",
                )
        )
            require(result.isNull) { "Invalid withdrawal reply" }
        else {
            require(method == "mint_credits_with_icp")
            ICPInvoice.decode(result)
        }
        return result
    }
}

data class ICPInvoice(
    val amountE8s: ULong,
    val paidE8s: ULong,
    val paid: Boolean,
    val account: String,
) {
    companion object {
        fun decode(value: JsonNode): ICPInvoice {
            val amount = WithdrawQuote.unsigned(value, "e8s")
            val paidAmount = WithdrawQuote.unsigned(value, "paid_e8s")
            val bytes = value.path("account")
            require(
                amount > 0uL &&
                    bytes.isArray &&
                    bytes.size() == 32 &&
                    bytes.all {
                        it.isIntegralNumber &&
                            it.bigIntegerValue() >= java.math.BigInteger.ZERO &&
                            it.bigIntegerValue() <= java.math.BigInteger.valueOf(255)
                    } &&
                    value.path("paid").isBoolean
            ) {
                "Invalid ICP invoice"
            }
            val hex = DraftImages.hex(bytes.map { it.asInt().toByte() }.toByteArray())
            org.ic4j.agent.android.ICPAccountIdentifier.parse(hex)
            return ICPInvoice(amount, paidAmount, value["paid"].asBoolean(), hex)
        }
    }
}

class FinancialCallStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-financial-calls")
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

    fun save(value: FinancialCall) =
        synchronized(gate) {
            require(load(value.owner, value.network) == null) {
                "Check the previous financial operation first."
            }
            check(root.mkdirs() || root.isDirectory)
            val file = file(value.owner, value.network)
            val bytes =
                mapper.writeValueAsBytes(
                    mapOf(
                        "owner" to value.owner,
                        "canister" to value.canister,
                        "network" to value.network,
                        "method" to value.method,
                        "requestId" to
                            java.util.Base64.getEncoder().encodeToString(value.requestId),
                        "arguments" to
                            java.util.Base64.getEncoder().encodeToString(value.arguments),
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

    fun load(owner: String, network: String): FinancialCall? =
        synchronized(gate) {
            val file = file(owner, network)
            val backup = File(file.baseFile.path + ".bak")
            if (!file.baseFile.exists() && !backup.exists()) return@synchronized null
            require(file.baseFile.length() <= 131072 && backup.length() <= 131072)
            val bytes = file.readFully()
            require(bytes.size <= 131072)
            val row = mapper.readTree(bytes)
            require(
                row.required("owner").asText() == owner &&
                    row.required("network").asText() == network
            )
            FinancialCall(
                owner,
                row.required("canister").asText(),
                network,
                row.required("method").asText(),
                java.util.Base64.getDecoder().decode(row.required("requestId").asText()),
                java.util.Base64.getDecoder().decode(row.required("arguments").asText()),
            )
        }

    fun clear(expected: FinancialCall) =
        synchronized(gate) {
            val current = load(expected.owner, expected.network) ?: return@synchronized
            require(current.matches(expected)) { "The financial operation changed." }
            val file = file(expected.owner, expected.network)
            file.delete()
            check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists())
        }

    companion object {
        private val gate = Any()
    }
}
