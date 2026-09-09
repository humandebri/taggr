import Foundation
import ICNativeClient

enum ProfileUpdateResult: Equatable {
    case applied
    case rejected
    case uncertain
}

extension TaggrAppCoordinator {
    func canInteractWithProfile(userID: Int) -> Bool {
        authSession != nil && currentUser != nil && currentUser?.id != userID
    }

    func isFollowingUser(_ userID: Int) -> Bool {
        currentUser?.followees.contains(userID) == true
    }

    func isMutedUser(_ userID: Int) -> Bool {
        currentUser?.filters.users.contains(userID) == true
    }

    @discardableResult
    func setFollowingUser(_ userID: Int, following: Bool) async -> ProfileUpdateResult {
        guard isFollowingUser(userID) != following else { return .applied }
        return await performProfileUserUpdate(userID: userID) { api, identity in
            let data = try await api.updateJSON("toggle_following_user", args: [userID], identity: identity)
            guard try JSONDecoder().decode(Bool.self, from: data) == following else {
                throw TaggrAPIError.invalidResponse("Follow status did not match the requested change. Refresh before trying again.")
            }
        }
    }

    @discardableResult
    func setMutedUser(_ userID: Int, muted: Bool) async -> ProfileUpdateResult {
        guard isMutedUser(userID) != muted else { return .applied }
        return await performProfileUserUpdate(userID: userID) { api, identity in
            let data = try await api.updateJSON("toggle_filter", args: ["user", String(userID)], identity: identity)
            try Self.validateProfileUpdateResult(data)
        }
    }

    func sendProfileCredits(userID: Int, amount: Int, expectedFee: Int) async -> ProfileUpdateResult {
        guard cache?.config?.creditTransactionFee == expectedFee,
              let balance = currentUser?.cycles,
              ProfileCreditAmount.total(amount: amount, fee: expectedFee, balance: balance) != nil else {
            errorMessage = "Check the amount, available credits, and current fee before sending."
            return .rejected
        }
        return await performProfileUserUpdate(userID: userID) { api, identity in
            let data = try await api.updateJSON("transfer_credits", args: [userID, amount], identity: identity)
            try Self.validateProfileUpdateResult(data)
        }
    }

    private static func validateProfileUpdateResult(_ data: Data) throws {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["Ok"] is NSNull else {
            throw TaggrAPIError.invalidResponse("The update response did not confirm success.")
        }
    }

    private func performProfileUserUpdate(
        userID: Int,
        operation: (TaggrAPI, ICAuthSession) async throws -> Void
    ) async -> ProfileUpdateResult {
        guard !contentStore.profileActionInFlight else { return .rejected }
        guard canInteractWithProfile(userID: userID), let identity = authSession else {
            errorMessage = "Sign in to interact with another user."
            return .rejected
        }
        let generation = runtimeGeneration
        let activeAPI = api
        let originalRoute = route
        let visibleProfileID = profile?.id
        contentStore.profileActionInFlight = true
        errorMessage = nil
        defer { contentStore.profileActionInFlight = false }
        var applied = false
        func isCurrentSession() -> Bool {
            runtimeGeneration == generation && authSession?.principal == identity.principal
        }
        do {
            try await operation(activeAPI, identity)
            applied = true
            guard isCurrentSession() else { return .applied }
            // A query started before the update must not restore the old follow/mute state.
            userRefreshTask?.cancel()
            userRefreshTask = nil
            userRefreshID = nil
            userRefreshKey = nil
            try await loadCurrentUserIfNeeded(generation: generation, api: activeAPI)
            guard isCurrentSession() else { return .applied }
            if route == originalRoute, let visibleProfileID, profile?.id == visibleProfileID {
                let request = beginRequest(.profile)
                contentStore.journalIsLoading = false
                let refreshed = try await activeAPI.query(
                    "user", args: [activeAPI.domain, [String(visibleProfileID)]], as: TaggrUser.self
                )
                guard isCurrentSession(), isCurrentRequest(request), profile?.id == visibleProfileID else { return .applied }
                profile = refreshed
            }
            if case .feed(let mode) = route {
                await loadFeed(mode: mode, reset: true)
            }
            return .applied
        } catch {
            guard isCurrentSession() else { return applied ? .applied : .uncertain }
            if applied {
                errorMessage = "The change succeeded, but the updated profile could not be loaded. Refresh to see it."
                return .applied
            }
            if case TaggrAPIError.rejected = error {
                errorMessage = error.localizedDescription
                return .rejected
            }
            errorMessage = "The result could not be confirmed. Refresh and check the current state before trying again. \(error.localizedDescription)"
            return .uncertain
        }
    }
}
