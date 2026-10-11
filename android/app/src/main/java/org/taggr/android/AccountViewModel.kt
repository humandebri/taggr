package org.taggr.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.ic4j.agent.AuthSession
import org.ic4j.agent.android.ICClient
import org.ic4j.agent.android.InternetIdentityAuthenticator
import org.taggr.android.data.TaggrApi

data class AccountState(
    val restoring: Boolean = true,
    val busy: Boolean = false,
    val principal: String? = null,
    val user: JsonNode? = null,
    val error: String? = null,
    val notice: String? = null,
    val postOutcomeUnknown: Boolean = false,
    val acceptedTerms: Boolean = false,
    val createdRealm: String? = null,
)

data class WalletState(
    val loading: Boolean = false,
    val snapshot: org.taggr.android.data.WalletSnapshot? = null,
    val error: String? = null,
)

data class TransferState(
    val restoring: Boolean = true,
    val pending: org.taggr.android.data.PendingTransfer? = null,
    val blocked: Boolean = false,
)

data class FinancialState(
    val restoring: Boolean = true,
    val pending: org.taggr.android.data.FinancialCall? = null,
    val blocked: Boolean = false,
)

data class RetirementState(
    val restoring: Boolean = true,
    val record: org.taggr.android.data.RetirementRecord? = null,
    val blocked: Boolean = false,
)

data class CreditPurchaseState(
    val restoring: Boolean = true,
    val pending: org.taggr.android.data.CreditPurchaseRecord? = null,
    val receipt: org.taggr.android.data.CreditPurchaseRecord? = null,
    val blocked: Boolean = false,
)

data class CreditInvoiceState(
    val restoring: Boolean = true,
    val receipt: org.taggr.android.data.CreditInvoiceReceipt? = null,
    val blocked: Boolean = false,
)

data class StorageCreationState(
    val restoring: Boolean = true,
    val pending: org.taggr.android.data.StorageCreationRecord? = null,
    val receipt: org.taggr.android.data.StorageCreationRecord? = null,
    val blocked: Boolean = false,
)

data class StorageTopUpState(
    val restoring: Boolean = true,
    val pending: org.taggr.android.data.StorageTopUpRecord? = null,
    val receipt: org.taggr.android.data.StorageTopUpRecord? = null,
    val blocked: Boolean = false,
)

class AccountViewModel(application: Application) : AndroidViewModel(application) {
    val safety = org.taggr.android.data.SafetyStore(application)
    val api = TaggrApi().apply { safety = this@AccountViewModel.safety }
    private val client = ICClient(api.configuration)
    private val store = client.sessionStore(application, "taggr-account")
    private var session: AuthSession? = null
    private var expiryJob: kotlinx.coroutines.Job? = null
    private val drafts =
        application.getSharedPreferences("taggr-drafts", android.content.Context.MODE_PRIVATE)
    private val draftImages = org.taggr.android.data.DraftImageStore(application)
    private val financialStore = org.taggr.android.data.FinancialCallStore(application)
    private val financialMutable = MutableStateFlow(FinancialState())
    val financialState = financialMutable.asStateFlow()
    private val retirementStore = org.taggr.android.data.RetirementStore(application)
    private val retirementMutable = MutableStateFlow(RetirementState())
    val retirementState = retirementMutable.asStateFlow()
    private val purchaseStore = org.taggr.android.data.CreditPurchaseStore(application)
    private val purchaseMutable = MutableStateFlow(CreditPurchaseState())
    val purchaseState = purchaseMutable.asStateFlow()
    private val invoiceStore = org.taggr.android.data.CreditInvoiceStore(application)
    private val invoiceMutable = MutableStateFlow(CreditInvoiceState())
    val invoiceState = invoiceMutable.asStateFlow()
    private val creationStore = org.taggr.android.data.StorageCreationStore(application)
    private val creationMutable = MutableStateFlow(StorageCreationState())
    val creationState = creationMutable.asStateFlow()
    private val topUpStore = org.taggr.android.data.StorageTopUpStore(application)
    private val topUpMutable = MutableStateFlow(StorageTopUpState())
    val topUpState = topUpMutable.asStateFlow()
    private val pendingTransfers = org.taggr.android.data.PendingTransferStore(application)
    private val transfers = MutableStateFlow(TransferState())
    val transferState = transfers.asStateFlow()
    private val pendingPosts = org.taggr.android.data.PendingPostStore(application)
    private val mutable = MutableStateFlow(AccountState(acceptedTerms = safety.accepted))
    val state = mutable.asStateFlow()
    private val youtubeMutable =
        MutableStateFlow<org.taggr.android.data.YouTubeAuthorization.Access?>(null)
    internal val youtubeAccess = youtubeMutable.asStateFlow()

    internal fun setYouTubeAccess(
        owner: String?,
        access: org.taggr.android.data.YouTubeAuthorization.Access?,
    ) {
        require(mutable.value.principal == owner) { "Return to the original TAGGR account." }
        youtubeMutable.value = access
    }

    private val walletMutable = MutableStateFlow(WalletState())
    val walletState = walletMutable.asStateFlow()
    private var walletJob: kotlinx.coroutines.Job? = null

    init {
        viewModelScope.launch {
            try {
                val restored = withContext(Dispatchers.IO) { client.loadSession(store) }
                install(restored)
                safety.refresh()
                if (restored != null) {
                    val pending =
                        withContext(Dispatchers.IO) {
                            pendingPosts.load(
                                restored.principal().toString(),
                                api.configuration.canisterId,
                            )
                        }
                    mutable.value = mutable.value.copy(postOutcomeUnknown = pending != null)
                    refreshUser()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error !is Exception && error !is org.ic4j.agent.AgentError) throw error
                mutable.value =
                    mutable.value.copy(error = "Session could not be restored. ${error.message}")
            } finally {
                mutable.value = mutable.value.copy(restoring = false)
            }
        }
    }

