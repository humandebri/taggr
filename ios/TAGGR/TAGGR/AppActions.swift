import AuthenticationServices
import Foundation
import ICNativeClient
import SwiftUI

enum TaggrPostSubmissionOutcome: Equatable {
    case submitted
    case retryableFailure
    case uncertain
}

extension TaggrAppCoordinator {
    func submitPost(text: String, parent: Int? = nil, realm: String? = nil, images: [TaggrDraftImage] = [], reloadMode: TaggrFeedMode? = nil) async -> TaggrPostSubmissionOutcome {
        let operationID = UUID()
        activeOperationIDs.insert(operationID)
        latestOperationID = operationID
        isBusy = !activeOperationIDs.isEmpty
        errorMessage = nil
        defer {
            activeOperationIDs.remove(operationID)
            isBusy = !activeOperationIDs.isEmpty
        }
        do {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let refs = try await uploadBlobs(referencedNewBlobs(in: body, draftImages: images, existingBlobIDs: []))
            let postingScope = realmPostingScope
            do {
                _ = try await api.addPost(text: body, refs: refs, parent: parent, realm: realm, identity: authSession)
            } catch {
                guard !isCancellation(error) else { return .retryableFailure }
                errorMessage = error.localizedDescription
                return isUncertainPostSubmissionError(error) ? .uncertain : .retryableFailure
            }
            if parent == nil, let postingScope {
                realmPostingPreferences.record(destination: realm, scope: postingScope)
            }
            if let parent {
                repliesByPostID[parent] = nil
                await updateCurrentUserIfPossible()
                await loadCurrentRoute()
                await refreshReplyThread(postID: parent)
            } else {
                await updateCurrentUserIfPossible()
                await reloadAfterRootPost(mode: reloadMode)
                refreshLoadedProfileAfterOwnPost()
            }
            errorMessage = nil
            return .submitted
        } catch {
            guard !isCancellation(error) else { return .retryableFailure }
            errorMessage = error.localizedDescription
            return .retryableFailure
        }
    }

    func postCreditCost(for body: String, editing post: TaggrPost? = nil) async -> Int? {
        guard let config = cache?.config,
              let baseCost = config.postCost else {
            return nil
        }
        let maxTagLength = config.maxTagLength ?? TaggrPostCreditCost.defaultMaxTagLength
        let tags = TaggrPostCreditCost.tags(in: body, maxLength: maxTagLength)
        let tagCost: Int
        if let cached = tagCostCache[tags] {
            tagCost = cached
        } else {
            tagCostRequestSequence += 1
            let requestSequence = tagCostRequestSequence
            let generation = runtimeGeneration
            let activeAPI = api
            tagCostTask?.cancel()
            let requestTask = Task {
                try await activeAPI.tagsCost(tags)
            }
            tagCostTask = requestTask
            do {
                tagCost = try await requestTask.value
                guard requestSequence == tagCostRequestSequence,
                      generation == runtimeGeneration,
                      !Task.isCancelled else {
                    return nil
                }
                tagCostCache[tags] = tagCost
            } catch {
                guard requestSequence == tagCostRequestSequence,
                      generation == runtimeGeneration,
                      !isCancellation(error) else {
                    return nil
                }
                guard post == nil else { return nil }
                tagCost = 0
            }
            if requestSequence == tagCostRequestSequence {
                tagCostTask = nil
            }
        }
        if let post {
            return TaggrPostCreditCost.estimateEdit(
                body: body,
                post: post,
                baseCost: baseCost,
                tagCost: tagCost,
                pollCost: config.pollCost
            )
        }
        return TaggrPostCreditCost.estimate(body: body, baseCost: baseCost, tagCost: tagCost)
    }

    private func isUncertainPostSubmissionError(_ error: Error) -> Bool {
        guard let error = error as? TaggrAPIError else { return true }
        switch error {
        case .pollTimeout, .backendUnavailable, .emptyResponse, .invalidResponse:
            return true
        case .invalidCanisterId, .invalidIdentity, .missingIdentity, .rejected:
            return false
        }
    }

