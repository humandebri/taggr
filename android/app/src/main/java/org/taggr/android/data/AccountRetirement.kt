package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.security.MessageDigest

enum class RetirementStage {
    PREPARING,
    STOP_PENDING,
    STOP_CONFIRMED,
    CLEANUP,
}

data class RetirementQuote(
    val owner: String,
    val network: String,
    val userId: Long,
    val cost: ULong,
    val preparedAtMillis: Long,
) {
    init {
        require(
            owner.isNotBlank() &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                userId >= 0 &&
                preparedAtMillis >= 0
        )
    }

    fun validate(user: JsonNode, liveCost: ULong, nowMillis: Long) {
        require(nowMillis >= preparedAtMillis && nowMillis - preparedAtMillis <= 120000) {
            "Review the deletion confirmation again; it expired."
        }
        require(user.path("id").asLong(-1) == userId && liveCost == cost) {
            "The account or deletion cost changed. Review the confirmation again."
        }
        require(user.path("deactivated").isBoolean && !user["deactivated"].asBoolean()) {
            "The account is already stopped. Nothing was toggled."
        }
        require(WithdrawQuote.unsigned(user, "cycles") >= cost) {
            "Insufficient credits to stop the account."
        }
    }
}

data class RetirementRecord(
    val quote: RetirementQuote,
    val stage: RetirementStage = RetirementStage.PREPARING,
    val requestId: ByteArray? = null,
) {
    init {
        require(requestId == null || requestId.size == 32)
        require(stage == RetirementStage.PREPARING || requestId != null)
    }
}

class RetirementRejected :
    IllegalStateException(
        "The backend rejected the stop request. Profile fields may already be cleared. Review and retry preparation."
    )

object RetirementReply {
    private val mapper = ObjectMapper()

    fun decode(bytes: ByteArray) {
        val node = mapper.readTree(bytes)
        require(node.isObject && node.size() == 1)
        if (node.has("Err")) {
            require(node["Err"].isTextual)
            throw RetirementRejected()
        }
        val ok = node.required("Ok")
        require(
            ok.isIntegralNumber &&
                ok.bigIntegerValue().signum() >= 0 &&
                ok.bigIntegerValue().bitLength() <= 64
        )
    }

    fun cleanup(node: JsonNode) {
        require(node.isObject && node.size() == 1 && node.has("Ok") && node["Ok"].isNull) {
            "Profile cleanup was not confirmed."
        }
    }

    fun profileArguments(user: JsonNode): List<Any> {
        val controllers = user.path("controllers")
        val noise = user.path("filters").path("noise")
        val mode = user.path("mode")
        require(
            controllers.isArray &&
                controllers.all { it.isTextual } &&
                noise.isObject &&
                mode.isTextual &&
                user.path("governance").isBoolean &&
                user.path("show_posts_in_realms").isBoolean
        )
        return listOf(
            "",
            "",
            controllers,
            noise,
            user["governance"].asBoolean(),
            mode.asText(),
            user["show_posts_in_realms"].asBoolean(),
        )
    }

    fun settings(user: JsonNode): Map<String, String> {
        val settings = user.path("settings")
        require(settings.isObject && settings.all { it.isTextual })
        return settings
            .fields()
            .asSequence()
            .filter { it.key !in setOf("links", "pgp") }
            .associate { it.key to it.value.asText() }
    }
}

interface RetirementBackend {
    suspend fun user(): JsonNode

    suspend fun cost(): ULong

    suspend fun clearProfile(user: JsonNode)

    suspend fun clearLinks(user: JsonNode)

    suspend fun stop(quote: RetirementQuote, persist: (ByteArray) -> Unit)

    /**
     * True = certified success, false = unavailable; certified rejection throws RetirementRejected.
     */
    suspend fun stopResult(requestId: ByteArray): Boolean
}

class RetirementWorkflow(private val backend: RetirementBackend) {
    suspend fun resume(
        initial: RetirementRecord,
        persist: (RetirementRecord, RetirementRecord) -> Unit,
        nowMillis: Long,
    ): RetirementRecord {
        var row = initial
        fun save(next: RetirementRecord) {
            persist(row, next)
            row = next
        }
        if (row.stage == RetirementStage.CLEANUP) return row
        var user = backend.user()
        require(
            user.path("id").asLong(-1) == row.quote.userId && user.path("deactivated").isBoolean
        ) {
            "The account state could not be verified."
        }
        if (row.stage != RetirementStage.PREPARING) {
            if (user["deactivated"].asBoolean()) {
                save(row.copy(stage = RetirementStage.CLEANUP))
                return row
            }
            if (row.stage == RetirementStage.STOP_PENDING) {
                try {
                    if (!backend.stopResult(row.requestId!!))
                        error("The stop result is unavailable. No stop request was resent.")
                } catch (e: RetirementRejected) {
                    save(row.copy(stage = RetirementStage.PREPARING))
                    throw e
                }
                save(row.copy(stage = RetirementStage.STOP_CONFIRMED))
            }
        } else {
            row.quote.validate(user, backend.cost(), nowMillis)
            backend.clearProfile(user)
            // Refresh before merging settings so unrelated settings are retained.
            user = backend.user()
            require(
                user.path("id").asLong(-1) == row.quote.userId &&
                    user.path("deactivated").isBoolean &&
                    !user["deactivated"].asBoolean()
            )
            backend.clearLinks(user)
            try {
                backend.stop(row.quote) {
                    save(row.copy(stage = RetirementStage.STOP_PENDING, requestId = it.clone()))
                }
            } catch (e: RetirementRejected) {
                save(row.copy(stage = RetirementStage.PREPARING))
                throw e
            }
            save(row.copy(stage = RetirementStage.STOP_CONFIRMED))
        }
        val stopped = backend.user()
        require(
            stopped.path("id").asLong(-1) == row.quote.userId &&
                stopped.path("deactivated").isBoolean &&
                stopped["deactivated"].asBoolean()
        ) {
            "The stop response was received. Check the account state later; the request will not be resent."
        }
        save(row.copy(stage = RetirementStage.CLEANUP))
        return row
    }
}

