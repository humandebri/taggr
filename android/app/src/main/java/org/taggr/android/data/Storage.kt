package org.taggr.android.data

import java.math.BigInteger
import org.ic4j.agent.android.*
import org.ic4j.types.Principal

data class StorageStatus(
    val bucket: String,
    val status: String,
    val controllers: List<String>,
    val moduleHash: String?,
    val memoryBytes: BigInteger,
    val cycles: BigInteger,
    val dailyBurn: BigInteger,
    val expectedHash: String,
) {
    val compatible
        get() = moduleHash == expectedHash

    val daysRemaining
        get() = if (dailyBurn.signum() == 0) null else cycles / dailyBurn

    fun requireUsable(owner: String) {
        require(status == "running" && compatible) {
            "This canister must run the current TAGGR storage module."
        }
        require(owner in controllers) {
            "The signed-in principal must control this storage canister."
        }
    }
}

data class StorageQuote(
    val owner: String,
    val userId: Long,
    val snapshot: StorageStatus,
    val preparedAtMillis: Long,
) {
    fun validate(owner: String, userId: Long, current: StorageStatus, now: Long) {
        require(owner == this.owner && userId == this.userId && current.bucket == snapshot.bucket) {
            "The account or storage changed. Review it again."
        }
        require(now >= preparedAtMillis && now - preparedAtMillis <= 120000) {
            "This confirmation expired. Review storage again."
        }
        current.requireUsable(owner)
        require(
            current.moduleHash == snapshot.moduleHash && current.controllers == snapshot.controllers
        ) {
            "Storage controllers or code changed. Review it again."
        }
    }
}

object StorageWire {
    fun canonicalBucket(text: String): String =
        try {
            Principal.fromString(text.trim()).toString().also {
                require(it != "aaaaa-aa" && it != "2vxsx-fae") { "Enter a storage canister ID." }
            }
        } catch (e: org.ic4j.types.PrincipalError) {
            throw IllegalArgumentException("Invalid storage canister ID", e)
        }

    fun arguments(bucket: String) =
        CandidArguments(
                LedgerWire.record(
                    "canister_id" to Candid.principal.encode(Principal.fromString(bucket))
                )
            )
            .encode()

    fun reply(bucket: String, bytes: ByteArray, expectedHash: String): StorageStatus {
        require(expectedHash.matches(Regex("[0-9a-f]{64}"))) {
            "Invalid expected storage module hash"
        }
        val value = Candid.decode(bytes).values.single().value
        val status =
            LedgerWire.field(value, "status") as? CandidVariant ?: error("Invalid storage status")
        val name =
            listOf("running", "stopping", "stopped").firstOrNull {
                Candid.fieldID(it) == status.tag
            } ?: error("Unknown storage status")
        require(status.value == null)
        val controllers =
            LedgerWire.field(LedgerWire.field(value, "settings"), "controllers") as? List<*>
                ?: error("Invalid storage controllers")
        val principals = controllers.map {
            (it as? Principal ?: error("Invalid controller")).toString()
        }
        val module =
            when (val option = LedgerWire.field(value, "module_hash")) {
                CandidOption.None -> null
                is CandidOption.Some ->
                    (option.value as? ByteArray ?: error("Invalid module hash"))
                        .also { require(it.size == 32) }
                        .let(DraftImages::hex)
                else -> error("Invalid module hash option")
            }
        fun nat(field: String) =
            (LedgerWire.field(value, field) as? BigInteger ?: error("Invalid storage metric"))
                .also { require(it.signum() >= 0) }
        return StorageStatus(
            bucket,
            name,
            principals,
            module,
            nat("memory_size"),
            nat("cycles"),
            nat("idle_cycles_burned_per_day"),
            expectedHash,
        )
    }
}
