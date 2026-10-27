import Foundation
import Security
import ICNativeClient

enum TaggrRetirementError: Error { case notApplied }

extension TaggrAppCoordinator {
    var retirementKey: String { "taggr.retirement.v1:\(runtimeConfig.apiBaseURL.absoluteString):\(runtimeConfig.canisterId):\(authSession?.principal ?? "guest")" }
    var retirementStage: String? {
        _ = retirementRevision
        return authSession == nil ? nil : retirementDefaults.string(forKey: retirementKey)
    }
    var accountRetired: Bool { authSession != nil && (retirementBusy || retirementStage != nil || currentUser?.deactivated == true) }

    var retirementStatusTitle: String {
        switch retirementStage {
        case "cleanup": return "Account stopped"
        case "confirmed": return "Stop response received"
        case "uncertain": return "Waiting for stop confirmation"
        case "preparing": return "Preparing account deletion"
        default: return currentUser?.deactivated == true ? "Account stopped" : "Deletion in progress"
        }
    }

    var retirementStatusDetail: String {
        switch retirementStage {
        case "cleanup": return "The account was confirmed stopped. Only removal of credentials and cached content from this device remains."
        case "confirmed": return "The stop response was received. Check the account state to finish. The stop request will not be sent again."
        case "uncertain": return "The stop result is unknown. You can check the account state, recover assets or sign out. Confirmation may remain unavailable; the stop request will not be sent again."
        case "preparing": return "Profile cleanup is not complete or the stop request was rejected. Some profile fields may already be empty. You can retry preparation."
        default: return "SNS actions and reactivation are unavailable in iOS. Names, images and DAO records may remain."
        }
    }

    var retirementActionTitle: String {
        switch retirementStage {
        case "preparing": return "Retry preparation"
        case "cleanup": return "Finish on this device"
        default: return "Check status"
        }
    }

    func saveRetirementStage(_ stage: String, key: String) throws {
        retirementDefaults.set(stage, forKey: key)
        retirementRevision += 1
        guard retirementDefaults.synchronize() else { throw TaggrAPIError.rejected("Could not save deletion progress. No new stop request was sent.") }
    }

    static func retirementSeed() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TaggrAPIError.rejected("Could not generate a random key.")
        }
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func retireAccount() async {
        guard !retirementBusy, !isBusy, let identity = authSession else { return }
        guard postSubmissionTasks.isEmpty else {
            retirementMessage = "Wait for pending post submissions before deleting the account."
            return
        }
        let generation = runtimeGeneration
        let key = retirementKey
        let activeAPI = api
        let store = identityStore
        func valid() -> Bool { runtimeGeneration == generation && authSession?.principal == identity.principal }
        retirementBusy = true
        retirementMessage = nil
        defer { retirementBusy = false }
        await activeAPI.restrictSNS(identity.principal, restricted: true)
        guard valid() else { return }
        do {
            // A confirmed stop needs only local cleanup, even when offline.
            if retirementStage == "cleanup" {
                try finishRetirement(key: key, store: store)
                return
            }
            let user = try await activeAPI.featureUser(identity: identity)
            guard valid() else { return }
            currentUser = user
            if user.deactivated == true {
                if retirementStage == "uncertain" || retirementStage == "confirmed" {
                    try finishRetirement(key: key, store: store)
                } else {
                    retirementMessage = "This account was already stopped. No encryption or key disposal was performed."
                }
                return
            }
            if retirementStage == "uncertain" || retirementStage == "confirmed" {
                retirementMessage = "The stop request is not confirmed. It will not be sent again. Check status later."
                return
            }
            guard let config = try await activeAPI.query("config", as: TaggrConfig.self),
                  let cost = config.accountActivationCost, cost >= 0, let credits = user.cycles else {
                throw TaggrAPIError.rejected("Could not verify the required credits. Nothing was changed.")
            }
            guard valid() else { return }
            if let displayedCost = cache?.config?.accountActivationCost, displayedCost != cost {
                cache = TaggrBackendCache(stats: cache?.stats, config: config)
                throw TaggrAPIError.rejected("The required cost changed to \(cost) credits. Review it before trying again.")
            }
            guard credits >= cost else { throw TaggrAPIError.rejected("Stopping requires \(cost) credits; this account has \(credits). Nothing was changed.") }
            try saveRetirementStage("preparing", key: key)
            try await activeAPI.clearRetirementProfile(user, identity: identity)
            guard valid() else { return }
            try await activeAPI.clearRetirementLinks(user, identity: identity)
            guard valid() else { return }
            var seed = try Self.retirementSeed()
            defer { seed = "" }
            try Task.checkCancellation()
            try saveRetirementStage("uncertain", key: key)
            do {
                try await activeAPI.stopForRetirement(seed: seed, identity: identity)
            } catch TaggrRetirementError.notApplied {
                try saveRetirementStage("preparing", key: key)
                if valid() { retirementMessage = "The backend rejected the stop request. Profile fields were cleared. You may retry." }
                return
            } catch {
                // Never log the underlying error: a server error could echo request arguments.
                if valid() { retirementMessage = "The stop request could not be confirmed. Profile fields were cleared. Check status; the request will not be resent." }
                return
            }
            try saveRetirementStage("confirmed", key: key)
            guard valid() else { return }
            let stopped = try await activeAPI.featureUser(identity: identity)
            guard valid() else { return }
            currentUser = stopped
            guard stopped.deactivated == true else {
                retirementMessage = "The stop response was received. Waiting for the account state to confirm it."
                return
            }
            try finishRetirement(key: key, store: store)
        } catch {
            guard valid() else { return }
            switch retirementStage {
            case "cleanup":
                retirementMessage = "The account is stopped, but this device could not finish removing credentials. Retry device cleanup; no stop request will be sent."
            case "uncertain", "confirmed":
                retirementMessage = "Could not confirm the account state. Check status later; the stop request will not be resent."
            case "preparing":
                retirementMessage = "Could not finish preparation. Profile fields may already have been cleared. You may retry preparation."
            default:
                retirementMessage = error.localizedDescription
            }
        }
        if valid() { await activeAPI.restrictSNS(identity.principal, restricted: retirementStage != nil || currentUser?.deactivated == true) }
    }

    private func finishRetirement(key: String, store: ICIdentityStore) throws {
        try saveRetirementStage("cleanup", key: key)
        try store.clear()
        userRefreshTask?.cancel()
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        runtimeGeneration += 1
        feed = []
        repliesByPostID = [:]
        focusedPost = nil
        postThread = []
        profile = nil
        contentStore.profilePosts = []
        featurePosts.reset()
        clearAuthorNameCache()
        URLCache.shared.removeAllCachedResponses()
        signOut()
        route = .settings
        retirementCompleted = true
    }
}
