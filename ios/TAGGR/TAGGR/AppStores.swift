import Foundation
import ICNativeClient
import Observation

@MainActor
@Observable
final class NavigationStore {
    var route: TaggrRoute = .feed(.hot)
    var returnFeedMode: TaggrFeedMode = .hot
    var profileReturnRoute: TaggrRoute = .feed(.hot)
    var routeLoadRevision = 0

    func setReturnFeedMode(_ mode: TaggrFeedMode) {
        returnFeedMode = mode
    }

    func setProfileReturnRoute(_ route: TaggrRoute) {
        profileReturnRoute = route
    }

    func requestRouteReload() {
        routeLoadRevision += 1
    }
}

@MainActor
@Observable
final class SessionStore {
    var authSession: ICAuthSession?
    var currentUser: TaggrUser?
    var cache: TaggrBackendCache?
    var isBusy = false
    var errorMessage: String?
    var isAuthenticatingIdentity = false
    var runtimeNetwork: TaggrRuntimeNetwork
    var runtimeConfig: TaggrRuntimeConfig

    init(network: TaggrRuntimeNetwork, config: TaggrRuntimeConfig) {
        runtimeNetwork = network
        runtimeConfig = config
    }

    func setRuntime(network: TaggrRuntimeNetwork, config: TaggrRuntimeConfig) {
        runtimeNetwork = network
        runtimeConfig = config
    }
}

@MainActor
@Observable
final class FeedStore {
    var feed: [TaggrPost] = []
    var repliesByPostID: [Int: [TaggrPost]] = [:]
    var loadingReplyPostIDs: Set<Int> = []
    var canLoadMoreFeed = false
    var authorProfilesByUserID: [Int: TaggrUser] = [:]
    var authorNamesByUserID: [Int: String] = [:]
    var loadingAuthorProfileIDs: Set<Int> = []
    var authorProfileRetryAfter: [Int: Date] = [:]

    func setCanLoadMoreFeed(_ value: Bool) {
        canLoadMoreFeed = value
    }

    func setAuthorProfile(_ profile: TaggrUser?, userID: Int) {
        authorProfilesByUserID[userID] = profile
    }

    func setAuthorName(_ name: String?, userID: Int) {
        authorNamesByUserID[userID] = name
    }

    func setAuthorProfileLoading(_ loading: Bool, userID: Int) {
        if loading {
            loadingAuthorProfileIDs.insert(userID)
        } else {
            loadingAuthorProfileIDs.remove(userID)
        }
    }

    func setAuthorProfileRetryDate(_ date: Date?, userID: Int) {
        authorProfileRetryAfter[userID] = date
    }

    func removeAllAuthorProfileRetryDates() {
        authorProfileRetryAfter.removeAll()
    }

    func clearAuthorCaches() {
        authorProfilesByUserID.removeAll()
        authorNamesByUserID.removeAll()
        loadingAuthorProfileIDs.removeAll()
        authorProfileRetryAfter.removeAll()
    }
}

@MainActor
@Observable
final class ContentStore {
    var focusedPost: TaggrPost?
    var profile: TaggrUser?
    var realms: [TaggrRealm] = []
}

@MainActor
@Observable
final class WalletStorageStore {
    var icpInvoice: TaggrICPInvoice?
    var icpBalanceE8s: UInt64?
    var storageStatus: TaggrStorageCanisterStatus?
    var storageExpectedWasmHash: String?
    var storageCreationState: TaggrStorageCreationState?
}