    func postingRealmColors(_ names: [String]) async -> [String: String] {
        guard !names.isEmpty else { return [:] }
        let generation = runtimeGeneration
        let activeAPI = api
        do {
            let values = try await activeAPI.query("realms", args: [names], as: [TaggrRealm].self) ?? []
            guard isCurrentRuntimeGeneration(generation) else { return [:] }
            return values.enumerated().reduce(into: [String: String]()) { colors, entry in
                let (index, realm) = entry
                guard let color = realm.labelColor else { return }
                let name = realm.name.isEmpty && names.indices.contains(index) ? names[index] : realm.name
                guard !name.isEmpty else { return }
                colors[name.uppercased()] = color
            }
        } catch {
            guard !isCancellation(error) else { return [:] }
            NSLog("TAGGR posting realm metadata refresh failed: %@", error.localizedDescription)
            return [:]
        }
    }

    func editPost(post: TaggrPost, text: String, realm: String?, images: [TaggrDraftImage] = [], reloadMode: TaggrFeedMode? = nil) async {
        await runBusy {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let refs = try await uploadBlobs(referencedNewBlobs(in: body, draftImages: images, existingBlobIDs: Self.blobIDs(in: post.files)))
            let patch = TaggrEditPatch.fullReplacement(from: body, to: post.body)
            _ = try await api.editPost(id: post.id, text: body, refs: refs, patch: patch, realm: realm, identity: authSession)
            await updateCurrentUserIfPossible()
            await loadCurrentRoute()
        }
    }

    func repost(postId: Int, text: String, realm: String?) async {
        await runBusy {
            _ = try await api.repost(
                postId: postId,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                realm: realm,
                identity: authSession
            )
            await updateCurrentUserIfPossible()
            await loadCurrentRoute()
        }
    }

    func react(postId: Int, reaction: Int) async {
        let previousFeed = feed
        let previousFocusedPost = focusedPost
        let previousReplies = repliesByPostID
        applyOptimisticReaction(postId: postId, reaction: reaction)
        let succeeded = await runBusy {
            _ = try await api.updateJSON("react", args: [postId, reaction], identity: authSession)
            await updateCurrentUserIfPossible()
            await loadCurrentRoute()
        }
        if !succeeded {
            feed = previousFeed
            focusedPost = previousFocusedPost
            repliesByPostID = previousReplies
        }
    }

    func report(userId: Int, reason: String) async {
        await runBusy {
            _ = try await api.updateJSON("report", args: [userId, reason], identity: authSession)
        }
    }

    func voteOnPoll(postId: Int, option: Int, anonymously: Bool) async {
        let previousFeed = feed
        let previousFocusedPost = focusedPost
        let previousReplies = repliesByPostID
        if let userId = currentUser?.id {
            updatePost(postId) { post in
                guard case .poll(let poll) = post.extensionKind else { return post }
                return post.replacingExtension(.poll(poll.voting(option: option, userId: userId, anonymously: anonymously)))
            }
        }
        let succeeded = await runBusy {
            _ = try await api.updateJSON("vote_on_poll", args: [postId, option, anonymously], identity: authSession)
            await loadCurrentRoute()
        }
        if !succeeded {
            feed = previousFeed
            focusedPost = previousFocusedPost
            repliesByPostID = previousReplies
        }
    }

    func toggleHide(postId: Int) async {
        guard let userId = currentUser?.id else { return }
        let previousFeed = feed
        let previousFocusedPost = focusedPost
        let previousReplies = repliesByPostID
        updatePost(postId) { post in
            var hidden = post.hiddenFor
            if hidden.contains(userId) {
                hidden.removeAll { $0 == userId }
            } else {
                hidden.append(userId)
            }
            return post.updatingHiddenFor(hidden)
        }
        let succeeded = await runBusy {
            _ = try await api.updateJSON("toggle_hide_post", args: [postId], identity: authSession)
        }
        if !succeeded {
            feed = previousFeed
            focusedPost = previousFocusedPost
            repliesByPostID = previousReplies
        }
    }

    func togglePinnedPost(postId: Int) async {
        await runBusy {
            _ = try await api.updateJSON("toggle_pinned_post", args: [postId], identity: authSession)
            await updateCurrentUserIfPossible()
        }
    }

    func deletePost(_ post: TaggrPost) async {
        await runBusy {
            let versions = try post.deletionVersions()
            _ = try await api.updateJSON("delete_post", args: [post.id, versions], identity: authSession)
            await loadCurrentRoute()
        }
    }

