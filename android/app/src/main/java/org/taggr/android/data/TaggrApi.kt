package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.ic4j.agent.AuthSession
import org.ic4j.agent.android.ICClient
import org.ic4j.agent.android.ICClientConfiguration

enum class FeedMode(val title: String, val method: String) {
    HOT("Hot", "hot_posts"),
    LATEST("Latest", "last_posts"),
    PERSONAL("Personal", "personal_feed"),
}

data class SearchMatch(
    val kind: String,
    val id: Long,
    val target: String,
    val title: String,
    val snippet: String,
)

interface PostRepository : AutoCloseable {
    override fun close() {}

    suspend fun feed(mode: FeedMode, page: Int, offset: Long): List<TaggrPost>

    suspend fun posts(ids: List<Long>): List<TaggrPost>

    suspend fun thread(id: Long): List<TaggrPost> = posts(listOf(id))

    suspend fun feedPage(mode: FeedMode, page: Int, offset: Long): PostPage =
        PostPage.visible(feed(mode, page, offset)) { true }
}

class TaggrApi(val configuration: ICClientConfiguration = TaggrRuntime.configuration()) :
    PostRepository {
    var safety: SafetyStore? = null
    var snsRestricted: Boolean = false
    private var identitySession: AuthSession? = null
    val session: AuthSession?
        get() = identitySession?.also {
            if (sessionRemainingMillis(it.expiration(), System.currentTimeMillis()) == 0L)
                throw SessionExpiredException()
        }

    fun setSession(value: AuthSession?) {
        identitySession = value
    }

    private val mapper = ObjectMapper()
    private val clientDelegate = lazy {
        ICClient(configuration)
    }
    private val client by clientDelegate

    override fun close() {
        if (clientDelegate.isInitialized()) client.close()
    }

    override suspend fun feed(mode: FeedMode, page: Int, offset: Long): List<TaggrPost> =
        feedPage(mode, page, offset).posts

    override suspend fun feedPage(mode: FeedMode, page: Int, offset: Long): PostPage =
        queryPostPage(
            mode.method,
            if (mode == FeedMode.PERSONAL) listOf(TaggrRuntime.domain, page, offset)
            else listOf(TaggrRuntime.domain, "", page, offset, true),
            signed = mode == FeedMode.PERSONAL || session != null,
        )

    override suspend fun thread(id: Long): List<TaggrPost> =
        queryPosts("thread", listOf(id), signed = session != null)

    override suspend fun posts(ids: List<Long>): List<TaggrPost> =
        if (ids.isEmpty()) emptyList()
        else queryPosts("posts", listOf(ids), signed = session != null)

    private suspend fun queryPosts(
        method: String,
        arguments: Any,
        signed: Boolean = false,
    ): List<TaggrPost> = agentOperation {
        withTimeout(45_000) {
            val bytes = rawQuery(method, arguments, signed)
            TaggrPost.decodeEnvelopes(bytes).filter { safety?.allowed(it) != false }
        }
    }

    private suspend fun queryPostPage(
        method: String,
        arguments: Any,
        signed: Boolean = session != null,
    ): PostPage = agentOperation {
        withTimeout(45_000) {
            val rows = TaggrPost.decodeEnvelopes(rawQuery(method, arguments, signed))
            PostPage.visible(rows) { safety?.allowed(it) != false }
        }
    }

    suspend fun proposalPage(filter: String, page: Int): PostPage {
        require(filter in TaggrProposal.filters && page >= 0)
        return queryPostPage("proposals", listOf(page, filter))
    }

    suspend fun proposal(id: Long): TaggrProposal {
        require(id in 0..0xffff_ffffL)
        return TaggrProposal.decode(jsonQuery("proposal", listOf(id)), id)
    }

    suspend fun realmPostPage(name: String, page: Int, offset: Long): PostPage =
        queryPostPage("last_posts", listOf(TaggrRuntime.domain, name, page, offset, true))

    suspend fun userPostPage(id: Long, page: Int, offset: Long): PostPage =
        queryPostPage("user_posts", listOf(TaggrRuntime.domain, id.toString(), page, offset))

    suspend fun tagPostPage(tag: String, page: Int, offset: Long): PostPage =
        tagPostPage(listOf(tag), page, offset)

    suspend fun tagPostPage(tags: List<String>, page: Int, offset: Long): PostPage =
        queryPostPage("posts_by_tags", listOf(TaggrRuntime.domain, "", tags, page, offset))

    suspend fun realmPosts(name: String): List<TaggrPost> = realmPostPage(name, 0, 0).posts

    suspend fun userPosts(id: Long): List<TaggrPost> = userPostPage(id, 0, 0).posts

    suspend fun tagPosts(tag: String, page: Int, offset: Long): List<TaggrPost> =
        tagPostPage(tag, page, offset).posts

    suspend fun search(term: String): List<SearchMatch> {
        val rows = jsonQuery("search", listOf(TaggrRuntime.domain, term)).toList()
        val visiblePosts =
            posts(
                    rows
                        .filter { it.path("result").asText() == "post" }
                        .map { it.path("id").asLong() }
                )
                .filter { it.restriction == null }
                .associateBy { it.id }
        val realmNames =
            rows
                .filter { it.path("result").asText() == "realm" }
                .map { it.path("generic_id").asText() }
                .distinct()
        val visibleRealms =
            realmNames
                .filter { name ->
                    val realm = jsonQuery("realms", listOf(listOf(name))).firstOrNull()
                    realm != null && !realm.path("adult_content").asBoolean()
                }
                .toSet()
        return rows.mapNotNull { row ->
            val kind = row.path("result").asText()
            val id = row.path("id").asLong()
            val generic = row.path("generic_id").asText()
            val snippet = row.path("relevant").asText()
            when (kind) {
                "post" ->
                    visiblePosts[id]?.let {
                        SearchMatch(kind, id, id.toString(), it.author, it.timelineBody)
                    }
                "realm" ->
                    if (generic in visibleRealms)
                        SearchMatch(kind, id, generic, "/$generic", snippet)
                    else null
                "tag" ->
                    if (!snippet.equals("nsfw", true))
                        SearchMatch(kind, id, snippet, "#$snippet", "")
                    else null
                "user" ->
                    if (safety?.allowedUser(id) != false) {
                        val user =
                            jsonQuery("user", listOf(TaggrRuntime.domain, listOf(id.toString())))
                        if (user.isNull) null
                        else
                            SearchMatch(
                                kind,
                                id,
                                id.toString(),
                                "@${user.path("name").asText()}",
                                snippet,
                            )
                    } else null
                else -> null
            }
        }
    }

    suspend fun rawQuery(
        method: String,
        arguments: Any = emptyList<Any>(),
        signed: Boolean = false,
    ): ByteArray = agentOperation {
        if (signed) {
            val identity = session ?: error("Sign in to use this action.")
            ICClient(configuration, identity).use {
                it.queryRaw(method, jsonArguments(arguments))
            }
        } else client.queryRaw(method, jsonArguments(arguments))
    }

    suspend fun jsonQuery(
        method: String,
        arguments: Any = emptyList<Any>(),
        signed: Boolean = false,
    ): JsonNode = mapper.readTree(rawQuery(method, arguments, signed))

    suspend fun update(method: String, arguments: Any = emptyList<Any>()): JsonNode =
        agentOperation {
            require(!snsRestricted) {
                "SNS actions are unavailable while this account is stopped or deletion is pending."
            }
            val identity = session ?: error("Sign in to use this action.")
            ICClient(configuration, identity).use {
                val bytes = it.callRaw(method, jsonArguments(arguments))
                val result =
                    if (bytes.isEmpty()) mapper.nodeFactory.nullNode() else mapper.readTree(bytes)
                if (result.has("Err")) error(result["Err"].asText("Action rejected."))
                result
            }
        }

    suspend fun financialUpdate(
        method: String,
        arguments: ByteArray,
        persist: (FinancialCall) -> Unit,
    ): JsonNode = agentOperation {
        require(!snsRestricted || method == "withdraw_rewards") {
            "New financial changes are unavailable while account deletion is pending."
        }
        val identity = session ?: error("Sign in to use the wallet.")
        ICClient(configuration, identity).use {
            val request = it.signUpdate(method, arguments)
            persist(
                FinancialCall(
                    identity.principal().toString(),
                    configuration.canisterId,
                    financialNetwork(configuration),
                    method,
                    request.requestId().get(),
                    arguments,
                )
            )
            FinancialReply.decode(method, it.completeRaw(it.submitSigned(request)))
        }
    }

    suspend fun recoverFinancial(call: FinancialCall): JsonNode? = agentOperation {
        val identity = session ?: error("Sign in to check the financial operation.")
        require(
            identity.principal().toString() == call.owner &&
                configuration.canisterId == call.canister &&
                financialNetwork(configuration) == call.network
        )
        ICClient(configuration, identity).use {
            when (val status = it.requestStatus(call.requestId)) {
                is org.ic4j.agent.android.ICRequestStatus.Replied ->
                    FinancialReply.decode(call.method, status.reply)
                is org.ic4j.agent.android.ICRequestStatus.Rejected ->
                    throw FinancialRejected(status.message)
                else -> null
            }
        }
    }

    fun retirementBackend(): RetirementBackend =
        object : RetirementBackend {
            override suspend fun user() = currentUser() ?: error("Account unavailable.")

            override suspend fun cost() =
                WithdrawQuote.unsigned(jsonQuery("config"), "account_activation_cost")

            private suspend fun cleanup(method: String, arguments: Any) = agentOperation {
                val identity = session ?: error("Sign in to continue deletion.")
                ICClient(configuration, identity).use {
                    RetirementReply.cleanup(
                        mapper.readTree(it.callRaw(method, jsonArguments(arguments)))
                    )
                }
            }

            override suspend fun clearProfile(user: JsonNode) =
                cleanup("update_user", RetirementReply.profileArguments(user))

            override suspend fun clearLinks(user: JsonNode) =
                cleanup("update_user_settings", listOf(RetirementReply.settings(user)))

            override suspend fun stop(quote: RetirementQuote, persist: (ByteArray) -> Unit) {
                require(
                    session?.principal()?.toString() == quote.owner &&
                        financialNetwork(configuration) == quote.network
                )
                quote.validate(user(), cost(), System.currentTimeMillis())
                val random = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
                val arguments = mapper.writeValueAsBytes(DraftImages.hex(random))
                try {
                    val identity = session ?: error("Sign in to continue deletion.")
                    ICClient(configuration, identity).use {
                        val request = it.signUpdate("crypt", arguments)
                        persist(request.requestId().get())
                        RetirementReply.decode(it.completeRaw(it.submitSigned(request)))
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: RetirementRejected) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    // Never propagate a transport/backend message that might echo the discarded
                    // key.
                    throw IllegalStateException(
                        "The stop result could not be confirmed. Check status; the request will not be resent."
                    )
                } finally {
                    random.fill(0)
                    arguments.fill(0)
                }
            }

            override suspend fun stopResult(requestId: ByteArray): Boolean =
                try {
                    agentOperation {
                        val identity = session ?: error("Sign in to check deletion.")
                        ICClient(configuration, identity).use {
                            when (val status = it.requestStatus(requestId)) {
                                is org.ic4j.agent.android.ICRequestStatus.Replied -> {
                                    RetirementReply.decode(status.reply)
                                    true
                                }
                                is org.ic4j.agent.android.ICRequestStatus.Rejected ->
                                    throw RetirementRejected()
                                else -> false
                            }
                        }
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: RetirementRejected) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    throw IllegalStateException(
                        "The stop result could not be verified. Check status later; nothing was resent."
                    )
                }
        }

    fun creditPurchaseBackend(): CreditPurchaseBackend =
        object : CreditPurchaseBackend {
            override suspend fun validate(row: CreditPurchaseRecord) {
                require(
                    session?.principal()?.toString() == row.quote.transfer.owner &&
                        financialNetwork(configuration) == row.quote.invoice.network &&
                        transferNetwork(configuration) == row.quote.transfer.network &&
                        configuration.canisterId == row.quote.invoice.canister
                ) {
                    "The credit purchase account or network changed."
                }
                require(currentUser()?.path("id")?.asLong(-1) == row.quote.userId) {
                    "The TAGGR account changed. Keep this purchase record."
                }
                if (row.payment == null) {
                    row.quote.transfer.validate(
                        wallet(row.quote.transfer.owner),
                        System.currentTimeMillis(),
                    )
                    require(
                        WithdrawQuote.unsigned(jsonQuery("config"), "credits_per_xdr") ==
                            row.quote.credits
                    ) {
                        "The credit amount changed. Review the purchase again."
                    }
                }
            }

            override suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit) =
                transfer(quote, persist = persist)

            override suspend fun paymentResult(payment: PendingTransfer) = recoverTransfer(payment)

            override suspend fun settle(persist: (FinancialCall) -> Unit) =
                ICPInvoice.decode(
                    financialUpdate("mint_credits_with_icp", "1".toByteArray(), persist)
                )

            override suspend fun settlementResult(call: FinancialCall) =
                recoverFinancial(call)?.let(ICPInvoice::decode)
        }

    suspend fun transfer(
        quote: TransferQuote,
        protocolMemo: ULong? = null,
        persist: (PendingTransfer) -> Unit,
    ): ULong = agentOperation {
        val identity = session ?: error("Sign in to send ICP.")
        require(
            identity.principal().toString() == quote.owner &&
                transferNetwork(configuration) == quote.network
        ) {
            "The wallet identity or network changed."
        }
        quote.validate(wallet(quote.owner), System.currentTimeMillis())
        val instant = java.time.Instant.now()
        val timestamp =
            (java.math.BigInteger.valueOf(instant.epochSecond) *
                    java.math.BigInteger.valueOf(1_000_000_000) +
                    java.math.BigInteger.valueOf(instant.nano.toLong()))
                .toString()
                .toULong()
        val memo = protocolMemo ?: java.security.SecureRandom().nextLong().toULong()
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate(
                    "transfer",
                    LedgerWire.transferArguments(
                        org.ic4j.agent.android.ICPAccountIdentifier.parse(quote.recipient),
                        quote.amount,
                        quote.fee,
                        memo,
                        timestamp,
                    ),
                    canisterId = LedgerWire.CANISTER,
                )
            persist(PendingTransfer(quote, request.requestId().get(), timestamp, memo))
            confirmedTransfer(LedgerWire.transferReply(it.completeRaw(it.submitSigned(request))))
        }
    }

    suspend fun replayTransfer(pending: PendingTransfer, persist: (ByteArray) -> Unit): ULong =
        agentOperation {
            val identity = session ?: error("Sign in to retry the pending transfer.")
            require(
                identity.principal().toString() == pending.quote.owner &&
                    transferNetwork(configuration) == pending.quote.network
            )
            val instant = java.time.Instant.now()
            val now =
                (java.math.BigInteger.valueOf(instant.epochSecond) *
                        java.math.BigInteger.valueOf(1_000_000_000) +
                        java.math.BigInteger.valueOf(instant.nano.toLong()))
                    .toString()
                    .toULong()
            pending.validateReplay(now)
            val snapshot = wallet(pending.quote.owner)
            require(snapshot.feeE8s == pending.quote.fee) {
                "The fee changed. The original transfer cannot be altered for replay. Check its recorded results."
            }
            ICClient(configuration, identity).use {
                // The original fee, timestamp and memo are never replaced, even after fee/balance
                // changes.
                val request =
                    it.signUpdate("transfer", pending.arguments(), canisterId = LedgerWire.CANISTER)
                persist(request.requestId().get())
                confirmedTransfer(
                    LedgerWire.transferReply(it.completeRaw(it.submitSigned(request)))
                )
            }
        }

    suspend fun recoverTransfer(pending: PendingTransfer): ULong? = agentOperation {
        val identity = session ?: error("Sign in to check the transfer result.")
        require(
            identity.principal().toString() == pending.quote.owner &&
                transferNetwork(configuration) == pending.quote.network
        )
        try {
            kotlinx.coroutines.withTimeout(45_000) {
                ICClient(configuration, identity).use { client ->
                    val results = mutableListOf<TransferProbe>()
                    for (id in pending.allRequestIds.asReversed()) {
                        val probe =
                            when (
                                val status =
                                    client.requestStatus(
                                        id,
                                        effectiveCanisterId = LedgerWire.CANISTER,
                                    )
                            ) {
                                is org.ic4j.agent.android.ICRequestStatus.Replied ->
                                    try {
                                        TransferProbe.Paid(
                                            confirmedTransfer(
                                                LedgerWire.transferReply(status.reply)
                                            )
                                        )
                                    } catch (rejected: TransferRejected) {
                                        TransferProbe.Rejected(
                                            rejected.message ?: "Transfer rejected"
                                        )
                                    }
                                is org.ic4j.agent.android.ICRequestStatus.Rejected ->
                                    TransferProbe.Rejected(status.message)
                                else -> TransferProbe.Unknown
                            }
                        if (probe is TransferProbe.Paid) return@withTimeout probe.block
                        results += probe
                    }
                    resolveTransferProbes(results)
                }
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw IllegalStateException("Result lookup timed out. The pending record is kept.", e)
        }
    }

    suspend fun wallet(owner: String): WalletSnapshot = agentOperation {
        ICClient(configuration).use { ledger ->
            val account = org.ic4j.agent.android.ICPAccountIdentifier.defaultAccount(owner)
            val balance =
                LedgerWire.balanceReply(
                    ledger.queryRaw(
                        "account_balance",
                        LedgerWire.balanceArguments(account),
                        canisterId = LedgerWire.CANISTER,
                    )
                )
            val fee =
                LedgerWire.feeReply(
                    ledger.queryRaw(
                        "icrc1_fee",
                        org.ic4j.agent.android.CandidArguments().encode(),
                        canisterId = LedgerWire.CANISTER,
                    )
                )
            val decimals = jsonQuery("config").path("token_decimals")
            require(decimals.isIntegralNumber && decimals.asInt() in 0..255) {
                "Token decimals are unavailable."
            }
            WalletSnapshot(owner, balance, fee, decimals.asInt())
        }
    }

    suspend fun prepareStorageTopUp(amount: String): StorageTopUpQuote = agentOperation {
        val owner = session?.principal()?.toString() ?: error("Sign in to top up storage.")
        val user = currentUser() ?: error("Create your TAGGR account first.")
        val bucket =
            user["bucket"]?.takeUnless { it.isNull }?.asText()?.takeIf { it.isNotBlank() }
                ?: error("Create storage before topping up.")
        storageStatus(bucket).also {
            require(owner in it.controllers) {
                "The signed-in principal must control this storage."
            }
        }
        val transfer =
            TransferQuote.prepare(
                DraftImages.hex(StorageProvisioning.topUpAccount(bucket)),
                amount,
                wallet(owner),
                transferNetwork(configuration),
                System.currentTimeMillis(),
            )
        StorageTopUpQuote(
            user.path("id").asLong(-1),
            configuration.canisterId,
            financialNetwork(configuration),
            bucket,
            transfer,
        )
    }

    fun storageTopUpBackend(): StorageTopUpBackend =
        object : StorageTopUpBackend {
            override suspend fun validate(row: StorageTopUpRecord) {
                require(
                    session?.principal()?.toString() == row.quote.transfer.owner &&
                        row.quote.taggr == configuration.canisterId &&
                        row.quote.network == financialNetwork(configuration) &&
                        row.quote.transfer.network == transferNetwork(configuration)
                ) {
                    "The storage identity or network changed."
                }
                val user = currentUser() ?: error("Account unavailable")
                require(
                    user.path("id").asLong(-1) == row.quote.userId &&
                        user["bucket"]?.takeUnless { it.isNull }?.asText() == row.quote.bucket
                ) {
                    "The account or registered storage changed. Keep the recorded payment."
                }
            }

            override suspend fun pay(quote: TransferQuote, persist: (PendingTransfer) -> Unit) =
                transfer(quote, StorageProvisioning.TOP_UP_MEMO, persist)

            override suspend fun paymentResult(payment: PendingTransfer) = recoverTransfer(payment)

            override suspend fun notify(
                block: ULong,
                bucket: String,
                persist: (ByteArray) -> Unit,
            ) = notifyStorageTopUp(block, bucket) { persist(it.requestId().get()) }
        }

    suspend fun prepareStorageCreation(): StorageCreationQuote = agentOperation {
        val owner = session?.principal()?.toString() ?: error("Sign in to create storage.")
        val user = currentUser() ?: error("Create your TAGGR account first.")
        require(user["bucket"]?.takeUnless { it.isNull }?.asText().isNullOrEmpty()) {
            "Storage is already registered."
        }
        val price = WithdrawQuote.unsigned(jsonQuery("stats"), "e8s_for_one_xdr")
        val wallet = wallet(owner)
        val transfer =
            TransferQuote(
                owner,
                transferNetwork(configuration),
                DraftImages.hex(StorageProvisioning.creationAccount(owner)),
                price,
                wallet.feeE8s,
                System.currentTimeMillis(),
            )
        transfer.validate(wallet, System.currentTimeMillis())
        val hash = jsonQuery("bucket_wasm_hash").also { require(it.isTextual) }.asText()
        StorageCreationQuote(
            user.path("id").asLong(),
            configuration.canisterId,
            financialNetwork(configuration),
            transfer,
            hash,
        )
    }

    suspend fun fundStorageCreation(
        record: StorageCreationRecord,
        persist: (StorageCreationRecord) -> Unit,
    ): ULong = agentOperation {
        require(
            record.payment == null &&
                record.quote.network == financialNetwork(configuration) &&
                record.quote.taggr == configuration.canisterId
        )
        val user = currentUser() ?: error("Account unavailable")
        require(
            user.path("id").asLong() == record.quote.userId &&
                user["bucket"]?.takeUnless { it.isNull }?.asText().isNullOrEmpty()
        ) {
            "The account or storage changed."
        }
        require(
            WithdrawQuote.unsigned(jsonQuery("stats"), "e8s_for_one_xdr") ==
                record.quote.transfer.amount
        ) {
            "The creation price changed. Review it again."
        }
        require(jsonQuery("bucket_wasm_hash").asText() == record.quote.moduleHash) {
            "The storage module changed. Review it again."
        }
        transfer(record.quote.transfer, StorageProvisioning.CREATE_MEMO) { pending ->
            persist(record.withPayment(pending))
        }
    }

    fun storageCreationBackend(): StorageCreationBackend =
        object : StorageCreationBackend {
            override suspend fun validateAccount(row: StorageCreationRecord) {
                require(
                    session?.principal()?.toString() == row.quote.transfer.owner &&
                        row.quote.taggr == configuration.canisterId &&
                        row.quote.network == financialNetwork(configuration) &&
                        row.quote.transfer.network == transferNetwork(configuration)
                ) {
                    "The storage identity or network changed."
                }
                val user = currentUser() ?: error("Account unavailable")
                val bucket = user["bucket"]?.takeUnless { it.isNull }?.asText()
                require(
                    user.path("id").asLong(-1) == row.quote.userId &&
                        (bucket.isNullOrEmpty() || bucket == row.bucket)
                ) {
                    "The account or registered storage changed."
                }
            }

            override suspend fun fund(
                row: StorageCreationRecord,
                persist: (StorageCreationRecord) -> Unit,
            ) = fundStorageCreation(row, persist)

            override suspend fun paymentResult(payment: PendingTransfer) = recoverTransfer(payment)

            override suspend fun create(row: StorageCreationRecord, persist: (ByteArray) -> Unit) =
                notifyStorageCreation(row.block!!, row.quote.transfer.owner) {
                    persist(it.requestId().get())
                }

            override suspend fun status(bucket: String) = storageStatus(bucket)

            override suspend fun installCanRetry(row: StorageCreationRecord): Boolean =
                agentOperation {
                    val identity = session ?: error("Sign in to check installation.")
                    ICClient(configuration, identity).use { signed ->
                        row.installRequests.all {
                            signed.requestStatus(it, effectiveCanisterId = row.bucket!!) is
                                org.ic4j.agent.android.ICRequestStatus.Rejected
                        }
                    }
                }

            override suspend fun module() = verifiedStorageWasm()

            override suspend fun install(
                bucket: String,
                wasm: VerifiedStorageWasm,
                persist: (ByteArray) -> Unit,
            ) = installNewStorage(bucket, wasm) { persist(it.requestId().get()) }

            override suspend fun register(
                row: StorageCreationRecord,
                persist: (ByteArray) -> Unit,
            ) = agentOperation {
                validateAccount(row)
                storageStatus(row.bucket!!).also {
                    require(it.expectedHash == row.quote.moduleHash)
                    it.requireUsable(row.quote.transfer.owner)
                }
                val current = currentUser() ?: error("Account unavailable")
                if (current["bucket"]?.asText() != row.bucket) {
                    val identity = session ?: error("Sign in to register storage.")
                    ICClient(configuration, identity).use {
                        val request = it.signUpdate("set_bucket", jsonArguments(listOf(row.bucket)))
                        persist(request.requestId().get())
                        val bytes = it.completeRaw(it.submitSigned(request))
                        if (bytes.isNotEmpty()) {
                            val result = mapper.readTree(bytes)
                            require(!result.has("Err")) {
                                result["Err"].asText("Storage registration rejected")
                            }
                        }
                    }
                }
                val verified = currentUser() ?: error("Account unavailable")
                require(
                    verified.path("id").asLong(-1) == row.quote.userId &&
                        verified["bucket"]?.asText() == row.bucket
                ) {
                    "Storage registration is not confirmed. Keep this record and check again."
                }
            }
        }

    suspend fun verifiedStorageWasm(): VerifiedStorageWasm = agentOperation {
        val hash = jsonQuery("bucket_wasm_hash").also { require(it.isTextual) }.asText()
        val bytes =
            org.ic4j.agent.android.Candid.decode(
                    client.queryRaw(
                        "bucket_wasm",
                        org.ic4j.agent.android.CandidArguments().encode(),
                    )
                )
                .values
                .single()
                .value as? ByteArray ?: error("Invalid storage module reply")
        VerifiedStorageWasm.verify(bytes, hash)
    }

    /**
     * Persist the signed request before dispatch; callers must retain the original ledger block.
     */
    suspend fun notifyStorageCreation(
        block: ULong,
        owner: String,
        persist: (org.ic4j.agent.SignedRequest) -> Unit,
    ): String = agentOperation {
        val identity = session ?: error("Sign in to create storage.")
        require(identity.principal().toString() == owner)
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate(
                    "notify_create_canister",
                    StorageProvisioning.createArguments(block, owner),
                    canisterId = StorageProvisioning.CMC,
                )
            persist(request)
            StorageProvisioning.creationReply(it.completeRaw(it.submitSigned(request)))
        }
    }

    suspend fun notifyStorageTopUp(
        block: ULong,
        bucket: String,
        persist: (org.ic4j.agent.SignedRequest) -> Unit,
    ): java.math.BigInteger = agentOperation {
        val identity = session ?: error("Sign in to top up storage.")
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate(
                    "notify_top_up",
                    StorageProvisioning.topUpArguments(block, bucket),
                    canisterId = StorageProvisioning.CMC,
                )
            persist(request)
            StorageProvisioning.topUpReply(it.completeRaw(it.submitSigned(request)))
        }
    }

    suspend fun installNewStorage(
        bucket: String,
        wasm: VerifiedStorageWasm,
        persist: (org.ic4j.agent.SignedRequest) -> Unit,
    ) = agentOperation {
        val identity = session ?: error("Sign in to install storage.")
        val owner = identity.principal().toString()
        val status = storageStatus(bucket)
        require(
            status.moduleHash == null &&
                owner in status.controllers &&
                wasm.hash == status.expectedHash
        ) {
            "Storage code or controllers changed. Nothing was installed."
        }
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate(
                    "install_code",
                    StorageProvisioning.installArguments(bucket, owner, wasm),
                    canisterId = "aaaaa-aa",
                    effectiveCanisterId = bucket,
                )
            persist(request)
            val reply = it.completeRaw(it.submitSigned(request))
            require(org.ic4j.agent.android.Candid.decode(reply).values.isEmpty()) {
                "Invalid install reply"
            }
        }
    }

    suspend fun manageStorage(quote: StorageManagementQuote): StorageStatus = agentOperation {
        val identity = session ?: error("Sign in to manage storage.")
        require(identity.principal().toString() == quote.owner)
        val bucket = quote.snapshot.bucket
        val wasm =
            if (quote.action == StorageManagementAction.UPGRADE) verifiedStorageWasm() else null
        require(wasm == null || wasm.hash == quote.snapshot.expectedHash) {
            "The published storage code changed. Review it again."
        }
        suspend fun call(method: String, args: ByteArray, management: Boolean) = agentOperation {
            require(session === identity) { "The account changed. Review storage again." }
            ICClient(configuration, identity).use {
                val bytes =
                    it.callRaw(
                        method,
                        args,
                        canisterId = if (management) "aaaaa-aa" else bucket,
                        effectiveCanisterId = bucket,
                    )
                StorageManagementWire.confirmReply(bytes, management)
            }
        }
        StorageManagementWorkflow.run(
            quote,
            object : StorageManagementPort {
                override suspend fun status(): StorageStatus {
                    require(session === identity) { "The account changed. Review storage again." }
                    return storageStatus(bucket)
                }

                override suspend fun upgrade() =
                    call(
                        "install_code",
                        StorageManagementWire.upgradeArguments(bucket, quote.owner, wasm!!),
                        true,
                    )

                override suspend fun synchronizeInternalControllers() =
                    call(
                        "update_internal_controllers",
                        StorageManagementWire.internalControllers(quote.controllers),
                        false,
                    )

                override suspend fun addManagementController() =
                    call(
                        "update_settings",
                        StorageManagementWire.settingsArguments(bucket, quote.controllers),
                        true,
                    )
            },
            System::currentTimeMillis,
        )
    }

    suspend fun storageStatus(bucket: String): StorageStatus = agentOperation {
        val identity = session ?: error("Sign in to manage storage.")
        val id = StorageWire.canonicalBucket(bucket)
        val expected = jsonQuery("bucket_wasm_hash").also { require(it.isTextual) }.asText()
        ICClient(configuration, identity).use {
            StorageWire.reply(
                id,
                it.callRaw(
                    "canister_status",
                    StorageWire.arguments(id),
                    canisterId = "aaaaa-aa",
                    effectiveCanisterId = id,
                ),
                expected,
            )
        }
    }

    suspend fun uploadImage(bucket: String, image: DraftImage): PostFileRef = agentOperation {
        val identity = session ?: error("Sign in to attach images.")
        org.ic4j.types.Principal.fromString(bucket)
        require(image.bytes.size in 1..DraftImages.MAX_BYTES)
        ICClient(configuration, identity).use {
            val reply = it.callRaw("write", image.bytes, canisterId = bucket)
            require(reply.size >= 8) { "The media bucket returned an invalid reply." }
            val offset = java.math.BigInteger(1, reply.copyOfRange(0, 8))
            require(offset.bitLength() <= 63) { "The media offset is unsupported." }
            PostFileRef(image.id, offset.toLong(), image.bytes.size.toLong())
        }
    }

    suspend fun addPost(
        text: String,
        parent: Long?,
        realm: String?,
        pending: (PendingPost) -> Unit,
        refs: List<PostFileRef> = emptyList(),
        repostId: Long? = null,
    ): Long = agentOperation {
        require(!snsRestricted) { "SNS actions are unavailable while account deletion is pending." }
        val identity = session ?: error("Sign in to use this action.")
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate("add_post", PostWire.encode(text, parent, realm, refs, repostId))
            pending(
                PendingPost(
                    identity.principal().toString(),
                    configuration.canisterId,
                    request.requestId().get(),
                    draftSlot =
                        if (repostId != null) "repost/$repostId"
                        else if (parent == null) "new" else "reply/$parent",
                )
            )
            PostWire.decodeResult(it.completeRaw(it.submitSigned(request)))
        }
    }

    suspend fun editPost(
        post: TaggrPost,
        text: String,
        realm: String?,
        pending: (PendingPost) -> Unit,
        refs: List<PostFileRef> = emptyList(),
    ): Long = agentOperation {
        require(!snsRestricted) { "SNS actions are unavailable while account deletion is pending." }
        val identity = session ?: error("Sign in to edit your post.")
        ICClient(configuration, identity).use {
            val request =
                it.signUpdate(
                    "edit_post",
                    PostWire.encodeEdit(post.id, text, post.body, realm, refs),
                )
            pending(
                PendingPost(
                    identity.principal().toString(),
                    configuration.canisterId,
                    request.requestId().get(),
                    "edit_post",
                    post.id,
                    "edit/${post.id}",
                )
            )
            PostWire.decodeEditResult(it.completeRaw(it.submitSigned(request)))
            post.id
        }
    }

    suspend fun requireSafePublishing(
        text: String,
        realm: String?,
        parent: Long?,
        editId: Long? = null,
    ) {
        require(!text.contains("#nsfw", ignoreCase = true)) {
            "Adult content is unavailable in this app."
        }
        var destination = realm
        if (parent != null) {
            val post =
                posts(listOf(parent)).singleOrNull() ?: error("The parent post is unavailable.")
            require(post.restriction == null && safety?.allowed(post) != false) {
                "The parent post is unavailable."
            }
            destination = post.realm
        }
        if (editId != null) {
            val post = posts(listOf(editId)).singleOrNull() ?: error("This post is unavailable.")
            require(post.restriction == null && safety?.allowed(post) != false) {
                "This post is unavailable."
            }
        }
        if (!destination.isNullOrBlank()) {
            val value =
                jsonQuery("realms", listOf(listOf(destination))).firstOrNull()
                    ?: error("Realm not found")
            require(!value.path("adult_content").asBoolean()) {
                "Adult content is unavailable in this app."
            }
        }
    }

    suspend fun deletePost(post: TaggrPost, pending: (PendingPost) -> Unit) = agentOperation {
        require(!snsRestricted) { "SNS actions are unavailable while account deletion is pending." }
        val identity = session ?: error("Sign in to delete a post.")
        ICClient(configuration, identity).use {
            val request = it.signUpdate("delete_post", PostWire.deleteArguments(post))
            pending(
                PendingPost(
                    identity.principal().toString(),
                    configuration.canisterId,
                    request.requestId().get(),
                    "delete_post",
                    post.id,
                )
            )
            PostWire.decodeDeleteResult(it.completeRaw(it.submitSigned(request)))
        }
    }

    suspend fun recoverPost(pending: PendingPost): Long? = agentOperation {
        val identity = session ?: error("Sign in to check the post result.")
        require(
            identity.principal().toString() == pending.principal &&
                configuration.canisterId == pending.canister
        )
        ICClient(configuration, identity).use { signed ->
            when (val status = signed.requestStatus(pending.requestId)) {
                is org.ic4j.agent.android.ICRequestStatus.Replied ->
                    if (pending.method == "delete_post") {
                        PostWire.decodeDeleteResult(status.reply)
                        pending.postId!!
                    } else if (pending.method == "edit_post") {
                        PostWire.decodeEditResult(status.reply)
                        pending.postId!!
                    } else PostWire.decodeResult(status.reply)
                is org.ic4j.agent.android.ICRequestStatus.Rejected ->
                    throw PostRejectedException(status.message)
                else -> null
            }
        }
    }

    suspend fun tokenTransactions(account: TokenAccount, page: Int): List<TokenTransaction> {
        require(page >= 0)
        return TokenTransactions.decode(
            jsonQuery("transactions", listOf(page, account.owner, account.subaccount))
        )
    }

    suspend fun tokenAccountSummary(account: TokenAccount): TokenAccountSummary = agentOperation {
        val config = jsonQuery("config")
        val decimals = config.required("token_decimals")
        val symbol = config.required("token_symbol")
        require(
            decimals.isIntegralNumber &&
                decimals.bigIntegerValue() >= java.math.BigInteger.ZERO &&
                decimals.bigIntegerValue() <= java.math.BigInteger.valueOf(255) &&
                symbol.isTextual
        )
        TokenAccountSummary(
            TokenTransactions.balanceReply(
                client.queryRaw("icrc1_balance_of", TokenTransactions.balanceArguments(account))
            ),
            decimals.asInt(),
            symbol.asText(),
        )
    }

    suspend fun currentUser(candidate: AuthSession): JsonNode? = agentOperation {
        ICClient(configuration, candidate).use {
            mapper
                .readTree(
                    it.queryRaw(
                        "user",
                        jsonArguments(listOf(TaggrRuntime.domain, emptyList<String>())),
                    )
                )
                .takeUnless { user -> user.isNull }
        }
    }

    suspend fun currentUser(): JsonNode? =
        jsonQuery("user", listOf(TaggrRuntime.domain, emptyList<String>()), true).takeUnless {
            it.isNull
        }

    private fun jsonArguments(arguments: Any): ByteArray {
        require(arguments is List<*>) { "Pass arguments as a tuple list" }
        return LegacyJsonArguments.encode(arguments)
    }

    private suspend fun <T> agentOperation(operation: suspend () -> T): T =
        withContext(Dispatchers.IO) {
            try {
                operation()
            } catch (error: org.ic4j.agent.AgentError) {
                throw IllegalStateException(error.message ?: "IC request failed", error)
            }
        }

    companion object {
        const val CANISTER_ID = "6qfxa-ryaaa-aaaai-qbhsq-cai"
        const val DOMAIN = "$CANISTER_ID.icp0.io"

        fun postUrl(id: Long) = "https://$DOMAIN/#/post/$id"
    }
}