    private suspend fun install(value: AuthSession?) {
        if (value?.principal()?.toString() != mutable.value.principal || value == null)
            youtubeMutable.value = null
        expiryJob?.cancel()
        expiryJob = null
        transfers.value = TransferState()
        financialMutable.value = FinancialState()
        creationMutable.value = StorageCreationState()
        topUpMutable.value = StorageTopUpState()
        invoiceMutable.value = CreditInvoiceState()
        purchaseMutable.value = CreditPurchaseState()
        retirementMutable.value = RetirementState()
        api.snsRestricted = value != null
        walletJob?.cancel()
        walletMutable.value = WalletState()
        api.setSession(value)
        org.taggr.android.data.YouTubeBackground.observeOwner(
            getApplication(),
            value?.principal()?.toString(),
        )
        safety.account(value?.principal()?.toString())
        session?.close()
        session = value
        if (value != null)
            expiryJob = viewModelScope.launch {
                org.taggr.android.data.watchSessionExpiry(
                    value.expiration(),
                    canExpire = { !mutable.value.busy && !mutable.value.restoring },
                ) {
                    if (session === value) {
                        expiryJob = null
                        expireSession(value)
                    }
                }
            }
        mutable.value =
            AccountState(
                restoring = false,
                busy = mutable.value.busy,
                principal = value?.principal()?.toString(),
                acceptedTerms = safety.accepted,
            )
        if (value == null) transfers.value = TransferState(restoring = false)
        else
            try {
                val pending =
                    withContext(Dispatchers.IO) {
                        pendingTransfers.load(
                            value.principal().toString(),
                            org.taggr.android.data.transferNetwork(api.configuration),
                        )
                    }
                transfers.value = TransferState(restoring = false, pending = pending)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                transfers.value = TransferState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error =
                            "The pending transfer record could not be loaded. New transfers are blocked. ${e.message}"
                    )
            }
        if (value == null) financialMutable.value = FinancialState(restoring = false)
        else
            try {
                val pending =
                    withContext(Dispatchers.IO) {
                        financialStore.load(
                            value.principal().toString(),
                            org.taggr.android.data.financialNetwork(api.configuration),
                        )
                    }
                financialMutable.value = FinancialState(restoring = false, pending = pending)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                financialMutable.value = FinancialState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error = "The financial operation record could not be restored. ${e.message}"
                    )
            }
        if (value == null) topUpMutable.value = StorageTopUpState(restoring = false)
        else
            try {
                val owner = value.principal().toString()
                val network = org.taggr.android.data.financialNetwork(api.configuration)
                topUpMutable.value =
                    withContext(Dispatchers.IO) {
                        StorageTopUpState(
                            restoring = false,
                            pending = topUpStore.load(owner, network),
                            receipt = topUpStore.latestReceipt(owner, network),
                        )
                    }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                topUpMutable.value = StorageTopUpState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error =
                            "Storage top-up could not be restored. New financial operations are blocked. ${e.message}"
                    )
            }
        if (value == null) creationMutable.value = StorageCreationState(restoring = false)
        else
            try {
                val pending =
                    withContext(Dispatchers.IO) {
                        creationStore.load(
                            value.principal().toString(),
                            org.taggr.android.data.financialNetwork(api.configuration),
                        )
                    }
                val receipt =
                    withContext(Dispatchers.IO) {
                        creationStore.latestFailureReceipt(
                            value.principal().toString(),
                            org.taggr.android.data.financialNetwork(api.configuration),
                        )
                    }
                creationMutable.value =
                    StorageCreationState(restoring = false, pending = pending, receipt = receipt)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                creationMutable.value = StorageCreationState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error =
                            "Storage creation could not be restored. New financial operations are blocked. ${e.message}"
                    )
            }
        if (value == null) invoiceMutable.value = CreditInvoiceState(restoring = false)
        else
            try {
                val receipt =
                    withContext(Dispatchers.IO) {
                        invoiceStore.load(
                            value.principal().toString(),
                            org.taggr.android.data.financialNetwork(api.configuration),
                            api.configuration.canisterId,
                        )
                    }
                invoiceMutable.value = CreditInvoiceState(restoring = false, receipt = receipt)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                invoiceMutable.value = CreditInvoiceState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error = "The saved credit invoice could not be restored. ${e.message}"
                    )
            }
        if (value == null) purchaseMutable.value = CreditPurchaseState(restoring = false)
        else
            try {
                val owner = value.principal().toString()
                val network = org.taggr.android.data.financialNetwork(api.configuration)
                val pending = withContext(Dispatchers.IO) { purchaseStore.load(owner, network) }
                val receipt =
                    withContext(Dispatchers.IO) { purchaseStore.latestReceipt(owner, network) }
                purchaseMutable.value = CreditPurchaseState(false, pending, receipt)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                purchaseMutable.value = CreditPurchaseState(restoring = false, blocked = true)
                mutable.value =
                    mutable.value.copy(
                        error =
                            "The credit purchase could not be restored. New financial operations are blocked. ${e.message}"
                    )
            }
        if (value == null) {
            retirementMutable.value = RetirementState(restoring = false)
            api.snsRestricted = false
        } else
            try {
                val record =
                    withContext(Dispatchers.IO) {
                        retirementStore.load(
                            value.principal().toString(),
                            org.taggr.android.data.financialNetwork(api.configuration),
                        )
                    }
                retirementMutable.value = RetirementState(false, record)
                api.snsRestricted = record != null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                retirementMutable.value = RetirementState(restoring = false, blocked = true)
                api.snsRestricted = true
                mutable.value =
                    mutable.value.copy(
                        error =
                            "Deletion progress could not be restored. SNS actions are blocked. ${e.message}"
                    )
            }
    }

    private fun draftSlot(parent: Long?, editId: Long?, repostId: Long? = null) =
        if (repostId != null) "repost/$repostId"
        else if (editId != null) "edit/$editId" else if (parent == null) "new" else "reply/$parent"

    private fun draftKey(slot: String) =
        "${api.configuration.canisterId}/${session?.principal()}/${slot.removePrefix("reply/")}"

    fun readDraft(
        parent: Long?,
        editing: org.taggr.android.data.TaggrPost? = null,
        repostId: Long? = null,
    ): String =
        drafts.getString(draftKey(draftSlot(parent, editing?.id, repostId)), null)
            ?: editing?.body
            ?: ""

    fun readDraftRealm(
        parent: Long?,
        editing: org.taggr.android.data.TaggrPost? = null,
        reposting: org.taggr.android.data.TaggrPost? = null,
    ): String =
        drafts.getString(draftKey(draftSlot(parent, editing?.id, reposting?.id)) + "/realm", null)
            ?: editing?.realm
            ?: reposting?.realm
            ?: ""

    fun saveDraft(
        parent: Long?,
        text: String,
        realm: String? = null,
        editId: Long? = null,
        repostId: Long? = null,
    ) {
        val key = draftKey(draftSlot(parent, editId, repostId))
        val edit = drafts.edit().putString(key, text)
        if (realm != null) edit.putString("$key/realm", realm)
        edit.apply()
    }

    internal fun insertYouTubeUpload(
        job: org.taggr.android.data.YouTubeUploadJob,
        fallbackBody: String,
        expectedSlot: String,
    ): String {
        val current =
            org.taggr.android.data.YouTubeDraftTarget(
                requireNotNull(mutable.value.principal),
                org.taggr.android.data.financialNetwork(api.configuration),
                api.configuration.canisterId,
                job.target.channelId,
                expectedSlot,
            )
        return org.taggr.android.data.YouTubeDraftInsertion.insert(
            drafts,
            draftKey(expectedSlot),
            job,
            current,
            fallbackBody,
        )
    }

    suspend fun loadImages(parent: Long?, editId: Long?) =
        withContext(Dispatchers.IO) {
            draftImages.load(draftKey(draftSlot(parent, editId)))
        }

    suspend fun saveImages(
        parent: Long?,
        editId: Long?,
        images: List<org.taggr.android.data.DraftImage>,
    ) =
        withContext(Dispatchers.IO) {
            draftImages.save(draftKey(draftSlot(parent, editId)), images)
        }

    suspend fun discardDraft(parent: Long?, editId: Long?) {
        require(!mutable.value.busy && !mutable.value.postOutcomeUnknown)
        require(
            !org.taggr.android.data.YouTubeBackground.isRunningForDraft(
                getApplication(),
                session?.principal()?.toString(),
                org.taggr.android.data.financialNetwork(api.configuration),
                api.configuration.canisterId,
                draftSlot(parent, editId),
            )
        ) {
            "Pause this draft's video upload before discarding the draft."
        }
        clearDraft(draftSlot(parent, editId))
    }

    private suspend fun clearDraft(slot: String) {
        val key = draftKey(slot)
        org.taggr.android.data.YouTubeDraftInsertion.clear(drafts, key)
        withContext(Dispatchers.IO) { draftImages.clear(key) }
    }

    fun signIn(authenticator: InternetIdentityAuthenticator) =
        action(checkExpiry = false) {
            val authenticated =
                client.signIn(authenticator, org.taggr.android.data.TaggrRuntime.callback)
            try {
                withContext(Dispatchers.IO) { store.save(authenticated) }
            } catch (error: Throwable) {
                authenticated.close()
                throw error
            }
            install(authenticated)
            val pending =
                withContext(Dispatchers.IO) {
                    pendingPosts.load(
                        authenticated.principal().toString(),
                        api.configuration.canisterId,
                    )
                }
            mutable.value = mutable.value.copy(postOutcomeUnknown = pending != null)
            refreshUser()
        }

    fun signInWithPassword(phrase: String, completed: () -> Unit) =
        action(checkExpiry = false) {
            require(session == null) { "Sign out before using another identity." }
            val (authenticated, user) =
                org.taggr.android.data.PasswordIdentity.authenticate(
                    phrase,
                    createSession = { seed -> client.delegatingSession(seed) },
                    loadUser = api::currentUser,
                )
            try {
                withContext(Dispatchers.IO) { store.save(authenticated) }
            } catch (error: Throwable) {
                authenticated.close()
                throw error
            }
            install(authenticated)
            safety.remoteUser(user)
            mutable.value = mutable.value.copy(user = user)
            api.snsRestricted =
                retirementMutable.value.restoring ||
                    retirementMutable.value.blocked ||
                    retirementMutable.value.record != null ||
                    user.path("deactivated").asBoolean()
            val pending =
                withContext(Dispatchers.IO) {
                    pendingPosts.load(
                        authenticated.principal().toString(),
                        api.configuration.canisterId,
                    )
                }
            mutable.value = mutable.value.copy(postOutcomeUnknown = pending != null)
            completed()
        }

    fun signOut() =
        action(checkExpiry = false) {
            withContext(Dispatchers.IO) {
                store.clear()
                pendingPosts.clear()
                draftImages.clearAll()
                drafts.edit().clear().apply()
            }
            install(null)
        }

    suspend fun refreshUser() {
        val active = session ?: return
        val user = api.currentUser()
        if (session === active) {
            safety.remoteUser(user)
            mutable.value = mutable.value.copy(user = user)
            api.snsRestricted =
                retirementMutable.value.restoring ||
                    retirementMutable.value.blocked ||
                    retirementMutable.value.record != null ||
                    user?.path("deactivated")?.asBoolean() == true
        }
    }

    fun createUser(name: String, invite: String) = action {
        require(name.isNotBlank()) { "Enter a user name." }
        api.update(
            "create_user",
            listOf(
                name.trim(),
                if (invite.isBlank()) "" else org.taggr.android.data.Invites.code(invite),
            ),
        )
        refreshUser()
    }

    fun post(
        text: String,
        parent: Long?,
        realm: String?,
        completed: (Long) -> Unit,
        editing: org.taggr.android.data.TaggrPost? = null,
        images: List<org.taggr.android.data.DraftImage> = emptyList(),
        repostId: Long? = null,
    ) = action {
        require(mutable.value.acceptedTerms) { "Accept the terms before posting." }
        val user = mutable.value.user ?: error("Create your TAGGR account before posting.")
        val owner = session ?: error("Sign in to post.")
        fun checkVideoTransfer() {
            require(
                !org.taggr.android.data.YouTubeBackground.isRunningForDraft(
                    getApplication(),
                    owner.principal().toString(),
                    org.taggr.android.data.financialNetwork(api.configuration),
                    api.configuration.canisterId,
                    draftSlot(parent, editing?.id, repostId),
                )
            ) {
                "Wait for this draft's video upload or pause it before posting."
            }
        }
        checkVideoTransfer()
        require(
            repostId == null ||
                (repostId >= 0 && parent == null && editing == null && images.isEmpty())
        )
        if (repostId != null)
            require(api.posts(listOf(repostId)).singleOrNull() != null) { "Repost unavailable" }
        require(!mutable.value.postOutcomeUnknown) {
            "Check the previous post result before sending again."
        }
        if (editing != null) {
            require(editing.authorId == user.path("id").asLong()) {
                "You can only edit your own posts."
            }
            val current =
                api.posts(listOf(editing.id)).singleOrNull() ?: error("This post is unavailable.")
            require(current.body == editing.body) {
                "This post has changed. Reopen the editor before saving."
            }
        }
        api.requireSafePublishing(text, realm, editing?.parent ?: parent, editing?.id)
        val attached =
            org.taggr.android.data.DraftImages.referenced(
                text,
                images,
                org.taggr.android.data.DraftImages.storedIds(editing?.files?.keys ?: emptySet()),
            )
        val refs =
            if (attached.isEmpty()) emptyList()
            else {
                val bucket = user.path("bucket").asText("")
                require(bucket.isNotBlank()) {
                    "No personal media bucket is configured. Set up storage before attaching images."
                }
                val limit =
                    api.jsonQuery("config")
                        .path("max_blob_size_bytes")
                        .asInt(org.taggr.android.data.DraftImages.MAX_BYTES)
                require(attached.all { it.bytes.size <= limit }) {
                    "An image exceeds the server's size limit. Remove and attach it again."
                }
                attached.map { api.uploadImage(bucket, it) }
            }
        // Never retry an uncertain update automatically or discard the draft on failure.
        var recorded = false
        val id =
            try {
                val record: (org.taggr.android.data.PendingPost) -> Unit = {
                    pendingPosts.save(it)
                    recorded = true
                }
                require(session === owner) { "The account changed. Reopen the composer." }
                checkVideoTransfer()
                if (editing == null) api.addPost(text, parent, realm, record, refs, repostId)
                else api.editPost(editing, text, realm, record, refs)
            } catch (error: org.taggr.android.data.PostRejectedException) {
                withContext(Dispatchers.IO) { pendingPosts.clear() }
                throw error
            } catch (error: Throwable) {
                if (
                    error is CancellationException ||
                        (error !is Exception && error !is org.ic4j.agent.AgentError)
                )
                    throw error
                if (!recorded) throw error
                mutable.value = mutable.value.copy(postOutcomeUnknown = true)
                throw IllegalStateException(
                    "The post result could not be confirmed. Check your posts before sending again. Your draft is kept.",
                    error,
                )
            }
        withContext(Dispatchers.IO) { pendingPosts.clear() }
        mutable.value =
            mutable.value.copy(notice = "Posted successfully.", postOutcomeUnknown = false)
        clearDraft(draftSlot(parent, editing?.id, repostId))
        completed(id)
        refreshUser()
    }

    fun saveProfile(
        draft: org.taggr.android.data.ProfileDraft,
        baseline: JsonNode,
        completed: () -> Unit,
        failed: (JsonNode?) -> Unit,
    ) = action {
        var profileSaved = false
        try {
            val current = api.currentUser() ?: error("Create your TAGGR account first.")
            require(
                current.path("id") == baseline.path("id") &&
                    org.taggr.android.data.ProfileDraft.from(current) ==
                        org.taggr.android.data.ProfileDraft.from(baseline)
            ) {
                "Your account changed. Reload it before saving."
            }
            draft.validate()
            if (draft.profileChanged(current)) {
                api.update("update_user", draft.updateArguments(current))
                profileSaved = true
            }
            if (draft.links != current.path("settings").path("links").asText("")) {
                val latest = api.currentUser() ?: error("Account unavailable")
                api.update("update_user_settings", listOf(draft.mergedSettings(latest)))
            }
            refreshUser()
            completed()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
            val fresh =
                try {
                    api.currentUser()
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (_: Exception) {
                    null
                }
            if (fresh != null) mutable.value = mutable.value.copy(user = fresh)
            failed(fresh)
            throw IllegalStateException(
                (if (profileSaved) "Profile saved; links may not be saved. " else "") +
                    (e.message ?: "Save failed. Reload your account before retrying."),
                e,
            )
        }
    }

    fun mutate(method: String, arguments: Any, completed: () -> Unit = {}) = action {
        api.update(method, arguments)
        refreshUser()
        completed()
    }

    fun reactToPost(id: Long, reaction: Int, owner: String, completed: () -> Unit) = action {
        fun requireAccount() {
            require(id >= 0 && session?.principal()?.toString() == owner) {
                "The account changed. Refresh the post."
            }
        }
        requireAccount()
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val userId = user.required("id").asLong(-1)
        require(userId >= 0) { "Account unavailable" }
        org.taggr.android.data.submitPostReaction(
            id,
            userId,
            reaction,
            read = { api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable") },
            send = { api.update("react", listOf(id, reaction)) },
            checkOwner = ::requireAccount,
        )
        refreshUser()
        requireAccount()
        completed()
    }

    private fun requirePurchaseReady() {
        requireTopUpReady()
        require(
            !purchaseMutable.value.restoring &&
                !purchaseMutable.value.blocked &&
                purchaseMutable.value.pending == null
        ) {
            "Finish or check the pending credit purchase before another financial operation."
        }
    }

    private fun requireTopUpReady() {
        require(
            !topUpMutable.value.restoring &&
                !topUpMutable.value.blocked &&
                topUpMutable.value.pending == null
        ) {
            "Finish or check the pending storage top-up before another financial operation."
        }
    }

    private fun requireCreationReady(allowStopped: Boolean = false) {
        if (!allowStopped)
            require(!api.snsRestricted) {
                "New financial operations are unavailable while account deletion is pending."
            }
        requirePurchaseReady()
        require(
            !creationMutable.value.restoring &&
                !creationMutable.value.blocked &&
                creationMutable.value.pending == null
        ) {
            "Finish the pending storage creation before another financial operation."
        }
    }

    private fun requireFinancialReady(allowStopped: Boolean = false) {
        requireCreationReady(allowStopped)
        require(
            !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null
        ) {
            "Confirm the previous financial operation before continuing."
        }
        require(
            !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null
        ) {
            "Confirm the previous ICP transfer before continuing."
        }
    }

    fun prepareWithdrawal(ready: (org.taggr.android.data.WithdrawQuote) -> Unit) = action {
        requireFinancialReady(allowStopped = true)
        val owner = session?.principal()?.toString() ?: error("Sign in to withdraw rewards.")
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        mutable.value = mutable.value.copy(user = user)
        ready(
            org.taggr.android.data.WithdrawQuote.prepare(
                owner,
                user,
                api.wallet(owner).feeE8s,
                org.taggr.android.data.financialNetwork(api.configuration),
                System.currentTimeMillis(),
            )
        )
    }

    fun withdrawRewards(quote: org.taggr.android.data.WithdrawQuote) = action {
        requireFinancialReady(allowStopped = true)
        val owner = session?.principal()?.toString() ?: error("Sign in to withdraw rewards.")
        require(
            owner == quote.owner &&
                org.taggr.android.data.financialNetwork(api.configuration) == quote.network
        )
        quote.validate(
            api.currentUser() ?: error("Account unavailable"),
            api.wallet(owner).feeE8s,
            System.currentTimeMillis(),
        )
        runFinancial("withdraw_rewards", "null".toByteArray())
    }

    private suspend fun requireNoPendingPost(owner: String) {
        require(
            withContext(Dispatchers.IO) {
                pendingPosts.load(owner, api.configuration.canisterId)
            } == null
        ) {
            "Check the pending post result before deleting the account."
        }
    }

    fun prepareRetirement(ready: (org.taggr.android.data.RetirementQuote) -> Unit) = action {
        requirePurchaseReady()
        require(
            !creationMutable.value.restoring &&
                !creationMutable.value.blocked &&
                creationMutable.value.pending == null &&
                !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null &&
                !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null &&
                !mutable.value.postOutcomeUnknown
        )
        require(
            !retirementMutable.value.restoring &&
                !retirementMutable.value.blocked &&
                (retirementMutable.value.record == null ||
                    retirementMutable.value.record?.stage ==
                        org.taggr.android.data.RetirementStage.PREPARING)
        )
        val owner = session?.principal()?.toString() ?: error("Sign in to delete this account.")
        requireNoPendingPost(owner)
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val quote =
            org.taggr.android.data.RetirementQuote(
                owner,
                org.taggr.android.data.financialNetwork(api.configuration),
                user.path("id").asLong(-1),
                org.taggr.android.data.WithdrawQuote.unsigned(
                    api.jsonQuery("config"),
                    "account_activation_cost",
                ),
                System.currentTimeMillis(),
            )
        quote.validate(user, quote.cost, System.currentTimeMillis())
        ready(quote)
    }

    fun retireAccount(quote: org.taggr.android.data.RetirementQuote) = action {
        require(
            session?.principal()?.toString() == quote.owner &&
                quote.network == org.taggr.android.data.financialNetwork(api.configuration)
        )
        requirePurchaseReady()
        require(
            !creationMutable.value.restoring &&
                !creationMutable.value.blocked &&
                creationMutable.value.pending == null &&
                !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null &&
                !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null &&
                !mutable.value.postOutcomeUnknown
        )
        requireNoPendingPost(quote.owner)
        val user = api.currentUser() ?: error("Account unavailable.")
        quote.validate(
            user,
            org.taggr.android.data.WithdrawQuote.unsigned(
                api.jsonQuery("config"),
                "account_activation_cost",
            ),
            System.currentTimeMillis(),
        )
        val old = retirementMutable.value.record
        val row =
            withContext(Dispatchers.IO) {
                if (old == null)
                    org.taggr.android.data.RetirementRecord(quote).also(retirementStore::create)
                else retirementStore.reapprove(old, quote)
            }
        retirementMutable.value = RetirementState(false, row)
        api.snsRestricted = true
        continueRetirement(row)
    }

    fun checkRetirement() = action {
        val owner = session?.principal()?.toString() ?: error("Sign in to check deletion.")
        val row =
            withContext(Dispatchers.IO) {
                retirementStore.load(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                )
            }
        retirementMutable.value = RetirementState(false, row)
        if (row == null) {
            refreshUser()
            return@action
        }
        require(row.stage != org.taggr.android.data.RetirementStage.PREPARING) {
            "Review the deletion confirmation before retrying preparation."
        }
        api.snsRestricted = true
        continueRetirement(row)
    }

    private suspend fun continueRetirement(initial: org.taggr.android.data.RetirementRecord) {
        val row =
            withContext(Dispatchers.IO) {
                org.taggr.android.data
                    .RetirementWorkflow(api.retirementBackend())
                    .resume(
                        initial,
                        { previous, next ->
                            retirementStore.update(previous, next)
                            retirementMutable.value = RetirementState(false, next)
                        },
                        System.currentTimeMillis(),
                    )
            }
        if (row.stage == org.taggr.android.data.RetirementStage.CLEANUP) {
            withContext(Dispatchers.IO) {
                pendingPosts.clear()
                draftImages.clearAll()
                check(drafts.edit().clear().commit()) {
                    "Device draft cleanup failed. Retry device cleanup."
                }
                // Remove credentials last so incomplete private-data cleanup remains resumable.
                store.clear()
            }
            install(null)
            mutable.value =
                mutable.value.copy(
                    notice =
                        "Account stopped. Credentials and drafts were removed from this device. Names, images and DAO/financial records may remain."
                )
        }
    }

    fun prepareCreditPurchase(ready: (org.taggr.android.data.CreditPurchaseQuote) -> Unit) =
        action {
            requireFinancialReady()
            require(!invoiceMutable.value.restoring && !invoiceMutable.value.blocked)
            runFinancial("mint_credits_with_icp", "0".toByteArray())
            val invoice = invoiceMutable.value.receipt ?: error("Missing credit invoice")
            require(!invoice.invoice.paid) {
                "Existing invoice payment was confirmed. Refresh the credits before preparing another purchase."
            }
            val user = api.currentUser() ?: error("Create your TAGGR account first.")
            val snapshot = api.wallet(invoice.owner)
            val quote =
                org.taggr.android.data.TransferQuote(
                    invoice.owner,
                    org.taggr.android.data.transferNetwork(api.configuration),
                    invoice.invoice.account,
                    invoice.invoice.amountE8s,
                    snapshot.feeE8s,
                    System.currentTimeMillis(),
                )
            quote.validate(snapshot, System.currentTimeMillis())
            ready(
                org.taggr.android.data.CreditPurchaseQuote(
                    user.path("id").asLong(-1),
                    org.taggr.android.data.WithdrawQuote.unsigned(
                        api.jsonQuery("config"),
                        "credits_per_xdr",
                    ),
                    invoice,
                    quote,
                )
            )
        }

    fun purchaseCredits(quote: org.taggr.android.data.CreditPurchaseQuote) = action {
        requireFinancialReady()
        require(
            session?.principal()?.toString() == quote.invoice.owner &&
                quote.invoice.network == org.taggr.android.data.financialNetwork(api.configuration)
        )
        val row = org.taggr.android.data.CreditPurchaseRecord(quote)
        withContext(Dispatchers.IO) { purchaseStore.create(row) }
        purchaseMutable.value = CreditPurchaseState(restoring = false, pending = row)
        continueCreditPurchase(row)
    }

    fun resumeCreditPurchase() = action {
        requireTopUpReady()
        require(!purchaseMutable.value.restoring)
        require(
            !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null &&
                !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null &&
                !creationMutable.value.restoring &&
                !creationMutable.value.blocked &&
                creationMutable.value.pending == null
        ) {
            "Check the other pending financial operation first."
        }
        val owner =
            session?.principal()?.toString() ?: error("Sign in to check the credit purchase.")
        val row =
            withContext(Dispatchers.IO) {
                purchaseStore.load(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                )
            }
        purchaseMutable.value = CreditPurchaseState(restoring = false, pending = row)
        if (row == null) return@action
        require(row.payment != null) {
            "No payment was dispatched. Cancel this preparation and review the current invoice again."
        }
        require(row.paymentFailure == null) {
            "Review the rejected payment before preparing another purchase."
        }
        continueCreditPurchase(row)
    }

    fun closeCreditPurchase() = action {
        val owner =
            session?.principal()?.toString() ?: error("Sign in to save the purchase result.")
        val row =
            withContext(Dispatchers.IO) {
                purchaseStore.load(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                )
            } ?: return@action
        withContext(Dispatchers.IO) {
            if (row.finished) purchaseStore.archive(row) else purchaseStore.discardUnpaid(row)
        }
        purchaseMutable.value =
            CreditPurchaseState(restoring = false, receipt = row.takeIf { it.finished })
    }

    private suspend fun continueCreditPurchase(
        initial: org.taggr.android.data.CreditPurchaseRecord
    ) {
        val result =
            withContext(Dispatchers.IO) {
                org.taggr.android.data.CreditPurchaseWorkflow(api.creditPurchaseBackend()).resume(
                    initial
                ) { previous, next ->
                    purchaseStore.update(previous, next)
                    purchaseMutable.value = CreditPurchaseState(restoring = false, pending = next)
                }
            }
        result.result?.let { invoice ->
            val receipt =
                org.taggr.android.data.CreditInvoiceReceipt(
                    result.quote.invoice.owner,
                    result.quote.invoice.network,
                    result.quote.invoice.canister,
                    invoice,
                    result.settlement!!.requestId,
                    System.currentTimeMillis(),
                )
            withContext(Dispatchers.IO) { invoiceStore.save(receipt) }
            invoiceMutable.value = CreditInvoiceState(false, receipt)
        }
        withContext(Dispatchers.IO) { purchaseStore.archive(result) }
        purchaseMutable.value = CreditPurchaseState(restoring = false, receipt = result)
        refreshUser()
        reloadWallet()
        mutable.value =
            mutable.value.copy(notice = "Credit purchase confirmed. Ledger block ${result.block}.")
    }

    fun prepareCreditInvoice() = action {
        requireFinancialReady()
        require(!invoiceMutable.value.restoring && !invoiceMutable.value.blocked) {
            "Restore the credit invoice before preparing another."
        }
        runFinancial("mint_credits_with_icp", "0".toByteArray())
    }

    private suspend fun retainInvoiceReply(
        call: org.taggr.android.data.FinancialCall,
        reply: JsonNode,
    ) {
        if (call.method != "mint_credits_with_icp") return
        val receipt =
            org.taggr.android.data.CreditInvoiceReceipt(
                call.owner,
                call.network,
                call.canister,
                org.taggr.android.data.ICPInvoice.decode(reply),
                call.requestId,
                System.currentTimeMillis(),
            )
        withContext(Dispatchers.IO) { invoiceStore.save(receipt) }
        invoiceMutable.value = CreditInvoiceState(restoring = false, receipt = receipt)
    }

    private suspend fun runFinancial(method: String, arguments: ByteArray): JsonNode {
        var recorded: org.taggr.android.data.FinancialCall? = null
        val result: JsonNode
        try {
            val reply =
                api.financialUpdate(method, arguments) {
                    financialStore.save(it)
                    recorded = it
                    financialMutable.value = FinancialState(restoring = false, pending = it)
                }
            retainInvoiceReply(recorded!!, reply)
            result = reply
            withContext(Dispatchers.IO) { financialStore.clear(recorded!!) }
            financialMutable.value = FinancialState(restoring = false)
            mutable.value = mutable.value.copy(notice = financialNotice(recorded!!, reply))
            afterFinancialConfirmed(recorded!!)
        } catch (e: org.taggr.android.data.FinancialRejected) {
            recorded?.let { withContext(Dispatchers.IO) { financialStore.clear(it) } }
            financialMutable.value = FinancialState(restoring = false)
            try {
                refreshUser()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {}
            reloadWallet()
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
            if (recorded == null) throw e
            throw IllegalStateException(
                "The ${if (method == "toggle_realm_membership") "Realm membership" else if (method == "vote_on_poll") "poll vote" else if (method == "transfer_credits") "credit transfer" else "financial"} result is unknown. Check its result before trying again. Nothing was automatically resent.",
                e,
            )
        }
        refreshUser()
        reloadWallet()
        return result
    }

    private fun financialNotice(call: org.taggr.android.data.FinancialCall, reply: JsonNode) =
        if (call.method == "toggle_realm_membership")
            org.taggr.android.data.RealmMembership.notice(call, reply)
        else if (call.method == "vote_on_poll") "Poll vote confirmed."
        else if (call.method == "transfer_credits") "Credits sent."
        else "Financial operation confirmed."

    fun checkFinancial() = action {
        val owner = session?.principal()?.toString() ?: error("Sign in to check the operation.")
        val pending =
            withContext(Dispatchers.IO) {
                financialStore.load(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                )
            }
        financialMutable.value = FinancialState(restoring = false, pending = pending)
        if (pending == null) return@action
        try {
            val reply =
                api.recoverFinancial(pending)
                    ?: error("The result is still unavailable. Nothing was resent.")
            retainInvoiceReply(pending, reply)
            withContext(Dispatchers.IO) { financialStore.clear(pending) }
            financialMutable.value = FinancialState(restoring = false)
            mutable.value = mutable.value.copy(notice = financialNotice(pending, reply))
            afterFinancialConfirmed(pending)
        } catch (e: org.taggr.android.data.FinancialRejected) {
            withContext(Dispatchers.IO) { financialStore.clear(pending) }
            financialMutable.value = FinancialState(restoring = false)
            try {
                refreshUser()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {}
            reloadWallet()
            throw e
        }
        refreshUser()
        reloadWallet()
    }

    fun prepareTransfer(
        recipient: String,
        amount: String,
        ready: (org.taggr.android.data.TransferQuote) -> Unit,
    ) = action {
        requireCreationReady(allowStopped = true)
        require(
            !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null
        ) {
            "Confirm the previous transfer before sending again."
        }
        require(
            !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null
        ) {
            "Confirm the previous financial operation first."
        }
        val owner = session?.principal()?.toString() ?: error("Sign in to send ICP.")
        val snapshot = api.wallet(owner)
        walletMutable.value = WalletState(snapshot = snapshot)
        ready(
            org.taggr.android.data.TransferQuote.prepare(
                recipient,
                amount,
                snapshot,
                org.taggr.android.data.transferNetwork(api.configuration),
                System.currentTimeMillis(),
            )
        )
    }

    fun sendTransfer(quote: org.taggr.android.data.TransferQuote, completed: () -> Unit) = action {
        requireCreationReady(allowStopped = true)
        require(
            !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null
        ) {
            "Confirm the previous transfer before sending again."
        }
        require(
            !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null
        ) {
            "Confirm the previous financial operation first."
        }
        var recorded: org.taggr.android.data.PendingTransfer? = null
        try {
            val block =
                api.transfer(quote) {
                    pendingTransfers.save(it)
                    recorded = it
                    transfers.value = TransferState(restoring = false, pending = it)
                }
            withContext(Dispatchers.IO) { pendingTransfers.clear(recorded!!) }
            transfers.value = TransferState(restoring = false)
            mutable.value = mutable.value.copy(notice = "ICP transfer confirmed. Block $block.")
            completed()
            reloadWallet()
        } catch (e: org.taggr.android.data.TransferRejected) {
            recorded?.let { withContext(Dispatchers.IO) { pendingTransfers.clear(it) } }
            transfers.value = TransferState(restoring = false)
            reloadWallet()
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
            if (recorded == null) throw e
            throw IllegalStateException(
                "The transfer result is unknown. Check its result before sending again. It has not been automatically resent.",
                e,
            )
        }
    }

    fun replayTransfer(expected: org.taggr.android.data.PendingTransfer, completed: () -> Unit) =
        action {
            val owner = session?.principal()?.toString() ?: error("Sign in to retry the transfer.")
            val current =
                withContext(Dispatchers.IO) {
                    pendingTransfers.load(
                        owner,
                        org.taggr.android.data.transferNetwork(api.configuration),
                    )
                } ?: error("No pending transfer")
            require(current.matches(expected)) { "The pending transfer changed. Review it again." }
            var recorded = current
            try {
                val block =
                    api.replayTransfer(current) { requestId ->
                        recorded = pendingTransfers.appendReplay(current, requestId)
                        transfers.value = TransferState(restoring = false, pending = recorded)
                    }
                withContext(Dispatchers.IO) { pendingTransfers.clear(recorded) }
                transfers.value = TransferState(restoring = false)
                mutable.value = mutable.value.copy(notice = "ICP transfer confirmed. Block $block.")
                completed()
                reloadWallet()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                // A replay rejection does not prove the original request was rejected.
                transfers.value = TransferState(restoring = false, pending = recorded)
                throw IllegalStateException(
                    (e.message ?: "Retry result unknown") +
                        " The original payment remains pending. Check all recorded results before making a new transfer.",
                    e,
                )
            }
        }

    fun checkTransfer() = action {
        val owner = session?.principal()?.toString() ?: error("Sign in to check the transfer.")
        val pending =
            withContext(Dispatchers.IO) {
                pendingTransfers.load(
                    owner,
                    org.taggr.android.data.transferNetwork(api.configuration),
                )
            }
        transfers.value = TransferState(restoring = false, pending = pending)
        if (pending == null) return@action
        try {
            val block =
                api.recoverTransfer(pending)
                    ?: error(
                        "The transfer result is still unavailable. Nothing was resent. Keep this pending record until the result can be confirmed."
                    )
            withContext(Dispatchers.IO) { pendingTransfers.clear(pending) }
            transfers.value = TransferState(restoring = false)
            mutable.value = mutable.value.copy(notice = "ICP transfer confirmed. Block $block.")
            reloadWallet()
        } catch (e: org.taggr.android.data.TransferRejected) {
            withContext(Dispatchers.IO) { pendingTransfers.clear(pending) }
            transfers.value = TransferState(restoring = false)
            reloadWallet()
            throw e
        }
    }

    fun reloadWallet() {
        val owner = session?.principal()?.toString() ?: return
        walletJob?.cancel()
        walletMutable.value = WalletState(loading = true)
        walletJob = viewModelScope.launch {
            try {
                val snapshot = api.wallet(owner)
                if (session?.principal()?.toString() == owner)
                    walletMutable.value = WalletState(snapshot = snapshot)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                if (session?.principal()?.toString() == owner)
                    walletMutable.value =
                        WalletState(error = e.message ?: "Wallet could not be loaded.")
            }
        }
    }

    private suspend fun afterFinancialConfirmed(call: org.taggr.android.data.FinancialCall) {
        if (call.method == "create_realm") {
            val name =
                com.fasterxml.jackson.databind.ObjectMapper().readTree(call.arguments)[0].asText()
            mutable.value = mutable.value.copy(createdRealm = name)
            try {
                requireFinancialReady()
                org.taggr.android.data.RealmMembership.set(
                    name,
                    true,
                    user = { api.currentUser() ?: error("Account unavailable.") },
                    toggle = { runFinancial("toggle_realm_membership", it) },
                )
                mutable.value = mutable.value.copy(notice = "Realm /$name created and joined.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutable.value =
                    mutable.value.copy(
                        notice =
                            "Realm /$name created. Joining could not be confirmed. ${e.message}"
                    )
            }
            return
        }
        if (call.method != "vote_on_proposal") return
        try {
            val id =
                com.fasterxml.jackson.databind.ObjectMapper().readTree(call.arguments)[0].asLong()
            val proposal = api.proposal(id)
            followProposalDiscussion(proposal.postId)
            mutable.value =
                mutable.value.copy(notice = "Vote confirmed. Discussion notifications enabled.")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            mutable.value =
                mutable.value.copy(
                    notice =
                        "Vote confirmed. Discussion follow could not be confirmed. ${e.message}"
                )
        }
    }

    private suspend fun followProposalDiscussion(postId: Long) {
        requireFinancialReady()
        val user = api.currentUser() ?: error("Account unavailable")
        val discussion =
            api.posts(listOf(postId)).firstOrNull { it.id == postId && it.restriction == null }
                ?: error("Discussion unavailable")
        if (user.path("id").asLong(-1) !in discussion.watchers)
            runFinancial("toggle_following_post", postId.toString().toByteArray())
        require(
            api.posts(listOf(postId))
                .firstOrNull()
                ?.watchers
                ?.contains(user.path("id").asLong(-1)) == true
        ) {
            "Refresh the discussion to check following status."
        }
    }

    fun followProposal(proposalId: Long) = action {
        requireFinancialReady()
        val proposal = api.proposal(proposalId)
        val user = api.currentUser() ?: error("Sign in to follow the discussion.")
        require(proposal.bulletins.any { it.user == user.path("id").asLong(-1) })
        followProposalDiscussion(proposal.postId)
        mutable.value = mutable.value.copy(notice = "Discussion notifications enabled.")
    }

    fun prepareCreditTransfer(
        recipientId: Long,
        amountText: String,
        ready: (org.taggr.android.data.CreditTransferQuote) -> Unit,
    ) = action {
        requireFinancialReady()
        val owner = session?.principal()?.toString() ?: error("Sign in to send credits.")
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val recipient =
            api.jsonQuery(
                "user",
                listOf(org.taggr.android.data.TaggrRuntime.domain, listOf(recipientId.toString())),
            )
        val amount =
            org.taggr.android.data.CreditTransferQuote.parse(amountText)
                ?: error("Enter a positive whole number of credits.")
        val fee =
            org.taggr.android.data.WithdrawQuote.unsigned(
                api.jsonQuery("config"),
                "credit_transaction_fee",
            )
        val quote =
            org.taggr.android.data.CreditTransferQuote(
                owner,
                user.path("id").asLong(-1),
                recipientId,
                recipient.path("name").asText(),
                amount,
                fee,
                org.taggr.android.data.financialNetwork(api.configuration),
                System.currentTimeMillis(),
            )
        quote.validate(user, recipient, fee, System.currentTimeMillis())
        ready(quote)
    }

    fun sendCredits(quote: org.taggr.android.data.CreditTransferQuote, completed: () -> Unit) =
        action {
            requireFinancialReady()
            require(
                session?.principal()?.toString() == quote.owner &&
                    quote.network == org.taggr.android.data.financialNetwork(api.configuration)
            ) {
                "The account or network changed. Review the credit transfer again."
            }
            val user = api.currentUser() ?: error("Create your TAGGR account first.")
            val recipient =
                api.jsonQuery(
                    "user",
                    listOf(
                        org.taggr.android.data.TaggrRuntime.domain,
                        listOf(quote.recipientId.toString()),
                    ),
                )
            val fee =
                org.taggr.android.data.WithdrawQuote.unsigned(
                    api.jsonQuery("config"),
                    "credit_transaction_fee",
                )
            quote.validate(user, recipient, fee, System.currentTimeMillis())
            require(session?.principal()?.toString() == quote.owner) {
                "The account changed. Review the credit transfer again."
            }
            runFinancial("transfer_credits", quote.arguments())
            completed()
        }

    fun voteOnPoll(
        post: org.taggr.android.data.TaggrPost,
        owner: String,
        option: Int,
        anonymous: Boolean,
        changing: Boolean,
        completed: () -> Unit,
    ) = action {
        requireFinancialReady()
        require(session?.principal()?.toString() == owner) {
            "The account changed. Review the poll again."
        }
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val current =
            api.posts(listOf(post.id)).singleOrNull { it.id == post.id }
                ?: error("Poll unavailable.")
        require(current.restriction == null && safety.allowed(current)) { "Poll unavailable." }
        val config = api.jsonQuery("config")
        org.taggr.android.data.PollVotes.validate(
            post.poll ?: error("Poll unavailable."),
            current.poll ?: error("Poll unavailable."),
            current.pollTimestampMillis,
            user.path("id").asLong(-1),
            org.taggr.android.data.TaggrPoll.unsigned(
                config.required("poll_revote_deadline_hours")
            ),
            option,
            changing,
            System.currentTimeMillis(),
        )
        runFinancial(
            "vote_on_poll",
            org.taggr.android.data.PollVotes.arguments(post.id, option, anonymous),
        )
        completed()
    }

    fun voteOnProposal(vote: org.taggr.android.data.ProposalVote, completed: () -> Unit) = action {
        requireFinancialReady()
        val owner = session?.principal()?.toString() ?: error("Sign in to vote.")
        val proposal = api.proposal(vote.proposalId)
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val config = api.jsonQuery("config")
        vote.validate(
            proposal,
            user,
            owner,
            org.taggr.android.data.financialNetwork(api.configuration),
            org.taggr.android.data.ProposalVotes.canonical(
                api.configuration.apiBaseURL,
                org.taggr.android.data.TaggrRuntime.domain,
                api.configuration.canisterId,
            ),
            System.currentTimeMillis(),
            config.required("token_decimals").asInt(),
            org.taggr.android.data.WithdrawQuote.unsigned(config, "max_funding_amount"),
        )
        require(
            api.posts(listOf(proposal.postId)).any {
                it.id == vote.postId && it.restriction == null
            }
        ) {
            "Discussion unavailable."
        }
        runFinancial("vote_on_proposal", vote.arguments())
        completed()
    }

    fun saveInvite(
        owner: String,
        existing: org.taggr.android.data.TaggrInvite?,
        draft: org.taggr.android.data.InviteDraft,
        completed: () -> Unit,
    ) = action {
        requireFinancialReady()
        require(session?.principal()?.toString() == owner) {
            "The account changed. Reload your invites."
        }
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val entries = org.taggr.android.data.Invites.decode(api.jsonQuery("invites", signed = true))
        require(entries.all { it.inviter == user.path("id").asLong(-1) }) {
            "Invite owner changed."
        }
        val minimum =
            org.taggr.android.data.WithdrawQuote.unsigned(
                api.jsonQuery("config"),
                "min_credits_for_inviting",
            )
        draft.validate(
            existing,
            entries,
            org.taggr.android.data.WithdrawQuote.unsigned(user, "cycles"),
            minimum,
        )
        if (draft.realm.isNotEmpty())
            require(
                api.jsonQuery("realms", listOf(listOf(draft.realm))).firstOrNull()?.isObject == true
            ) {
                "Realm not found."
            }
        runFinancial(
            if (existing == null) "create_invite" else "update_invite",
            draft.arguments(existing?.code),
        )
        completed()
    }

    fun resetRealmCreationResult() {
        if (!mutable.value.busy) mutable.value = mutable.value.copy(createdRealm = null)
    }

    fun prepareRealmCreation(
        draft: org.taggr.android.data.RealmCreationDraft,
        ready: (org.taggr.android.data.RealmCreationQuote) -> Unit,
    ) = action {
        requireFinancialReady()
        val owner = session?.principal()?.toString() ?: error("Sign in to create a Realm.")
        val user = api.currentUser() ?: error("Create your TAGGR account first.")
        val limits = org.taggr.android.data.RealmCreationLimits.decode(api.jsonQuery("config"))
        val id = org.taggr.android.data.WithdrawQuote.unsigned(user, "id")
        require(id <= Long.MAX_VALUE.toULong())
        draft.payload(limits, listOf(id), emptyList())
        suspend fun resolve(key: String): List<ULong> =
            draft
                .handles(key)
                .map { handle ->
                    val resolved = api.jsonQuery("user", listOf("", listOf(handle)))
                    require(!resolved.isNull) { "User not found: $handle" }
                    org.taggr.android.data.WithdrawQuote.unsigned(resolved, "id")
                }
                .distinct()
        val payload = draft.payload(limits, resolve("controllers"), resolve("whitelist"))
        val quote =
            org.taggr.android.data.RealmCreationQuote(
                owner,
                org.taggr.android.data.financialNetwork(api.configuration),
                id.toLong(),
                draft.name,
                payload.toString(),
                limits,
                System.currentTimeMillis(),
            )
        quote.validate(user, limits, System.currentTimeMillis())
        val existing = api.jsonQuery("realms", listOf(listOf(quote.name)))
        require(existing.isArray && existing.isEmpty) { "Realm name taken." }
        ready(quote)
    }

    fun createRealm(quote: org.taggr.android.data.RealmCreationQuote) = action {
        requireFinancialReady()
        require(
            session?.principal()?.toString() == quote.owner &&
                org.taggr.android.data.financialNetwork(api.configuration) == quote.network
        ) {
            "The creating account or network changed."
        }
        val user = api.currentUser() ?: error("Account unavailable.")
        quote.validate(
            user,
            org.taggr.android.data.RealmCreationLimits.decode(api.jsonQuery("config")),
            System.currentTimeMillis(),
        )
        val existing = api.jsonQuery("realms", listOf(listOf(quote.name)))
        require(existing.isArray && existing.isEmpty) { "Realm name taken. Nothing was created." }
        runFinancial("create_realm", quote.arguments())
    }

    fun setRealmMembership(
        name: String,
        joined: Boolean,
        realmConsent: JsonNode? = null,
        completed: () -> Unit,
    ) = action {
        requireFinancialReady()
        val realms = api.jsonQuery("realms", listOf(listOf(name)))
        require(realms.isArray && realms.size() == 1) { "Realm not found." }
        if (joined && realmConsent != null)
            org.taggr.android.data.RealmMembership.validateConsent(realmConsent, realms[0])
        org.taggr.android.data.RealmMembership.set(
            name,
            joined,
            user = { api.currentUser() ?: error("Create your TAGGR account first.") },
            toggle = { runFinancial("toggle_realm_membership", it) },
        )
        refreshUser()
        mutable.value =
            mutable.value.copy(notice = if (joined) "Joined /$name." else "Left /$name.")
        completed()
    }

    fun prepareRealmEdit(name: String, ready: (org.taggr.android.data.RealmEditContext) -> Unit) =
        action {
            requireFinancialReady()
            val owner = session?.principal()?.toString() ?: error("Sign in to manage the Realm.")
            val user = api.currentUser() ?: error("Create your TAGGR account first.")
            val realm =
                api.jsonQuery("realms", listOf(listOf(name))).firstOrNull()
                    ?: error("Realm not found.")
            val config = api.jsonQuery("config")
            val maxLogo =
                org.taggr.android.data.WithdrawQuote.unsigned(config, "max_realm_logo_len")
            require(maxLogo in 1uL..65536uL) { "Realm logo limits are unavailable." }
            ready(
                org.taggr.android.data.RealmEditContext(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                    user.path("id").asLong(-1),
                    name,
                    realm.deepCopy(),
                    org.taggr.android.data.WithdrawQuote.unsigned(
                        config,
                        "max_realm_cleanup_penalty",
                    ),
                    maxLogo.toInt(),
                )
            )
        }

    fun saveRealmEdit(
        context: org.taggr.android.data.RealmEditContext,
        draft: org.taggr.android.data.RealmSettingsDraft,
        completed: () -> Unit,
    ) = action {
        requireFinancialReady()
        require(
            session?.principal()?.toString() == context.owner &&
                context.network == org.taggr.android.data.financialNetwork(api.configuration)
        ) {
            "The Realm editing account or network changed."
        }
        val user = api.currentUser() ?: error("Account unavailable.")
        val realm =
            api.jsonQuery("realms", listOf(listOf(context.name))).firstOrNull()
                ?: error("Realm not found.")
        val config = api.jsonQuery("config")
        val maxLogo = org.taggr.android.data.WithdrawQuote.unsigned(config, "max_realm_logo_len")
        require(maxLogo in 1uL..65536uL)
        context.validate(
            realm,
            user,
            org.taggr.android.data.WithdrawQuote.unsigned(config, "max_realm_cleanup_penalty"),
            maxLogo.toInt(),
        )
        val payload = draft.payload(realm, context.maxPenalty, context.maxLogoBytes)
        val args =
            com.fasterxml.jackson.databind
                .ObjectMapper()
                .writeValueAsBytes(listOf(context.name, payload))
        runFinancial("edit_realm", args)
        completed()
    }

    fun prepareStorageTopUp(
        amount: String,
        ready: (org.taggr.android.data.StorageTopUpQuote) -> Unit,
    ) = action {
        requireFinancialReady()
        ready(api.prepareStorageTopUp(amount))
    }

    fun topUpStorage(quote: org.taggr.android.data.StorageTopUpQuote) = action {
        requireFinancialReady()
        val row = org.taggr.android.data.StorageTopUpRecord(quote)
        api.storageTopUpBackend().validate(row)
        withContext(Dispatchers.IO) { topUpStore.create(row) }
        topUpMutable.value = StorageTopUpState(restoring = false, pending = row)
        continueStorageTopUp(row)
    }

    fun resumeStorageTopUp() = action {
        require(!topUpMutable.value.restoring && !topUpMutable.value.blocked)
        require(
            !purchaseMutable.value.restoring &&
                !purchaseMutable.value.blocked &&
                purchaseMutable.value.pending == null &&
                !creationMutable.value.restoring &&
                !creationMutable.value.blocked &&
                creationMutable.value.pending == null &&
                !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null &&
                !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null
        ) {
            "Check the other pending financial operation first."
        }
        val owner = session?.principal()?.toString() ?: error("Sign in to resume storage top-up.")
        val row =
            withContext(Dispatchers.IO) {
                topUpStore.load(owner, org.taggr.android.data.financialNetwork(api.configuration))
            } ?: error("No pending storage top-up")
        require(row.payment != null) {
            "No payment was dispatched. Cancel this preparation and review it again."
        }
        continueStorageTopUp(row)
    }

    fun cancelStorageTopUpPreparation() = action {
        val owner = session?.principal()?.toString() ?: error("Sign in to cancel storage top-up.")
        withContext(Dispatchers.IO) {
            topUpStore
                .load(owner, org.taggr.android.data.financialNetwork(api.configuration))
                ?.let(topUpStore::discardUnpaid)
        }
        topUpMutable.value = topUpMutable.value.copy(restoring = false, pending = null)
    }

    fun acknowledgeStorageTopUp(row: org.taggr.android.data.StorageTopUpRecord) = action {
        require(
            session?.principal()?.toString() == row.quote.transfer.owner &&
                row.quote.network == org.taggr.android.data.financialNetwork(api.configuration)
        )
        withContext(Dispatchers.IO) { topUpStore.acknowledge(row) }
        topUpMutable.value = StorageTopUpState(restoring = false, receipt = row)
        reloadWallet()
    }

    private suspend fun continueStorageTopUp(initial: org.taggr.android.data.StorageTopUpRecord) {
        val result =
            withContext(Dispatchers.IO) {
                org.taggr.android.data.StorageTopUpWorkflow(api.storageTopUpBackend()).resume(
                    initial
                ) { old, next ->
                    topUpStore.update(old, next)
                    topUpMutable.value = topUpMutable.value.copy(restoring = false, pending = next)
                }
            }
        topUpMutable.value = topUpMutable.value.copy(restoring = false, pending = result)
        reloadWallet()
        mutable.value =
            mutable.value.copy(
                notice =
                    "Storage topped up with ${result.cycles} cycles. Save the receipt before another payment."
            )
    }

    fun prepareStorageCreation(ready: (org.taggr.android.data.StorageCreationQuote) -> Unit) =
        action {
            requireFinancialReady()
            ready(api.prepareStorageCreation())
        }

    fun createStorage(quote: org.taggr.android.data.StorageCreationQuote) = action {
        requireFinancialReady()
        require(
            session?.principal()?.toString() == quote.transfer.owner &&
                quote.network == org.taggr.android.data.financialNetwork(api.configuration)
        )
        val row = org.taggr.android.data.StorageCreationRecord(quote)
        withContext(Dispatchers.IO) { creationStore.create(row) }
        creationMutable.value = StorageCreationState(restoring = false, pending = row)
        continueStorageCreation(row)
    }

    fun resumeStorageCreation() = action {
        requirePurchaseReady()
        require(!creationMutable.value.restoring && !creationMutable.value.blocked)
        require(
            !transfers.value.restoring &&
                !transfers.value.blocked &&
                transfers.value.pending == null &&
                !financialMutable.value.restoring &&
                !financialMutable.value.blocked &&
                financialMutable.value.pending == null
        ) {
            "Check the other pending financial operation first."
        }
        val owner = session?.principal()?.toString() ?: error("Sign in to resume storage creation.")
        val row =
            withContext(Dispatchers.IO) {
                creationStore.load(
                    owner,
                    org.taggr.android.data.financialNetwork(api.configuration),
                )
            } ?: error("No pending storage creation")
        require(row.payment != null) {
            "No payment was dispatched. Cancel this preparation and review the current price again."
        }
        continueStorageCreation(row)
    }

    fun acknowledgeStorageFailure(expected: org.taggr.android.data.StorageCreationRecord) = action {
        val owner =
            session?.principal()?.toString() ?: error("Sign in to save the creation result.")
        require(
            expected.quote.transfer.owner == owner &&
                expected.quote.network == org.taggr.android.data.financialNetwork(api.configuration)
        )
        withContext(Dispatchers.IO) { creationStore.acknowledgeFailure(expected) }
        creationMutable.value = StorageCreationState(restoring = false, receipt = expected)
        reloadWallet()
        mutable.value =
            mutable.value.copy(
                notice =
                    "Creation result saved. Review the current price before starting another creation."
            )
    }

    fun cancelStoragePreparation() = action {
        val owner =
            session?.principal()?.toString() ?: error("Sign in to cancel storage preparation.")
        withContext(Dispatchers.IO) {
            creationStore
                .load(owner, org.taggr.android.data.financialNetwork(api.configuration))
                ?.let { creationStore.discardUnpaid(it) }
        }
        creationMutable.value = StorageCreationState(restoring = false)
    }

    private suspend fun continueStorageCreation(
        initial: org.taggr.android.data.StorageCreationRecord
    ) {
        val result =
            withContext(Dispatchers.IO) {
                org.taggr.android.data.StorageCreationWorkflow(api.storageCreationBackend()).resume(
                    initial
                ) { previous, next ->
                    creationStore.update(previous, next)
                    creationMutable.value = StorageCreationState(restoring = false, pending = next)
                }
            }
        withContext(Dispatchers.IO) { creationStore.clearCompleted(result) }
        creationMutable.value = StorageCreationState(restoring = false)
        refreshUser()
        reloadWallet()
        mutable.value =
            mutable.value.copy(
                notice = "Storage created and registered. You can attach images to posts."
            )
    }

    fun prepareStorageManagement(
        change: org.taggr.android.data.StorageManagementAction,
        ready: (org.taggr.android.data.StorageManagementQuote) -> Unit,
    ) = action {
        requireFinancialReady()
        val owner = session?.principal()?.toString() ?: error("Sign in to manage storage.")
        val user = api.currentUser() ?: error("Account unavailable")
        val bucket =
            user["bucket"]?.takeUnless { it.isNull }?.asText() ?: error("Create storage first.")
        val status = api.storageStatus(bucket)
        val quote =
            org.taggr.android.data.StorageManagementQuote(
                change,
                owner,
                user.path("id").asLong(),
                status,
                System.currentTimeMillis(),
            )
        quote.validate(owner, user.path("id").asLong(), bucket, status, System.currentTimeMillis())
        ready(quote)
    }

    fun manageStorage(quote: org.taggr.android.data.StorageManagementQuote, completed: () -> Unit) =
        action {
            requireFinancialReady()
            val owner = session?.principal()?.toString() ?: error("Sign in to manage storage.")
            val user = api.currentUser() ?: error("Account unavailable")
            quote.validate(
                owner,
                user.path("id").asLong(),
                user["bucket"]?.takeUnless { it.isNull }?.asText(),
                api.storageStatus(quote.snapshot.bucket),
                System.currentTimeMillis(),
            )
            api.manageStorage(quote)
            mutable.value =
                mutable.value.copy(
                    notice =
                        if (quote.action == org.taggr.android.data.StorageManagementAction.UPGRADE)
                            "Storage is up to date."
                        else "Blackhole controller added."
                )
            completed()
        }

    fun prepareStorage(bucket: String, ready: (org.taggr.android.data.StorageQuote) -> Unit) =
        action {
            requireCreationReady()
            val owner = session?.principal()?.toString() ?: error("Sign in to manage storage.")
            val user = api.currentUser() ?: error("Create your TAGGR account first.")
            val id = org.taggr.android.data.StorageWire.canonicalBucket(bucket)
            require(user["bucket"]?.takeUnless { it.isNull }?.asText().isNullOrEmpty()) {
                "Storage is already registered. Refresh its status."
            }
            val snapshot = api.storageStatus(id)
            snapshot.requireUsable(owner)
            ready(
                org.taggr.android.data.StorageQuote(
                    owner,
                    user.path("id").asLong(),
                    snapshot,
                    System.currentTimeMillis(),
                )
            )
        }

    fun registerStorage(quote: org.taggr.android.data.StorageQuote) = action {
        requireCreationReady()
        val owner = session?.principal()?.toString() ?: error("Sign in to manage storage.")
        val user = api.currentUser() ?: error("Account unavailable")
        val bucket = user["bucket"]?.takeUnless { it.isNull }?.asText()
        if (bucket == quote.snapshot.bucket) {
            refreshUser()
            return@action
        }
        require(bucket.isNullOrEmpty()) { "A different storage canister is already registered." }
        quote.validate(
            owner,
            user.path("id").asLong(),
            api.storageStatus(quote.snapshot.bucket),
            System.currentTimeMillis(),
        )
        try {
            api.update("set_bucket", listOf(quote.snapshot.bucket))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            try {
                refreshUser()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {}
            if (mutable.value.user?.path("bucket")?.asText() != quote.snapshot.bucket)
                throw IllegalStateException(
                    "Registration result is unavailable. Refresh your account before trying another storage canister.",
                    e,
                )
        }
        refreshUser()
        require(mutable.value.user?.path("bucket")?.asText() == quote.snapshot.bucket) {
            "Storage registration did not confirm the requested canister. Refresh your account."
        }
        mutable.value =
            mutable.value.copy(notice = "Storage registered. You can attach images to posts.")
    }

    fun setUserFollowing(id: Long, selected: Boolean, owner: String, completed: () -> Unit = {}) =
        changeProfileUser(id, selected, owner, mute = false, completed)

    fun setUserMuted(id: Long, selected: Boolean, owner: String, completed: () -> Unit = {}) =
        changeProfileUser(id, selected, owner, mute = true, completed)

    private fun changeProfileUser(
        id: Long,
        selected: Boolean,
        owner: String,
        mute: Boolean,
        completed: () -> Unit,
    ) = action {
        val active = session ?: error("Sign in to interact with another user.")
        fun checkOwner() {
            require(id >= 0 && session === active && active.principal().toString() == owner) {
                "The account changed. Refresh the profile."
            }
        }
        checkOwner()
        val before =
            org.taggr.android.data.ProfileUserState.decode(
                api.currentUser() ?: error("Account unavailable")
            )
        require(id != before.id) { "Choose another user's profile." }
        val target =
            api.jsonQuery(
                "user",
                listOf(org.taggr.android.data.TaggrRuntime.domain, listOf(id.toString())),
            )
        require(!target.isNull && target.path("id").asLong(-1) == id) { "User unavailable" }
        checkOwner()
        if ((id in if (mute) before.muted else before.follows) != selected) {
            val reply =
                if (mute) api.update("toggle_filter", listOf("user", id.toString()))
                else api.update("toggle_following_user", listOf(id))
            if (mute) org.taggr.android.data.ProfileUserState.confirmMuteReply(reply)
            else
                require(reply.isBoolean && reply.booleanValue() == selected) {
                    "Follow result is unconfirmed. Refresh your account before trying again."
                }
        }
        refreshUser()
        checkOwner()
        val after =
            org.taggr.android.data.ProfileUserState.decode(
                mutable.value.user ?: error("Account unavailable")
            )
        require(
            after.id == before.id && (id in if (mute) after.muted else after.follows) == selected
        ) {
            "The profile action result is unconfirmed. Refresh your account before trying again."
        }
        require(!(selected && (if (mute) id in after.follows else id in after.muted))) {
            "Follow and mute states changed. Refresh your account."
        }
        mutable.value =
            mutable.value.copy(
                notice =
                    if (mute) {
                        if (selected) "User muted." else "User unmuted."
                    } else {
                        if (selected) "Following user." else "User unfollowed."
                    }
            )
        completed()
    }

    fun setBookmark(id: Long, selected: Boolean, owner: String) = action {
        require(id >= 0 && session?.principal()?.toString() == owner) {
            "The account changed. Refresh your bookmarks."
        }
        val user = api.currentUser() ?: error("Account unavailable")
        val saved = org.taggr.android.data.BookmarkIDs.decode(user.get("bookmarks"))
        if ((id in saved) != selected) api.update("toggle_bookmark", listOf(id))
        refreshUser()
        val refreshed =
            org.taggr.android.data.BookmarkIDs.decode(mutable.value.user?.get("bookmarks"))
        require((id in refreshed) == selected) { "Bookmark status changed. Refresh to check it." }
    }

    fun setPostWatching(id: Long, selected: Boolean, owner: String, completed: () -> Unit) =
        action {
            fun requireAccount() {
                require(id >= 0 && session?.principal()?.toString() == owner) {
                    "The account changed. Refresh the post."
                }
            }
            requireAccount()
            val user = api.currentUser() ?: error("Sign in to watch a post.")
            val userId = user.required("id").asLong(-1)
            require(userId >= 0) { "Account unavailable" }
            val before = api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable")
            requireAccount()
            if ((userId in before.watchers) != selected) {
                val result = api.update("toggle_following_post", listOf(id))
                require(result.isBoolean && result.booleanValue() == selected) {
                    "Watch status changed. Refresh the post before trying again."
                }
            }
            val after = api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable")
            requireAccount()
            require((userId in after.watchers) == selected) {
                "Watch status is unconfirmed. Refresh the post before trying again."
            }
            mutable.value =
                mutable.value.copy(notice = if (selected) "Watching post." else "Post unwatched.")
            completed()
        }

    fun setPostHidden(id: Long, selected: Boolean, owner: String, completed: () -> Unit) = action {
        fun requireAccount() {
            require(id >= 0 && session?.principal()?.toString() == owner) {
                "The account changed. Refresh the post."
            }
        }
        requireAccount()
        val user = api.currentUser() ?: error("Sign in to hide a post.")
        val userId = user.required("id").asLong(-1)
        require(userId >= 0) { "Account unavailable" }
        val before = api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable")
        requireAccount()
        if (before.hiddenForViewer(userId) != selected) {
            val result = api.update("toggle_hide_post", listOf(id))
            require(result.isBoolean && result.booleanValue() == selected) {
                "Hidden status changed. Refresh the post before trying again."
            }
        }
        val after = api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable")
        requireAccount()
        require(after.hiddenForViewer(userId) == selected) {
            "Hidden status is unconfirmed. Refresh the post before trying again."
        }
        mutable.value =
            mutable.value.copy(notice = if (selected) "Post hidden." else "Post unhidden.")
        completed()
    }

    fun setPostPinned(id: Long, selected: Boolean, owner: String, completed: () -> Unit) = action {
        fun requireAccount() {
            require(id >= 0 && session?.principal()?.toString() == owner) {
                "The account changed. Refresh the post."
            }
        }
        requireAccount()
        val user = api.currentUser() ?: error("Sign in to pin a post.")
        val userId = user.required("id").asLong(-1)
        require(userId >= 0) { "Account unavailable" }
        val post = api.posts(listOf(id)).singleOrNull() ?: error("Post unavailable")
        require(post.authorId == userId) { "You can only pin your own posts." }
        val before = org.taggr.android.data.PinnedPosts.decode(user.get("pinned_posts"))
        requireAccount()
        if ((id in before) != selected) {
            val result = api.update("toggle_pinned_post", listOf(id))
            require(result.isObject && result.has("Ok") && result.get("Ok").isNull) {
                "Pin status is unconfirmed. Refresh your account before trying again."
            }
        }
        refreshUser()
        requireAccount()
        val after =
            org.taggr.android.data.PinnedPosts.decode(mutable.value.user?.get("pinned_posts"))
        require(mutable.value.user?.path("id")?.asLong(-1) == userId && (id in after) == selected) {
            "Pin status changed. Refresh your account before trying again."
        }
        mutable.value =
            mutable.value.copy(notice = if (selected) "Post pinned." else "Post unpinned.")
        completed()
    }

    fun unwatchNotification(id: Long, postId: Long, owner: String) = action {
        require(session?.principal()?.toString() == owner) {
            "The account changed. Refresh notifications."
        }
        val user = api.currentUser() ?: error("Account unavailable")
        val notification =
            org.taggr.android.data.Notifications.decode(user.get("notifications"))
                .entries
                .firstOrNull { it.id == id }
        require(
            notification != null &&
                notification.postId == postId &&
                notification.watchedEntries.isNotEmpty()
        ) {
            "The notification changed. Refresh to continue."
        }
        val post = api.posts(listOf(postId)).singleOrNull() ?: error("Post unavailable")
        if (user.path("id").asLong() in post.watchers)
            api.update("toggle_following_post", listOf(postId))
        // A retry rechecks watchers, so a successful unsubscribe cannot become a subscription.
        api.update("clear_notifications", listOf(listOf(id)))
        refreshUser()
    }

    fun markNotificationsRead(ids: List<Long>, owner: String) = action {
        require(session?.principal()?.toString() == owner) {
            "The account changed. Refresh notifications."
        }
        val selected = ids.distinct()
        require(selected.all { it >= 0 })
        if (selected.isEmpty()) return@action
        api.update("clear_notifications", listOf(selected))
        refreshUser()
    }

    fun reload() = action { refreshUser() }

    fun deletePost(reviewed: org.taggr.android.data.TaggrPost, completed: () -> Unit) = action {
        val owner = session ?: error("Sign in to delete a post.")
        require(!mutable.value.postOutcomeUnknown) {
            "Check the pending post result before deleting."
        }
        val user = api.currentUser() ?: error("Account unavailable")
        require(user.path("id").asLong(-1) == reviewed.authorId && !reviewed.deleted) {
            "You can only delete your own undeleted posts."
        }
        val current = api.posts(listOf(reviewed.id)).singleOrNull() ?: error("Post unavailable")
        val versions =
            withContext(Dispatchers.Default) {
                require(
                    !current.deleted &&
                        current.authorId == reviewed.authorId &&
                        current.deletionVersions() == reviewed.deletionVersions()
                ) {
                    "The post changed. Reopen the deletion confirmation."
                }
                current.deletionVersions()
            }
        val config = api.jsonQuery("config")
        val limit = config.path("max_post_length").asInt(-1)
        require(limit > 0 && versions.all { it.toByteArray(Charsets.UTF_8).size <= limit }) {
            "The edit history exceeds the deletion limit."
        }
        require(session === owner) { "The account changed. Reopen the post." }
        var recorded = false
        try {
            api.deletePost(current) {
                pendingPosts.save(it)
                recorded = true
            }
        } catch (rejected: org.taggr.android.data.PostRejectedException) {
            withContext(Dispatchers.IO) { pendingPosts.clear() }
            throw rejected
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (e: Exception) {
            if (recorded) {
                mutable.value = mutable.value.copy(postOutcomeUnknown = true)
                throw IllegalStateException(
                    "Deletion result is unconfirmed. Check the result before trying again.",
                    e,
                )
            }
            throw e
        } catch (e: org.ic4j.agent.AgentError) {
            if (recorded) mutable.value = mutable.value.copy(postOutcomeUnknown = true)
            throw e
        }
        withContext(Dispatchers.IO) { pendingPosts.clear() }
        mutable.value = mutable.value.copy(postOutcomeUnknown = false, notice = "Post deleted.")
        completed()
        refreshUser()
    }

    suspend fun hasPendingRepost(owner: String, sourceId: Long): Boolean =
        withContext(Dispatchers.IO) {
            val pending = pendingPosts.load(owner, api.configuration.canisterId)
            pending?.method == "add_post" && pending.draftSlot == "repost/$sourceId"
        }

    fun resolveRepostAfterReview(
        owner: String,
        sourceId: Long,
        keepDraft: Boolean,
        completed: () -> Unit,
    ) = action {
        require(session?.principal()?.toString() == owner) {
            "The account changed. Reopen the repost."
        }
        val pending =
            withContext(Dispatchers.IO) { pendingPosts.load(owner, api.configuration.canisterId) }
        require(pending?.method == "add_post" && pending.draftSlot == "repost/$sourceId") {
            "The pending request belongs to another post. Check its result from Account."
        }
        require(session?.principal()?.toString() == owner) {
            "The account changed. Reopen the repost."
        }
        if (!keepDraft) clearDraft("repost/$sourceId")
        withContext(Dispatchers.IO) { pendingPosts.clear() }
        mutable.value =
            mutable.value.copy(
                postOutcomeUnknown = false,
                notice =
                    if (keepDraft) "Repost draft retained for editing. No request was sent."
                    else "Repost marked as checked by you. No request was sent.",
            )
        completed()
    }

    fun recoverPost(completed: (Long) -> Unit) = action {
        val identity = session ?: error("Sign in to check the post result.")
        val pending =
            withContext(Dispatchers.IO) {
                pendingPosts.load(identity.principal().toString(), api.configuration.canisterId)
            } ?: error("No pending post")
        try {
            val id = api.recoverPost(pending)
            if (id == null)
                error(
                    "The post result is still unavailable. Check your profile; this action has not resent the post."
                )
            withContext(Dispatchers.IO) { pendingPosts.clear() }
            mutable.value =
                mutable.value.copy(
                    postOutcomeUnknown = false,
                    notice =
                        if (pending.method == "delete_post") "Deletion confirmed."
                        else "Post confirmed.",
                )
            pending.draftSlot?.let { clearDraft(it) }
            completed(id)
            if (pending.method == "delete_post") refreshUser()
        } catch (e: org.taggr.android.data.PostRejectedException) {
            withContext(Dispatchers.IO) { pendingPosts.clear() }
            mutable.value = mutable.value.copy(postOutcomeUnknown = false)
            throw e
        }
    }

    fun acceptTerms() {
        safety.accept()
        mutable.value = mutable.value.copy(acceptedTerms = true)
    }

    fun blockUser(id: Long, blocked: Boolean = true, changed: () -> Unit = {}) {
        if (mutable.value.busy || mutable.value.restoring) return
        require(id >= 0 && id != mutable.value.user?.path("id")?.asLong(-1)) {
            "Choose another user's profile."
        }
        val active = session
        safety.block(id, blocked)
        changed()
        if (active == null) return
        action {
            try {
                val user =
                    org.taggr.android.data.synchronizeUserBlock(
                        id,
                        blocked,
                        read = { api.currentUser() ?: error("Create your TAGGR account first.") },
                        toggle = {
                            api.update("toggle_blacklist", listOf(id))
                            Unit
                        },
                        checkOwner = { require(session === active) { "The account changed." } },
                    )
                safety.remoteUser(user)
                mutable.value =
                    mutable.value.copy(
                        user = user,
                        notice = if (blocked) "User blocked." else "User unblocked.",
                    )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw IllegalStateException(
                    "Your choice is saved on this device. The server result is unavailable; refresh your account before trying again.",
                    e,
                )
            }
        }
    }

    fun report(user: Long, post: Long?, reason: String, id: String, completed: () -> Unit) =
        action {
            safety.report(id, user, post, reason)
            mutable.value = mutable.value.copy(notice = "Report received.")
            completed()
        }

    fun dismissMessage() {
        mutable.value = mutable.value.copy(error = null, notice = null)
    }

    fun checkSessionExpiry() {
        val active = session ?: return
        if (
            org.taggr.android.data.sessionRemainingMillis(
                active.expiration(),
                System.currentTimeMillis(),
            ) == 0L
        )
            action {}
    }

    private suspend fun expireSession(expected: AuthSession) {
        if (session !== expected) return
        // Detach immediately, but keep drafts and all pending outcome records for the same owner.
        install(null)
        mutable.value =
            mutable.value.copy(error = org.taggr.android.data.SessionExpiredException().message)
        try {
            withContext(Dispatchers.IO) { store.clear() }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (e: Exception) {
            mutable.value =
                mutable.value.copy(
                    error =
                        "Session expired. Saved credentials could not be cleared. Sign in again. ${e.message}"
                )
        }
    }

    private fun action(checkExpiry: Boolean = true, operation: suspend () -> Unit) {
        if (mutable.value.busy || mutable.value.restoring) return
        mutable.value = mutable.value.copy(busy = true, error = null, notice = null)
        viewModelScope.launch {
            try {
                val active = session
                if (
                    checkExpiry &&
                        active != null &&
                        org.taggr.android.data.sessionRemainingMillis(
                            active.expiration(),
                            System.currentTimeMillis(),
                        ) == 0L
                ) {
                    expireSession(active)
                    throw org.taggr.android.data.SessionExpiredException()
                }
                operation()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error !is Exception && error !is org.ic4j.agent.AgentError) throw error
                mutable.value =
                    mutable.value.copy(
                        error =
                            error.message
                                ?: "Action failed. Check your account before trying again."
                    )
            } finally {
                mutable.value = mutable.value.copy(busy = false)
            }
        }
    }

    override fun onCleared() {
        expiryJob?.cancel()
        session?.close()
        org.taggr.android.data.closeNetworkResources(api, client)
        super.onCleared()
    }
}
