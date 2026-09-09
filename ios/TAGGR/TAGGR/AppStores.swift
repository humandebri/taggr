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
    private static let homeFeedModeKey = "taggr.home-feed-mode"
    private let defaults: UserDefaults

    var route: TaggrRoute = .feed(.hot)
    var returnFeedMode: TaggrFeedMode = .hot
    var lastHomeFeedMode: TaggrFeedMode = .hot
    private(set) var hasStoredHomeFeedMode = false
    var postReturnRoutesByPostID: [Int: TaggrRoute] = [:]
    var profileReturnRoute: TaggrRoute = .feed(.hot)
    var routeLoadRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedValue = defaults.string(forKey: Self.homeFeedModeKey),
           let storedMode = Self.feedMode(from: storedValue) {
            lastHomeFeedMode = storedMode
            route = .feed(storedMode)
            hasStoredHomeFeedMode = true
        }
    }

    func setReturnFeedMode(_ mode: TaggrFeedMode) {
        returnFeedMode = mode
    }

    func rememberHomeFeedMode(_ mode: TaggrFeedMode) {
        switch mode {
        case .hot, .latest, .personal, .realms:
            lastHomeFeedMode = mode
            defaults.set(Self.rawValue(for: mode), forKey: Self.homeFeedModeKey)
            hasStoredHomeFeedMode = true
        case .realm, .tags:
            break
        }
    }

    private static func rawValue(for mode: TaggrFeedMode) -> String {
        switch mode {
        case .hot: return "hot"
        case .latest: return "latest"
        case .personal: return "personal"
        case .realms: return "realms"
        case .realm, .tags: return "hot"
        }
    }

    private static func feedMode(from rawValue: String) -> TaggrFeedMode? {
        switch rawValue {
        case "hot": return .hot
        case "latest": return .latest
        case "personal": return .personal
        case "realms": return .realms
        default: return nil
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
    var postSubmissionNotice: TaggrPostSubmissionNotice?
    var isAuthenticatingIdentity = false
    var identitySignInMethodPickerPresented = false
    var identitySignInReason: String?
    let runtimeConfig: TaggrRuntimeConfig

    init(config: TaggrRuntimeConfig) {
        runtimeConfig = config
    }
}

enum TaggrPostSubmissionPhase: Equatable, Sendable {
    case submitting
    case succeeded
    case retryableFailure
    case uncertain
}

struct TaggrPostSubmissionNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let phase: TaggrPostSubmissionPhase
    let message: String
}

enum TaggrPostSubmissionKey: Hashable, Sendable {
    case newPost
    case reply(Int)
    case edit(Int)
    case repost(Int)
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
    var profileActionInFlight = false
    var journalPosts: [TaggrPost] = []
    var journalPage = 0
    var journalOffset = 0
    var journalCanLoadMore = false
    var journalIsLoading = false
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