    func loadEmbeddedPost(_ id: Int) async -> TaggrPost? {
        do {
            return try await loadPostEnvelopes("posts", args: [[id]], identity: nil).first
        } catch {
            guard !isCancellation(error) else { return nil }
            NSLog("TAGGR embedded post load failed: %@", error.localizedDescription)
            return nil
        }
    }

    func toggleBookmark(postId: Int) async {
        await runBusy {
            _ = try await api.toggleBookmark(postId: postId, identity: authSession)
            await updateCurrentUserIfPossible()
            await loadCurrentRoute()
        }
    }

    func toggleFollowingPost(postId: Int) async {
        await runBusy {
            _ = try await api.toggleFollowingPost(postId: postId, identity: authSession)
            await updateCurrentUserIfPossible()
            await loadCurrentRoute()
        }
    }

    func toggleBlock(userId: Int) async {
        await runBusy {
            _ = try await api.updateJSON("toggle_blacklist", args: [userId], identity: authSession)
            await updateCurrentUserIfPossible()
            if case .profile(let handle) = route {
                profile = try await api.query("user", args: [api.domain, [handle]], as: TaggrUser.self)
            }
        }
    }

    @discardableResult
    func createUser(name: String, invite: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInvite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "User name is required."
            return false
        }
        return await runBusy {
            _ = try await api.createUser(name: trimmedName, invite: trimmedInvite, identity: authSession)
            icpInvoice = nil
            try await loadCurrentUserIfNeeded()
            await reloadCache()
            await loadCurrentRoute()
        }
    }

    func checkICPInvoice() async {
        await runBusy {
            icpInvoice = try await api.mintCreditsWithICP(kiloCredits: 0, identity: authSession)
        }
    }

    func refreshWallet() async {
        await runBusy {
            try await loadCurrentUserIfNeeded()
            if let principal = currentUser?.principal ?? authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            } else {
                icpBalanceE8s = nil
            }
        }
    }

    func prepareCreditMint() async {
        await runBusy {
            icpInvoice = try await api.mintCreditsWithICP(kiloCredits: 0, identity: authSession)
        }
    }

    func payICPInvoice() async {
        await runBusy {
            let invoice: TaggrICPInvoice
            if let currentInvoice = icpInvoice {
                invoice = currentInvoice
            } else {
                invoice = try await api.mintCreditsWithICP(kiloCredits: 0, identity: authSession)
            }
            if !invoice.paid {
                _ = try await api.transferICP(
                    to: invoice.accountHex,
                    e8s: invoice.e8s,
                    identity: authSession
                )
            }
            let paidInvoice = try await api.mintCreditsWithICP(kiloCredits: 0, identity: authSession)
            guard paidInvoice.paid else {
                throw TaggrAPIError.rejected("ICP invoice payment was not confirmed.")
            }
            icpInvoice = paidInvoice
        }
    }

    func mintOneKCredits() async {
        await runBusy {
            let invoice: TaggrICPInvoice
            if let currentInvoice = icpInvoice {
                invoice = currentInvoice
            } else {
                invoice = try await api.mintCreditsWithICP(kiloCredits: 0, identity: authSession)
            }
            if !invoice.paid {
                _ = try await api.transferICP(
                    to: invoice.accountHex,
                    e8s: invoice.e8s,
                    identity: authSession
                )
            }
            let paidInvoice = try await api.mintCreditsWithICP(kiloCredits: 1, identity: authSession)
            guard paidInvoice.paid else {
                throw TaggrAPIError.rejected("ICP credit payment was not confirmed.")
            }
            icpInvoice = nil
            try await loadCurrentUserIfNeeded()
            if let principal = currentUser?.principal ?? authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            }
        }
    }

    func sendICP(to recipient: String, amountE8s: UInt64) async {
        await runBusy {
            guard amountE8s > 0 else {
                throw TaggrAPIError.rejected("Enter a positive ICP amount.")
            }
            _ = try await api.transferICP(to: recipient, e8s: amountE8s, identity: authSession)
            if let principal = currentUser?.principal ?? authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            }
        }
    }

    func withdrawRewards() async {
        await runBusy {
            _ = try await api.updateJSON("withdraw_rewards", identity: authSession)
            try await loadCurrentUserIfNeeded()
            if let principal = currentUser?.principal ?? authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            }
        }
    }

    var storageNeedsUpgrade: Bool {
        guard let expected = storageExpectedWasmHash?.lowercased(),
              let actual = storageStatus?.moduleHash?.icHexString.lowercased(),
              !expected.isEmpty else {
            return false
        }
        return expected != actual
    }

    func loadStorageStatus() async {
        await runBusy {
            guard let authSession else { throw TaggrAPIError.missingIdentity }
            try await loadCurrentUserIfNeeded()
            storageCreationState = Self.storageCreationState(from: currentUser?.settings)
            storageExpectedWasmHash = try await api.bucketWasmHash()
            guard let bucket = currentUser?.bucket, !bucket.isEmpty else {
                storageStatus = nil
                return
            }
            storageStatus = try await api.storageCanisterStatus(bucket, identity: authSession)
        }
    }

    func createStorageCanister() async {
        await runBusy {
            guard let authSession else { throw TaggrAPIError.missingIdentity }
            try await loadCurrentUserIfNeeded()
            guard let principal = currentUser?.principal ?? self.authSession?.principal else {
                throw TaggrAPIError.rejected("Sign in before creating storage.")
            }
            if let bucket = currentUser?.bucket, !bucket.isEmpty {
                storageStatus = try await api.storageCanisterStatus(bucket, identity: authSession)
                return
            }
            let creationE8s = cache?.stats?.e8sForOneXdr
            guard let creationE8s, creationE8s > ICPAmount.feeE8s else {
                throw TaggrAPIError.rejected("Backend stats do not include the storage creation price.")
            }

            var creation = Self.storageCreationState(from: currentUser?.settings)
                ?? TaggrStorageCreationState(stage: .transferring, blockIndex: nil, canisterId: nil)
            storageCreationState = creation

            if creation.blockIndex == nil {
                let account = try ICPAccountIdentifier.account(
                    for: TaggrAPI.cmcCanisterId,
                    subaccountPrincipal: principal
                )
                let blockIndex = try await api.transferICP(
                    toAccount: account,
                    e8s: creationE8s,
                    memo: TaggrAPI.memoCreateCanister,
                    identity: authSession
                )
                creation = TaggrStorageCreationState(stage: .transferred, blockIndex: blockIndex, canisterId: nil)
                try await saveStorageCreationState(creation)
            }

            if creation.canisterId == nil {
                creation.stage = .creating
                storageCreationState = creation
                let canisterId = try await api.notifyCreateCanister(
                    blockIndex: creation.blockIndex ?? 0,
                    controller: principal,
                    identity: authSession
                )
                creation = TaggrStorageCreationState(stage: .created, blockIndex: creation.blockIndex, canisterId: canisterId)
                try await saveStorageCreationState(creation)
            }

            guard let canisterId = creation.canisterId else {
                throw TaggrAPIError.invalidResponse("Storage canister id missing after creation.")
            }
            if creation.stage == .created {
                let createdState = creation
                creation.stage = .installing
                storageCreationState = creation
                do {
                    let wasm = try await api.bucketWasm()
                    try await api.installBucketCode(
                        canisterId: canisterId,
                        wasm: wasm,
                        userPrincipal: principal,
                        mode: "install",
                        identity: authSession
                    )
                } catch {
                    storageCreationState = createdState
                    throw error
                }
                creation.stage = .installed
                try await saveStorageCreationState(creation)
            }

            let installedState = creation
            creation.stage = .registering
            storageCreationState = creation
            do {
                try await api.setBucket(canisterId, identity: authSession)
            } catch {
                storageCreationState = installedState
                throw error
            }
            try await clearStorageCreationState()
            try await loadCurrentUserIfNeeded()
            storageExpectedWasmHash = try await api.bucketWasmHash()
            storageStatus = try await api.storageCanisterStatus(canisterId, identity: authSession)
            if let principal = currentUser?.principal ?? self.authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            }
        }
    }

    func topUpStorageCanister(amountE8s: UInt64) async {
        await runBusy {
            guard let authSession else { throw TaggrAPIError.missingIdentity }
            guard amountE8s > ICPAmount.feeE8s else {
                throw TaggrAPIError.rejected("Enter an ICP amount greater than the ledger fee.")
            }
            guard let bucket = currentUser?.bucket, !bucket.isEmpty else {
                throw TaggrAPIError.rejected("Create storage before topping up.")
            }
            let account = try ICPAccountIdentifier.account(
                for: TaggrAPI.cmcCanisterId,
                subaccountPrincipal: bucket
            )
            let blockIndex = try await api.transferICP(
                toAccount: account,
                e8s: amountE8s,
                memo: TaggrAPI.memoTopUpCanister,
                identity: authSession
            )
            _ = try await api.notifyTopUp(blockIndex: blockIndex, canisterId: bucket, identity: authSession)
            storageStatus = try await api.storageCanisterStatus(bucket, identity: authSession)
            if let principal = currentUser?.principal ?? self.authSession?.principal {
                icpBalanceE8s = try await api.icpAccountBalance(ownerPrincipal: principal)
            }
        }
    }

    func upgradeStorageCanister() async {
        await runBusy {
            guard let authSession else { throw TaggrAPIError.missingIdentity }
            guard let principal = currentUser?.principal ?? self.authSession?.principal else {
                throw TaggrAPIError.missingIdentity
            }
            guard let bucket = currentUser?.bucket, !bucket.isEmpty else {
                throw TaggrAPIError.rejected("Create storage before upgrading.")
            }
            let wasm = try await api.bucketWasm()
            try await api.installBucketCode(
                canisterId: bucket,
                wasm: wasm,
                userPrincipal: principal,
                mode: "upgrade",
                identity: authSession
            )
            storageExpectedWasmHash = try await api.bucketWasmHash()
            storageStatus = try await api.storageCanisterStatus(bucket, identity: authSession)
        }
    }

    func addBlackholeStorageController() async {
        await runBusy {
            guard let authSession else { throw TaggrAPIError.missingIdentity }
            guard let bucket = currentUser?.bucket, !bucket.isEmpty else {
                throw TaggrAPIError.rejected("Create storage before updating controllers.")
            }
            let status = try await api.storageCanisterStatus(bucket, identity: authSession)
            var controllers = status.controllers
            if !controllers.contains(TaggrAPI.blackholeCanisterId) {
                controllers.append(TaggrAPI.blackholeCanisterId)
            }
            try await api.updateStorageControllers(canisterId: bucket, controllers: controllers, identity: authSession)
            let refreshed = try await api.storageCanisterStatus(bucket, identity: authSession)
            guard refreshed.controllers.contains(TaggrAPI.blackholeCanisterId) else {
                throw TaggrAPIError.rejected("Blackhole controller was not added.")
            }
            storageStatus = refreshed
        }
    }

    func startIdentitySignIn() {
        startIdentitySignIn(reason: nil)
    }

    func startIdentitySignIn(reason: String?) {
        guard !isAuthenticatingIdentity else { return }
        isAuthenticatingIdentity = true
        errorMessage = reason
        Task {
            do {
                let session = try await identityAuthenticator.authenticate()
                await completeIdentity(session)
            } catch {
                if !isCancellation(error) {
                    errorMessage = error.localizedDescription
                }
            }
            isAuthenticatingIdentity = false
        }
    }

    func completeIdentity(_ session: ICAuthSession) async {
        await runBusy {
            // This signed canister query is the practical verifier before the II delegation is saved.
            currentUser = try await api.signedQuery("user", args: [api.domain, []], identity: session, as: Optional<TaggrUser>.self) ?? nil
            if let currentUser {
                cacheAuthorName(currentUser.name, userID: currentUser.id)
            }
            try identityStore.save(session)
            authSession = session
            await reloadCache()
            await loadCurrentRoute()
        }
    }

    func signOut() {
        do {
            try identityStore.clear()
        } catch {
            NSLog("TAGGR identity session could not be cleared: %@", error.localizedDescription)
        }
        authSession = nil
        currentUser = nil
        icpBalanceE8s = nil
        icpInvoice = nil
        profile = nil
        focusedPost = nil
        clearAuthorNameCache()
        if case .feed(.personal) = route {
            feed = []
        }
    }

    @discardableResult
    func runBusy(
        validWhile isValid: () -> Bool = { true },
        _ operation: () async throws -> Void
    ) async -> Bool {
        let operationID = UUID()
        activeOperationIDs.insert(operationID)
        latestOperationID = operationID
        isBusy = !activeOperationIDs.isEmpty
        errorMessage = nil
        defer {
            activeOperationIDs.remove(operationID)
            isBusy = !activeOperationIDs.isEmpty
        }
        do {
            try await operation()
            return true
        } catch {
            guard !isCancellation(error) else {
                return false
            }
            NSLog("TAGGR operation failed: %@", error.localizedDescription)
            if latestOperationID == operationID, isValid() {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func markLocalNotificationsRead(_ ids: [Int]) {
        guard let user = currentUser else { return }
        var notifications = user.notifications
        for id in ids {
            guard let entry = notifications[id] else { continue }
            notifications[id] = TaggrNotificationEntry(notification: entry.notification, read: true)
        }
        currentUser = user.updatingNotifications(notifications)
    }

    func uploadBlobs(_ blobs: [(id: String, data: Data)]) async throws -> [TaggrCandid.FileRef] {
        guard !blobs.isEmpty else { return [] }
        guard let authSession else {
            throw TaggrAPIError.missingIdentity
        }
        guard let bucket = currentUser?.bucket, !bucket.isEmpty else {
            throw TaggrAPIError.rejected("No personal media bucket configured. Set one up under Settings > Storage.")
        }
        // Bucket updates are serialized by the canister, but several requests can be
        // in flight while the client waits for their certificates. Keep the window
        // bounded so a large photo selection does not monopolize the connection.
        let maxConcurrentUploads = 4
        let activeAPI = api
        let activeSession = authSession
        let indexedRefs = try await withThrowingTaskGroup(
            of: (Int, TaggrCandid.FileRef).self,
            returning: [(Int, TaggrCandid.FileRef)].self
        ) { group in
            var nextIndex = 0

            func submit(_ index: Int) {
                let blob = blobs[index]
                group.addTask {
                    let offset = try await activeAPI.bucketWrite(
                        bucketId: bucket,
                        blob: blob.data,
                        identity: activeSession
                    )
                    return (
                        index,
                        (id: blob.id, offset: offset, length: UInt64(blob.data.count))
                    )
                }
            }

            for _ in 0..<min(maxConcurrentUploads, blobs.count) {
                submit(nextIndex)
                nextIndex += 1
            }

            var results: [(Int, TaggrCandid.FileRef)] = []
            results.reserveCapacity(blobs.count)
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < blobs.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }

        return indexedRefs
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    func referencedNewBlobs(
        in body: String,
        draftImages: [TaggrDraftImage],
        existingBlobIDs: Set<String>
    ) throws -> [(id: String, data: Data)] {
        guard draftImages.allSatisfy({ body.contains($0.markdown) }) else {
            throw TaggrAPIError.rejected("Attached image marker was edited. Remove and attach the image again.")
        }
        let referencedIDs = Self.blobIDs(inMarkdown: body)
        var refs: [(id: String, data: Data)] = []
        var seen = Set<String>()

        for id in referencedIDs where !seen.contains(id) {
            seen.insert(id)
            if let draft = draftImages.first(where: { $0.id == id }) {
                refs.append((id: draft.id, data: draft.data))
            } else if !existingBlobIDs.contains(id) {
                throw TaggrAPIError.rejected("You're referencing pictures that are not attached anymore. Please re-upload.")
            }
        }

        return refs
    }

    static func blobIDs(in files: [String: [LosslessInt]]) -> Set<String> {
        Set(files.keys.compactMap { $0.split(separator: "@").first.map(String.init) })
    }

    static func blobIDs(inMarkdown text: String) -> [String] {
        let pattern = #"!\[[^\]]*\]\(/blob/([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let idRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[idRange])
        }
    }

    func refreshCurrentUser() async {
        let generation = runtimeGeneration
        let activeAPI = api
        await runBusy {
            try await loadCurrentUserIfNeeded(generation: generation, api: activeAPI)
        }
    }

    func loadCurrentUserIfNeeded(generation: Int? = nil, api activeAPI: TaggrAPI? = nil) async throws {
        let generation = generation ?? runtimeGeneration
        let activeAPI = activeAPI ?? api
        guard let authSession else {
            guard isCurrentRuntimeGeneration(generation) else { return }
            currentUser = nil
            return
        }
        let loadedUser = try await activeAPI.signedQuery("user", args: [activeAPI.domain, []], identity: authSession, as: Optional<TaggrUser>.self) ?? nil
        guard isCurrentRuntimeGeneration(generation) else { return }
        currentUser = loadedUser
        storageCreationState = Self.storageCreationState(from: loadedUser?.settings)
        if let loadedUser {
            cacheAuthorName(loadedUser.name, userID: loadedUser.id)
        }
    }

    func updateCurrentUserIfPossible() async {
        let generation = runtimeGeneration
        let activeAPI = api
        do {
            try await loadCurrentUserIfNeeded(generation: generation, api: activeAPI)
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            NSLog("TAGGR current user refresh failed: %@", error.localizedDescription)
        }
    }

    func setRealmMembership(name: String, joined: Bool) async -> Bool {
        let normalized = normalizedRealmName(name)
        guard !normalized.isEmpty, realmMembershipOperation == nil else { return false }
        guard authSession != nil, currentUser != nil else {
            errorMessage = TaggrAPIError.signInRequiredMessage
            return false
        }
        let isJoined = currentUser?.realms.contains {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        } == true
        guard isJoined != joined else { return true }

        realmMembershipOperation = normalized
        defer { realmMembershipOperation = nil }
        return await runBusy {
            try await api.setRealmMembership(name: normalized, joined: joined, identity: authSession)
            try await loadCurrentUserIfNeeded()
            let refreshedMembership = currentUser?.realms.contains {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            } == true
            guard refreshedMembership == joined else {
                throw TaggrAPIError.invalidResponse("Realm membership did not refresh to the requested state")
            }
            try await refreshRealmMetadata(normalized)
        }
    }

    func isJoinedRealm(_ name: String) -> Bool {
        currentUser?.realms.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        } == true
    }

    func canManageRealm(_ name: String) -> Bool {
        currentUser?.controlledRealms.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        } == true
    }

    func saveRealmSettings(_ draft: TaggrRealmSettingsDraft, realm: TaggrRealm) async -> Bool {
        await runBusy {
            guard canManageRealm(realm.name) else {
                throw TaggrAPIError.rejected("You are not a controller of this realm.")
            }
            let payload = try draft.payload(
                for: realm,
                maxCleanupPenalty: cache?.config?.maxRealmCleanupPenalty,
                maxLogoLength: cache?.config?.maxRealmLogoLen
            )
            try await api.editRealm(name: realm.name, payload: payload, identity: authSession)
            try await refreshRealmMetadata(realm.name)
        }
    }

    func refreshRealmMetadata(_ name: String) async throws {
        let generation = runtimeGeneration
        let activeAPI = api
        let values = try await activeAPI.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
        guard isCurrentRuntimeGeneration(generation), let realm = values.first else {
            throw TaggrAPIError.invalidResponse("Realm metadata was not returned")
        }
        let refreshed = realm.renamed(realm.name.isEmpty ? name : realm.name)
        if let index = realms.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            realms[index] = refreshed
        } else {
            realms = [refreshed]
        }
    }

    func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let authError = error as? ASWebAuthenticationSessionError {
            return authError.code == .canceledLogin
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    func saveStorageCreationState(_ state: TaggrStorageCreationState) async throws {
        guard var settings = currentUser?.settings else {
            throw TaggrAPIError.rejected("Create a TAGGR user before creating storage.")
        }
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TaggrAPIError.invalidResponse("Storage creation state could not be encoded.")
        }
        settings[TaggrStorageCreationState.settingKey] = json
        _ = try await api.updateJSON("update_user_settings", args: [settings], identity: authSession)
        currentUser = currentUser?.updatingSettings(settings)
        storageCreationState = state
    }

    func clearStorageCreationState() async throws {
        guard var settings = currentUser?.settings else { return }
        settings.removeValue(forKey: TaggrStorageCreationState.settingKey)
        _ = try await api.updateJSON("update_user_settings", args: [settings], identity: authSession)
        currentUser = currentUser?.updatingSettings(settings)
        storageCreationState = nil
    }

    static func storageCreationState(from settings: [String: String]?) -> TaggrStorageCreationState? {
        guard let rawValue = settings?[TaggrStorageCreationState.settingKey],
              let data = rawValue.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TaggrStorageCreationState.self, from: data)
    }

    func applyOptimisticReaction(postId: Int, reaction: Int) {
        guard let userId = currentUser?.id else { return }
        updatePost(postId) { $0.addingReaction(reaction, by: userId) }
    }

    func updatePost(_ postId: Int, transform: (TaggrPost) -> TaggrPost) {
        feed = feed.map { post in
            post.id == postId ? transform(post) : post
        }
        if focusedPost?.id == postId, let focusedPost {
            self.focusedPost = transform(focusedPost)
        }
        repliesByPostID = repliesByPostID.mapValues { posts in
            posts.map { post in
                post.id == postId ? transform(post) : post
            }
        }
    }

    func refreshLoadedProfileAfterOwnPost() {
        guard let currentUser, profile?.id == currentUser.id else { return }
        profile = currentUser
    }

    func reloadAfterRootPost(mode reloadMode: TaggrFeedMode?) async {
        switch route {
        case .feed(let mode):
            await loadFeed(mode: reloadMode ?? mode, reset: true)
        case .realm:
            await loadCurrentRoute()
        default:
            break
        }
    }

    func isCurrentRuntimeGeneration(_ generation: Int) -> Bool {
        generation == runtimeGeneration
    }

    func beginRequest(_ scope: RequestScope) -> RequestToken {
        requestTasks[scope]?.cancel()
        let sequence = (requestSequences[scope] ?? 0) + 1
        requestSequences[scope] = sequence
        return RequestToken(
            scope: scope,
            sequence: sequence,
            runtimeGeneration: runtimeGeneration,
            route: route
        )
    }

    func executeRequest(
        _ request: RequestToken,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let task = Task { await operation() }
        requestTasks[request.scope] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if requestSequences[request.scope] == request.sequence {
            requestTasks[request.scope] = nil
        }
    }

    func isCurrentRequest(_ request: RequestToken) -> Bool {
        !Task.isCancelled &&
            request.runtimeGeneration == runtimeGeneration &&
            requestSequences[request.scope] == request.sequence &&
            request.route == route
    }

    func loadAuthorNames(userIDs: [Int], generation: Int, api: TaggrAPI) async throws -> [Int: String] {
        let rows = try await api.query("users_data", args: [userIDs], as: [String: String].self) ?? [:]
        let names = rows.reduce(into: [Int: String]()) { partial, entry in
            guard let userID = Int(entry.key), !entry.value.isEmpty else { return }
            partial[userID] = entry.value
        }
        guard isCurrentRuntimeGeneration(generation) else { return names }
        for (userID, name) in names {
            cacheAuthorName(name, userID: userID)
        }
        return names
    }

    func cacheAuthorName(_ name: String, userID: Int) {
        authorNamesByUserID[userID] = name
        markAuthorNameCacheAccess(userID)
    }

    func markAuthorNameCacheAccess(_ userID: Int) {
        authorNameCacheOrder.removeAll { $0 == userID }
        authorNameCacheOrder.append(userID)
        trimAuthorNameCache()
    }

    func trimAuthorNameCache() {
        while authorNameCacheOrder.count > Self.maxAuthorNameCacheEntries {
            let evictedUserID = authorNameCacheOrder.removeFirst()
            authorNamesByUserID[evictedUserID] = nil
        }
    }

    func clearAuthorNameCache() {
        authorNamesByUserID.removeAll()
        authorNameCacheOrder.removeAll()
    }

    func normalizedRealmName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func loadPostEnvelopes(_ method: String, args: sending [Any?], identity: ICAuthSession?) async throws -> [TaggrPost] {
        try await loadPostEnvelopes(method, args: args, identity: identity, api: api)
    }

    func loadPostEnvelopes(_ method: String, args: sending [Any?], identity: ICAuthSession?, api activeAPI: TaggrAPI) async throws -> [TaggrPost] {
        let rows: [TaggrPostEnvelope]?
        if let identity {
            rows = try await activeAPI.signedQuery(method, args: args, identity: identity, as: [TaggrPostEnvelope].self)
        } else {
            rows = try await activeAPI.query(method, args: args, as: [TaggrPostEnvelope].self)
        }
        return (rows ?? []).map(\.post)
    }
}
