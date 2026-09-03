import Foundation
import ICNativeClient
import Observation

struct RealmPostingScope: Hashable {
    let canisterID: String
    let userID: Int
}

struct RealmPostingPreferences {
    private static let keyPrefix = "taggr.realm-posting-history"
    private static let maxDestinations = 100

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recentDestinations(scope: RealmPostingScope) -> [String] {
        defaults.stringArray(forKey: storageKey(scope: scope)) ?? []
    }

    func record(destination: String?, scope: RealmPostingScope) {
        let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var destinations = recentDestinations(scope: scope)
        destinations.removeAll { $0.caseInsensitiveCompare(destination) == .orderedSame }
        destinations.insert(destination, at: 0)
        defaults.set(Array(destinations.prefix(Self.maxDestinations)), forKey: storageKey(scope: scope))
    }

    func validDestinations(scope: RealmPostingScope, availableRealms: [String]) -> [String] {
        recentDestinations(scope: scope).compactMap { destination in
            guard !destination.isEmpty else { return "" }
            return availableRealms.first {
                $0.caseInsensitiveCompare(destination) == .orderedSame
            }
        }
    }

    private func storageKey(scope: RealmPostingScope) -> String {
        "\(Self.keyPrefix).\(scope.canisterID).\(scope.userID)"
    }
}

@MainActor
@Observable
final class NavigationStore {
    var route: TaggrRoute = .feed(.hot)
    var returnFeedMode: TaggrFeedMode = .hot
    var lastHomeFeedMode: TaggrFeedMode = .hot
    var postReturnRoutesByPostID: [Int: TaggrRoute] = [:]
    var profileReturnRoute: TaggrRoute = .feed(.hot)
    var routeLoadRevision = 0

    func setReturnFeedMode(_ mode: TaggrFeedMode) {
        returnFeedMode = mode
    }

    func rememberHomeFeedMode(_ mode: TaggrFeedMode) {
        switch mode {
        case .hot, .latest, .personal:
            lastHomeFeedMode = mode
        case .realm, .tags:
            break
        }
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
    let runtimeConfig: TaggrRuntimeConfig

    init(config: TaggrRuntimeConfig) {
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
    var isLoadingMoreFeed = false
    var authorNamesByUserID: [Int: String] = [:]
}

@MainActor
@Observable
final class ContentStore {
    var focusedPost: TaggrPost?
    var profile: TaggrUser?
    var realms: [TaggrRealm] = []
    var nextAllRealmsPage = 0
    var canLoadMoreRealms = false
    var isLoadingMoreRealms = false
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