object RetirementCodec {
    private val mapper = ObjectMapper()

    fun encode(row: RetirementRecord): ByteArray =
        mapper.writeValueAsBytes(
            mapOf(
                "owner" to row.quote.owner,
                "network" to row.quote.network,
                "userId" to row.quote.userId,
                "cost" to row.quote.cost.toString(),
                "preparedAtMillis" to row.quote.preparedAtMillis,
                "stage" to row.stage.name,
                "requestId" to row.requestId?.let(DraftImages::hex),
            )
        )

    fun decode(bytes: ByteArray, owner: String, network: String): RetirementRecord {
        require(bytes.size <= 4096)
        val n = mapper.readTree(bytes)
        fun text(key: String) = n.required(key).also { require(it.isTextual) }.asText()
        fun long(key: String) =
            n.required(key).also { require(it.isIntegralNumber && it.canConvertToLong()) }.asLong()
        require(text("owner") == owner && text("network") == network)
        val request =
            n.required("requestId")
                .takeUnless { it.isNull }
                ?.also { require(it.isTextual) }
                ?.asText()
                ?.let {
                    require(it.matches(Regex("[0-9a-f]{64}")))
                    it.chunked(2).map { byte -> byte.toInt(16).toByte() }.toByteArray()
                }
        return RetirementRecord(
            RetirementQuote(
                owner,
                network,
                long("userId"),
                text("cost").toULong(),
                long("preparedAtMillis"),
            ),
            RetirementStage.valueOf(text("stage")),
            request,
        )
    }
}

class RetirementStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-retirement")

    private fun file(owner: String, network: String) =
        AtomicFile(
            File(
                root,
                DraftImages.hex(
                    MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
                ) + ".json",
            )
        )

    fun load(owner: String, network: String): RetirementRecord? =
        synchronized(gate) {
            val target = file(owner, network)
            val backup = File(target.baseFile.path + ".bak")
            if (!target.baseFile.exists() && !backup.exists()) return@synchronized null
            require(target.baseFile.length() <= 4096 && backup.length() <= 4096)
            RetirementCodec.decode(target.readFully(), owner, network)
        }

    private fun write(row: RetirementRecord) {
        check(root.mkdirs() || root.isDirectory)
        val target = file(row.quote.owner, row.quote.network)
        val stream = target.startWrite()
        try {
            stream.write(RetirementCodec.encode(row))
            target.finishWrite(stream)
        } catch (e: Exception) {
            target.failWrite(stream)
            throw e
        }
    }

    fun create(row: RetirementRecord) =
        synchronized(gate) {
            require(
                row.stage == RetirementStage.PREPARING &&
                    row.requestId == null &&
                    load(row.quote.owner, row.quote.network) == null
            )
            write(row)
        }

    fun update(expected: RetirementRecord, next: RetirementRecord) =
        synchronized(gate) {
            val current =
                load(expected.quote.owner, expected.quote.network)
                    ?: error("Deletion record missing")
            require(
                RetirementCodec.encode(current).contentEquals(RetirementCodec.encode(expected)) &&
                    expected.quote == next.quote
            )
            require(expected.stage != RetirementStage.CLEANUP)
            require(
                next.stage in
                    when (expected.stage) {
                        RetirementStage.PREPARING -> setOf(RetirementStage.STOP_PENDING)
                        RetirementStage.STOP_PENDING ->
                            setOf(
                                RetirementStage.PREPARING,
                                RetirementStage.STOP_CONFIRMED,
                                RetirementStage.CLEANUP,
                            )
                        RetirementStage.STOP_CONFIRMED -> setOf(RetirementStage.CLEANUP)
                        RetirementStage.CLEANUP -> emptySet()
                    }
            )
            // A pending request ID is only replaced after its rejection was certified.
            require(
                expected.stage == RetirementStage.PREPARING ||
                    (next.requestId != null && expected.requestId!!.contentEquals(next.requestId))
            )
            write(next)
        }

    fun reapprove(expected: RetirementRecord, quote: RetirementQuote): RetirementRecord =
        synchronized(gate) {
            require(
                expected.stage == RetirementStage.PREPARING &&
                    expected.quote.owner == quote.owner &&
                    expected.quote.network == quote.network &&
                    expected.quote.userId == quote.userId
            )
            val current = load(quote.owner, quote.network) ?: error("Deletion record missing")
            require(RetirementCodec.encode(current).contentEquals(RetirementCodec.encode(expected)))
            RetirementRecord(quote, requestId = expected.requestId).also(::write)
        }

    companion object {
        private val gate = Any()
    }
}
