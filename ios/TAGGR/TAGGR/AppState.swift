import Foundation
import AuthenticationServices
import ICNativeClient
import Observation
import SwiftUI

struct TaggrDraftImage: Equatable, Sendable {
    let id: String
    let data: Data
    let width: Int
    let height: Int

    var markdown: String {
        let kilobytes = Int(ceil(Double(data.count) / 1024))
        return "![\(width)x\(height), \(kilobytes)kb](/blob/\(id))"
    }
}

struct TaggrStorageCreationState: Codable, Equatable, Sendable {
    static let settingKey = "bucket_creation_state"

    var stage: Stage
    var blockIndex: UInt64?
    var canisterId: String?

    enum Stage: String, Codable, Equatable, Sendable {
        case transferring
        case transferred
        case creating
        case created
        case installing
        case installed
        case registering
        case done
    }

    var title: String {
        switch stage {
        case .transferring:
            return "Transferring ICP"
        case .transferred:
            return "ICP transferred"
        case .creating:
            return "Creating canister"
        case .created:
            return "Canister created"
        case .installing:
            return "Installing storage"
        case .installed:
            return "Storage installed"
        case .registering:
            return "Registering storage"
        case .done:
            return "Storage ready"
        }
    }
}

@MainActor
@Observable
final class TaggrAppCoordinator {
    static let identityStoreService = ["network", "taggr", "ios", "identity"].joined(separator: ".")

    let navigationStore: NavigationStore
    let feedStore = FeedStore()
    let contentStore = ContentStore()
    let featurePosts = TaggrFeaturePostStore()
    let walletStorageStore = WalletStorageStore()
    let sessionStore: SessionStore
    let safety: TaggrSafetyStore

    var route: TaggrRoute {
        get { navigationStore.route }
        set {
            guard navigationStore.route != newValue else { return }
            featurePosts.clearPosts()
            requestTasks.values.forEach { $0.cancel() }
            requestTasks.removeAll()
            navigationStore.route = newValue
        }
    }
    var returnFeedMode: TaggrFeedMode {
        get { navigationStore.returnFeedMode }
        set { navigationStore.returnFeedMode = newValue }
    }
    var lastHomeFeedMode: TaggrFeedMode {
        navigationStore.lastHomeFeedMode
    }
    var effectiveHomeFeedMode: TaggrFeedMode {
        if lastHomeFeedMode == .personal, authSession == nil {
            return .hot
        }
        return lastHomeFeedMode
    }
    var postReturnRoutesByPostID: [Int: TaggrRoute] {
        get { navigationStore.postReturnRoutesByPostID }
        set { navigationStore.postReturnRoutesByPostID = newValue }
    }
    var profileReturnRoute: TaggrRoute {
        get { navigationStore.profileReturnRoute }
        set { navigationStore.profileReturnRoute = newValue }
    }
    var routeLoadRevision: Int {
        get { navigationStore.routeLoadRevision }
        set { navigationStore.routeLoadRevision = newValue }
    }
    var authSession: ICAuthSession? {
        get { sessionStore.authSession }
        set {
            if sessionStore.authSession?.principal != newValue?.principal {
                featurePosts.reset()
                clearNotificationPostCache()
                restoredFeedMode = nil
                postThread = []
                loadedFeedMode = nil
            }
            sessionStore.authSession = newValue
        }
    }
    var currentUser: TaggrUser? {
        get { sessionStore.currentUser }
        set {
            if let previousUserID = sessionStore.currentUser?.id,
               previousUserID != newValue?.id {
                featurePosts.reset()
                clearNotificationPostCache()
                restoredFeedMode = nil
                postThread = []
                loadedFeedMode = nil
            }
            sessionStore.currentUser = newValue
        }
    }
    var cache: TaggrBackendCache? {
        get { sessionStore.cache }
        set { sessionStore.cache = newValue }
    }
    var isBusy: Bool {
        get { sessionStore.isBusy }
        set { sessionStore.isBusy = newValue }
    }
    var errorMessage: String? {
        get { sessionStore.errorMessage }
        set { sessionStore.errorMessage = newValue }
    }
    var postSubmissionNotice: TaggrPostSubmissionNotice? {
        get { sessionStore.postSubmissionNotice }
        set { sessionStore.postSubmissionNotice = newValue }
    }
    var isAuthenticatingIdentity: Bool {
        get { sessionStore.isAuthenticatingIdentity }
        set { sessionStore.isAuthenticatingIdentity = newValue }
    }
    var identitySignInMethodPickerPresented: Bool {
        get { sessionStore.identitySignInMethodPickerPresented }
        set { sessionStore.identitySignInMethodPickerPresented = newValue }
    }
    var identitySignInReason: String? {
        get { sessionStore.identitySignInReason }
        set { sessionStore.identitySignInReason = newValue }
    }
    var runtimeConfig: TaggrRuntimeConfig {
        sessionStore.runtimeConfig
    }
    // Consumed once by the route task when returning to an intact timeline.
    var restoredFeedMode: TaggrFeedMode?
    var loadedFeedMode: TaggrFeedMode?
    var postThread: [TaggrPost] {
        get { contentStore.postThread }
        set { contentStore.postThread = newValue }
    }
    var feed: [TaggrPost] {
        get { feedStore.feed }
        set { feedStore.feed = newValue }
    }
    var repliesByPostID: [Int: [TaggrPost]] {
        get { feedStore.repliesByPostID }
        set { feedStore.repliesByPostID = newValue }
    }
    var loadingReplyPostIDs: Set<Int> {
        get { feedStore.loadingReplyPostIDs }
        set { feedStore.loadingReplyPostIDs = newValue }
    }
    var canLoadMoreFeed: Bool {
        get { feedStore.canLoadMoreFeed }
        set { feedStore.canLoadMoreFeed = newValue }
    }
    var isLoadingMoreFeed: Bool {
        get { feedStore.isLoadingMoreFeed }
        set { feedStore.isLoadingMoreFeed = newValue }
    }
    var authorNamesByUserID: [Int: String] {
        get { feedStore.authorNamesByUserID }
        set { feedStore.authorNamesByUserID = newValue }
    }
    var notificationPosts: [Int: TaggrPost] {
        get { feedStore.notificationPosts }
    }
    var focusedPost: TaggrPost? {
        get { contentStore.focusedPost }
        set { contentStore.focusedPost = newValue }
    }
    var profile: TaggrUser? {
        get { contentStore.profile }
        set { contentStore.profile = newValue }
    }
    var realms: [TaggrRealm] {
        get { contentStore.realms }
        set { contentStore.realms = newValue }
    }
    var nextAllRealmsPage: Int {
        get { contentStore.nextAllRealmsPage }
        set { contentStore.nextAllRealmsPage = newValue }
    }
    var canLoadMoreRealms: Bool {
        get { contentStore.canLoadMoreRealms }
        set { contentStore.canLoadMoreRealms = newValue }
    }
    var isLoadingMoreRealms: Bool {
        get { contentStore.isLoadingMoreRealms }
        set { contentStore.isLoadingMoreRealms = newValue }
    }
    var icpInvoice: TaggrICPInvoice? {
        get { walletStorageStore.icpInvoice }
        set { walletStorageStore.icpInvoice = newValue }
    }
    var icpBalanceE8s: UInt64? {
        get { walletStorageStore.icpBalanceE8s }
        set { walletStorageStore.icpBalanceE8s = newValue }
    }
    var storageStatus: TaggrStorageCanisterStatus? {
        get { walletStorageStore.storageStatus }
        set { walletStorageStore.storageStatus = newValue }
    }
    var storageExpectedWasmHash: String? {
        get { walletStorageStore.storageExpectedWasmHash }
        set { walletStorageStore.storageExpectedWasmHash = newValue }
    }
    var storageCreationState: TaggrStorageCreationState? {
        get { walletStorageStore.storageCreationState }
        set { walletStorageStore.storageCreationState = newValue }
    }

    var retirementDefaults: UserDefaults
    var retirementRevision = 0
    var retirementBusy = false
    var retirementCompleted = false
    var retirementMessage: String?
    var api: TaggrAPI
    var identityStore: ICIdentityStore
    var identityAuthenticator: ICInternetIdentityAuthenticator
    let apiFactory: @MainActor (TaggrRuntimeConfig) -> TaggrAPI
    let identityStoreFactory: @MainActor (TaggrRuntimeConfig) -> ICIdentityStore
    let identityAuthenticatorFactory: @MainActor (TaggrRuntimeConfig) -> ICInternetIdentityAuthenticator
    let injectedAPI: TaggrAPI?
    let injectedIdentityStore: ICIdentityStore?
    let injectedIdentityAuthenticator: ICInternetIdentityAuthenticator?
    let postDraftStore: PostDraftStore
    let realmPostingPreferences: RealmPostingPreferences
    let youtubeUpload: YouTubeUploadCoordinator
    static let maxAuthorNameCacheEntries = 500
    static let allRealmsPageSize = 20
    enum RequestScope: Hashable, Sendable {
        case feed
        case post
        case profile
        case realm
    }

    struct RequestToken: Sendable {
        let scope: RequestScope
        let sequence: Int
        let runtimeGeneration: Int
        let route: TaggrRoute
    }

    var authorNameCacheOrder: [Int] = []
    var notificationRefreshFailed = false
    @ObservationIgnored var userRefreshTask: Task<TaggrUser?, Error>?
    @ObservationIgnored var userRefreshKey: String?
    @ObservationIgnored var userRefreshID: UUID?
    var runtimeGeneration = 0 {
        didSet {
            featurePosts.reset()
            clearNotificationPostCache()
            restoredFeedMode = nil
            postThread = []
            loadedFeedMode = nil
        }
    }
    var requestSequences: [RequestScope: Int] = [:]
    var requestTasks: [RequestScope: Task<Void, Never>] = [:]
    var activeOperationIDs: Set<UUID> = []
    var latestOperationID: UUID?
    var realmMembershipOperation: String?
    var tagCostCache: [[String]: Int] = [:]
    var tagCostRequestSequence = 0
    var tagCostTask: Task<Int, Error>?
    var postSubmissionTasks: [TaggrPostSubmissionKey: Task<Void, Never>] = [:]
    var postReconciliationTasks: [UUID: Task<Void, Never>] = [:]
    var postSubmissionNoticeDismissTask: Task<Void, Never>?

    init(
        retirementDefaults: UserDefaults = .standard,
        navigationStore: NavigationStore = NavigationStore(),
        safety: TaggrSafetyStore = TaggrSafetyStore(),
        api: TaggrAPI? = nil,
        identityStore: ICIdentityStore? = nil,
        identityAuthenticator: ICInternetIdentityAuthenticator? = nil,
        postDraftStore: PostDraftStore = PostDraftStore(),
        realmPostingPreferences: RealmPostingPreferences = RealmPostingPreferences(),
        youtubeUpload: YouTubeUploadCoordinator? = nil,
        buildConfig: TaggrRuntimeConfig = .current,
        apiFactory: @escaping @MainActor (TaggrRuntimeConfig) -> TaggrAPI = { TaggrAPI(config: $0) },
        identityStoreFactory: @escaping @MainActor (TaggrRuntimeConfig) -> ICIdentityStore = { runtimeConfig in
            ICIdentityStore(
                configuration: runtimeConfig.icClientConfiguration,
                service: TaggrAppCoordinator.identityStoreService
            )
        },
        identityAuthenticatorFactory: @escaping @MainActor (TaggrRuntimeConfig) -> ICInternetIdentityAuthenticator = { runtimeConfig in
            do {
                return try ICInternetIdentityAuthenticator(
                    configuration: runtimeConfig.icClientConfiguration,
                    callbackDomain: runtimeConfig.callbackDomain,
                    callbackPath: ICInternetIdentityAuthenticator.callbackPath
                )
            } catch {
                preconditionFailure("Invalid Internet Identity configuration: \(error)")
            }
        }
    ) {
        self.navigationStore = navigationStore
        self.sessionStore = SessionStore(config: buildConfig)
        self.safety = safety
        self.apiFactory = apiFactory
        self.identityStoreFactory = identityStoreFactory
        self.identityAuthenticatorFactory = identityAuthenticatorFactory
        self.injectedAPI = api
        self.injectedIdentityStore = identityStore
        self.injectedIdentityAuthenticator = identityAuthenticator
        self.api = api ?? apiFactory(buildConfig)
        self.identityStore = identityStore ?? identityStoreFactory(buildConfig)
        self.identityAuthenticator = identityAuthenticator ?? identityAuthenticatorFactory(buildConfig)
        self.retirementDefaults = retirementDefaults
        self.postDraftStore = postDraftStore
        self.realmPostingPreferences = realmPostingPreferences
        self.youtubeUpload = youtubeUpload ?? YouTubeUploadCoordinator()
        self.youtubeUpload.safetyCheck = { [weak self] target, text in
            guard let self, target.namespace.canisterID == self.runtimeConfig.canisterId,
                  target.namespace.userID == self.currentUser?.id else { throw TaggrSafetyError.unavailable }
            try await self.requireSafePublishing(text: text)
            guard target.namespace.canisterID == self.runtimeConfig.canisterId,
                  target.namespace.userID == self.currentUser?.id else { throw TaggrSafetyError.unavailable }
        }
    }

    var realmPostingScope: RealmPostingScope? {
        currentUser.map {
            RealmPostingScope(canisterID: runtimeConfig.canisterId, userID: $0.id)
        }
    }

    var recentlyUsedJoinedRealms: [String] {
        Array((currentUser?.realms ?? []).reversed())
    }

    func initialPostingRealm(for mode: TaggrFeedMode) -> String {
        if case .realm(let name) = mode {
            return name
        }
        guard let scope = realmPostingScope else { return "" }
        let localDestination = realmPostingPreferences.validDestinations(
            scope: scope,
            availableRealms: currentUser?.realms ?? []
        ).first
        guard localDestination?.isEmpty == false else { return "" }
        return recentlyUsedJoinedRealms.first ?? ""
    }

    func orderedPostingRealms(selectedRealm: String?) -> [String] {
        var realms = recentlyUsedJoinedRealms
        guard let selectedRealm, !selectedRealm.isEmpty else { return realms }
        let selectedName = realms.first {
            $0.caseInsensitiveCompare(selectedRealm) == .orderedSame
        } ?? selectedRealm
        realms.removeAll { $0.caseInsensitiveCompare(selectedRealm) == .orderedSame }
        realms.insert(selectedName, at: 0)
        return realms
    }

    func bootstrap() async {
        youtubeUpload.auth.bootstrap()
        var loadError: Error?
        authSession = nil
        for signInMethod in runtimeConfig.availableIdentitySignInMethods {
            activateIdentityConfiguration(for: signInMethod)
            do {
                if let session = try identityStore.load() {
                    authSession = session
                    break
                }
            } catch {
                loadError = error
            }
        }
        if authSession == nil {
            activateIdentityConfiguration(for: .passkey)
            if let loadError {
                NSLog("TAGGR identity session could not be loaded: %@", loadError.localizedDescription)
            }
        }
        await reloadCache()
        await refreshCurrentUser()
        await youtubeUpload.bootstrap()
        if navigationStore.lastHomeFeedMode == .personal, authSession == nil {
            route = .feed(.hot)
        } else if !navigationStore.hasStoredHomeFeedMode, authSession != nil {
            route = .feed(.personal)
            navigationStore.rememberHomeFeedMode(.personal)
        }
        routeLoadRevision += 1
    }

    func open(_ url: URL) {
        navigate(to: TaggrNavigation.route(from: url) ?? .feed(.hot))
        routeLoadRevision += 1
    }

    func navigate(to destination: TaggrRoute) {
        switch destination {
        case .post(let id):
            navigateToPost(id)
        case .thread(let id):
            navigateToThread(id)
        default:
            switch destination {
            case .bookmarks, .invites, .proposals, .proposal, .search, .transactions:
                if destination != route { navigationStore.featureReturnRoutes[destination] = route }
            default: break
            }
            route = destination
        }
    }

    func loadCurrentRoute(forceFeedReload: Bool = false) async {
        guard !accountRetired else { return }
        switch route {
        case .feed(let mode):
            let restoresFeed = restoredFeedMode == mode
            restoredFeedMode = nil
            if !restoresFeed || forceFeedReload {
                await loadFeed(mode: mode, reset: true)
            }
        case .post(let id):
            await loadPost(id)
        case .thread(let id):
            await loadThread(id)
        case .profile(let handle):
            await loadProfile(handle)
        case .userPhotos, .search, .transactions, .bookmarks, .invites, .proposals, .proposal:
            break
        case .realm(let name) where name.isEmpty:
            await loadRealmsList()
        case .realm(let name):
            await loadRealm(name)
        case .inbox:
            await refreshCurrentUser()
        case .settings:
            break
        }
    }

    func refreshVisibleRoute() async {
        if case .settings = route {
            await reloadCache()
            if authSession != nil {
                await refreshSettingsAccount()
            }
            return
        }
        if authSession != nil {
            await refreshCurrentUser()
        }
        switch route {
        case .realm(let name) where name.isEmpty:
            await loadRealmsList()
        case .inbox:
            break
        default:
            await loadCurrentRoute(forceFeedReload: true)
        }
    }

    func selectRootRoute(_ nextRoute: TaggrRoute) {
        switch nextRoute {
        case .feed(let mode):
            navigateToFeed(mode)
        case .inbox:
            route = .inbox
        case .realm(let name) where name.isEmpty:
            focusedPost = nil
            route = .realm("")
        case .settings:
            focusedPost = nil
            route = .settings
        default:
            route = nextRoute
        }
    }

    func reloadCache() async {
        let generation = runtimeGeneration
        let activeAPI = api
        do {
            async let stats: TaggrStats? = activeAPI.query("stats", as: TaggrStats.self)
            async let config: TaggrConfig? = activeAPI.query("config", as: TaggrConfig.self)
            let nextCache = TaggrBackendCache(stats: try await stats, config: try await config)
            guard isCurrentRuntimeGeneration(generation) else { return }
            cache = nextCache
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadFeed(mode: TaggrFeedMode, reset: Bool, showsBusyOverlay: Bool = true) async {
        if reset { loadedFeedMode = nil }
        let request = beginRequest(.feed)
        let activeAPI = api
        returnFeedMode = mode
        navigationStore.rememberHomeFeedMode(mode)
        await executeRequest(request) {
            let load = {
                let pageSize = self.cache?.config?.feedPageSize ?? 30
                let page = reset ? 0 : max(self.feed.count / max(pageSize, 1), 0)
                let offset = reset ? 0 : (self.feed.first?.id ?? 0)
                let posts: [TaggrPost]
                switch mode {
                case .hot:
                    posts = try await self.loadPostEnvelopes("hot_posts", args: [activeAPI.domain, "", page, offset, true], identity: self.authSession, api: activeAPI)
                case .latest:
                    posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, "", page, offset, true], identity: self.authSession, api: activeAPI)
                case .personal:
                    if let authSession = self.authSession {
                        posts = try await self.loadPostEnvelopes("personal_feed", args: [activeAPI.domain, page, offset], identity: authSession, api: activeAPI)
                    } else {
                        posts = []
                    }
                case .realm(let name):
                    posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, name, page, offset, true], identity: self.authSession, api: activeAPI)
                case .tags(let tokens):
                    posts = try await self.loadPostEnvelopes("posts_by_tags", args: [activeAPI.domain, "", tokens, page, offset], identity: nil, api: activeAPI)
                }
                guard self.isCurrentRequest(request) else { return }
                self.feed = reset ? posts : self.feed + posts
                self.loadedFeedMode = mode
                self.canLoadMoreFeed = posts.count >= pageSize
            }
            if showsBusyOverlay {
                await self.runBusy(validWhile: { self.isCurrentRequest(request) }, load)
            } else {
                do {
                    try await load()
                } catch {
                    guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                    NSLog("TAGGR background feed refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func loadMoreFeed(mode: TaggrFeedMode) async {
        guard canLoadMoreFeed, !isLoadingMoreFeed else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        await loadFeed(mode: mode, reset: false)
    }

    func navigateToPost(_ id: Int, from mode: TaggrFeedMode? = nil) {
        navigate(toPostScreen: .post(id), from: mode)
    }

    func navigateToThread(_ id: Int) {
        navigate(toPostScreen: .thread(id))
    }

    private func navigate(toPostScreen destination: TaggrRoute, from mode: TaggrFeedMode? = nil) {
        restoredFeedMode = nil
        if let mode {
            returnFeedMode = mode
        }
        let returnRoute: TaggrRoute
        if let currentPostID = currentPostScreenID {
            returnRoute = postReturnRoute(for: currentPostID)
            postReturnRoutesByPostID.removeValue(forKey: currentPostID)
        } else {
            returnRoute = route
        }
        if let postID = Self.postScreenID(destination) {
            postReturnRoutesByPostID[postID] = returnRoute
        }
        route = destination
    }

    /// Both post screens (a single post and its thread) keep the same return route.
    private static func postScreenID(_ route: TaggrRoute) -> Int? {
        switch route {
        case .post(let id), .thread(let id):
            return id
        default:
            return nil
        }
    }

    private var currentPostScreenID: Int? {
        Self.postScreenID(route)
    }

    func postReturnRoute(for postID: Int) -> TaggrRoute {
        postReturnRoutesByPostID[postID] ?? .feed(effectiveHomeFeedMode)
    }

    var currentPostReturnRoute: TaggrRoute {
        guard let postID = currentPostScreenID else {
            return .feed(effectiveHomeFeedMode)
        }
        return postReturnRoute(for: postID)
    }

    var postReturnTitle: String {
        switch currentPostReturnRoute {
        case .feed:
            return "Timeline"
        case .profile:
            return "Profile"
        case .userPhotos:
            return "Photos"
        case .realm:
            return "Realm"
        case .inbox:
            return "Inbox"
        case .settings:
            return "Account"
        case .bookmarks: return "Bookmarks"
        case .search: return "Search"
        case .transactions: return "Transactions"
        case .invites: return "Invites"
        case .proposals, .proposal: return "Proposals"
        case .post:
            return "Timeline"
        case .thread:
            return "Post"
        }
    }

    func navigateBackFromPost() {
        guard let postID = currentPostScreenID else {
            navigateToHomeFeed()
            return
        }
        let destination = postReturnRoute(for: postID)
        postReturnRoutesByPostID.removeValue(forKey: postID)
        switch destination {
        case .feed(let mode):
            navigateToFeed(mode)
            restoreLoadedFeed(for: destination)
        case .realm(let name):
            navigateToRealm(name)
        case .post:
            navigateToHomeFeed()
        default:
            focusedPost = nil
            route = destination
        }
    }

    func navigateToFeed(_ mode: TaggrFeedMode) {
        restoredFeedMode = nil
        returnFeedMode = mode
        navigationStore.rememberHomeFeedMode(mode)
        focusedPost = nil
        route = .feed(mode)
    }

    func navigateToHomeFeed() {
        restoredFeedMode = nil
        let mode = effectiveHomeFeedMode
        returnFeedMode = mode
        focusedPost = nil
        route = .feed(mode)
    }

    func navigateToRealm(_ name: String) {
        let normalized = normalizedRealmName(name)
        returnFeedMode = .realm(normalized)
        focusedPost = nil
        route = .realm(normalized)
    }

    func navigateToProfile(_ handle: String, from route: TaggrRoute? = nil) {
        profileReturnRoute = route ?? self.route
        self.route = .profile(handle)
    }

    func navigateBackFromProfile() {
        route = profileReturnRoute
        restoreLoadedFeed(for: profileReturnRoute)
    }

    /// A back navigation into the timeline that is still loaded must not refetch its first page,
    /// otherwise the reader loses the position they left.
    func restoreLoadedFeed(for destination: TaggrRoute) {
        guard case .feed(let mode) = destination else { return }
        restoredFeedMode = loadedFeedMode == mode ? mode : nil
    }

    var unreadNotificationCount: Int {
        currentUser?.notifications.values.filter { !$0.read }.count ?? 0
    }

    func notificationEntries(read: Bool) -> [(id: Int, entry: TaggrNotificationEntry)] {
        guard let notifications = currentUser?.notifications else { return [] }
        return notifications
            .filter { $0.value.read == read }
            .sorted { $0.key > $1.key }
            .map { (id: $0.key, entry: $0.value) }
    }

    private static let unavailableNotificationPostTTL: TimeInterval = 60

    func loadNotificationPost(_ id: Int, useCache: Bool = true) async throws -> TaggrPost? {
        if useCache {
            if let cached = feedStore.notificationPosts[id] { return cached }
            if isNotificationPostUnavailable(id) { return nil }
        }
        let post = try await loadPostEnvelopes("posts", args: [[id]], identity: nil).first
        if let post {
            feedStore.unavailableNotificationPostIDs.removeValue(forKey: id)
            feedStore.notificationPosts[id] = post
        } else if useCache {
            feedStore.unavailableNotificationPostIDs[id] = Date()
        }
        return post
    }

    // An empty query result can come from a lagging replica, so a negative result expires
    // instead of hiding the post until the next account change or pull-to-refresh.
    func isNotificationPostUnavailable(_ id: Int) -> Bool {
        (notificationPostRetryDelay(id) ?? 0) > 0
    }

    func notificationPostRetryDelay(_ id: Int, now: Date = .now) -> TimeInterval? {
        guard let markedAt = feedStore.unavailableNotificationPostIDs[id] else { return nil }
        return max(Self.unavailableNotificationPostTTL - now.timeIntervalSince(markedAt), 0)
    }

    // Inbox cards are recycled while scrolling, so retained posts are cleared only on account or explicit refresh.
    func clearNotificationPostCache() {
        feedStore.notificationPosts.removeAll()
        feedStore.unavailableNotificationPostIDs.removeAll()
    }

    // Optimistic updates write through `updatePost`, so a failed action must restore the retained copy as well.
    func restoreNotificationPost(_ post: TaggrPost?, for id: Int) {
        if let post {
            feedStore.notificationPosts[id] = post
        } else {
            feedStore.notificationPosts.removeValue(forKey: id)
        }
    }

    // A post the backend no longer serves must stop rendering from the inbox cache.
    func invalidateNotificationPost(_ id: Int) {
        feedStore.notificationPosts.removeValue(forKey: id)
        feedStore.unavailableNotificationPostIDs[id] = Date()
    }

    func markNotificationsRead(_ ids: [Int]) async {
        guard !ids.isEmpty else { return }
        await runBusy {
            _ = try await api.updateJSON("clear_notifications", args: [ids], identity: authSession)
            markLocalNotificationsRead(ids)
        }
    }

    func markAllNotificationsRead() async {
        let ids = currentUser?.notifications.keys.sorted() ?? []
        await markNotificationsRead(ids)
    }

    func unwatchPostFromNotification(notificationId: Int, postId: Int) async {
        await runBusy {
            _ = try await api.updateJSON("clear_notifications", args: [[notificationId]], identity: authSession)
            _ = try await api.toggleFollowingPost(postId: postId, identity: authSession)
            markLocalNotificationsRead([notificationId])
        }
    }

    /// Opens a post like the PWA post page. A root post shows its direct replies
    /// below the post; a reply keeps its ancestor thread visible instead, which is
    /// the state the separate thread entry used to reach. The post is shown as soon
    /// as it arrives and its replies follow without holding the busy overlay, so a
    /// large thread cannot delay the first paint.
    func loadPost(_ id: Int, showsBusyOverlay: Bool = true) async {
        let request = beginRequest(.post)
        let activeAPI = api
        await executeRequest(request) {
            let load = {
                let thread = try await self.loadPostEnvelopes("thread", args: [id], identity: nil, api: activeAPI)
                guard self.isCurrentRequest(request) else { return }
                self.focusedPost = thread.last
                if thread.count > 1 {
                    self.postThread = thread
                    return
                }
                self.postThread = []
                self.repliesByPostID[id] = nil
            }
            if showsBusyOverlay {
                await self.runBusy(validWhile: { self.isCurrentRequest(request) }, load)
            } else {
                do {
                    try await load()
                } catch {
                    guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                    NSLog("TAGGR background post refresh failed: %@", error.localizedDescription)
                    return
                }
            }
            guard self.isCurrentRequest(request), self.postThread.isEmpty,
                  let post = self.focusedPost, post.id == id else { return }
            let generation = self.runtimeGeneration
            self.loadingReplyPostIDs.insert(id)
            defer { self.loadingReplyPostIDs.remove(id) }
            do {
                let replies = try await self.loadDirectReplies(for: post, api: activeAPI)
                guard self.isCurrentRuntimeGeneration(generation), self.isCurrentRequest(request) else { return }
                self.repliesByPostID[id] = replies
            } catch {
                guard self.isCurrentRuntimeGeneration(generation), !self.isCancellation(error) else { return }
                NSLog("TAGGR replies load after post open failed: %@", error.localizedDescription)
            }
        }
    }

    /// Opens a post inside its ancestor chain, like the PWA thread page.
    func loadThread(_ id: Int, showsBusyOverlay: Bool = true) async {
        let request = beginRequest(.post)
        let activeAPI = api
        await executeRequest(request) {
            let load = {
                let thread = try await self.loadPostEnvelopes("thread", args: [id], identity: nil, api: activeAPI)
                var refreshedReplies: [TaggrPost]?
                if self.repliesByPostID[id] != nil, let post = thread.last {
                    do {
                        refreshedReplies = try await self.loadDirectReplies(for: post, api: activeAPI)
                    } catch {
                        guard !self.isCancellation(error) else { return }
                        NSLog("TAGGR replies refresh during thread load failed: %@", error.localizedDescription)
                    }
                }
                guard self.isCurrentRequest(request) else { return }
                self.focusedPost = thread.last
                self.postThread = thread
                if let refreshedReplies {
                    self.repliesByPostID[id] = refreshedReplies
                }
            }
            if showsBusyOverlay {
                await self.runBusy(validWhile: { self.isCurrentRequest(request) }, load)
            } else {
                do {
                    try await load()
                } catch {
                    guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                    NSLog("TAGGR background thread refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func loadReplies(for post: TaggrPost) async {
        guard repliesByPostID[post.id] == nil, !loadingReplyPostIDs.contains(post.id) else {
            return
        }
        let generation = runtimeGeneration
        let activeAPI = api
        loadingReplyPostIDs.insert(post.id)
        defer { loadingReplyPostIDs.remove(post.id) }
        do {
            let replies = try await loadDirectReplies(for: post, api: activeAPI)
            guard isCurrentRuntimeGeneration(generation) else { return }
            repliesByPostID[post.id] = replies
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            NSLog("TAGGR replies load failed: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func loadReplies(postID: Int) async {
        guard repliesByPostID[postID] == nil, !loadingReplyPostIDs.contains(postID) else {
            return
        }
        let generation = runtimeGeneration
        let activeAPI = api
        loadingReplyPostIDs.insert(postID)
        defer { loadingReplyPostIDs.remove(postID) }
        do {
            let snapshot = try await loadReplySnapshot(postID: postID, api: activeAPI)
            guard isCurrentRuntimeGeneration(generation) else { return }
            applyReplySnapshot(snapshot)
        } catch {
            guard isCurrentRuntimeGeneration(generation), !isCancellation(error) else { return }
            NSLog("TAGGR reply refresh failed: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func loadReplySnapshot(postID: Int, api activeAPI: TaggrAPI) async throws -> (parent: TaggrPost, replies: [TaggrPost]) {
        guard let parent = try await loadPostEnvelopes(
            "posts",
            args: [[postID]],
            identity: nil,
            api: activeAPI
        ).first else {
            throw TaggrAPIError.invalidResponse("Reply parent was not found.")
        }
        return (parent, try await loadDirectReplies(for: parent, api: activeAPI))
    }

    func loadDirectReplies(for post: TaggrPost, api activeAPI: TaggrAPI) async throws -> [TaggrPost] {
        guard !post.children.isEmpty else { return [] }
        return try await loadPostEnvelopes("posts", args: [post.children], identity: nil, api: activeAPI)
    }

    func applyReplySnapshot(_ snapshot: (parent: TaggrPost, replies: [TaggrPost])) {
        updatePost(snapshot.parent.id) { _ in snapshot.parent }
        repliesByPostID[snapshot.parent.id] = snapshot.replies
    }

    func loadProfile(_ handle: String) async {
        let request = beginRequest(.profile)
        let activeAPI = api
        contentStore.profilePosts = []
        contentStore.profilePostsPage = 0
        contentStore.profilePostsOffset = 0
        contentStore.profilePostsCanLoadMore = false
        contentStore.profilePostsIsLoading = true
        await executeRequest(request) {
            defer {
                if self.isCurrentRequest(request) {
                    self.contentStore.profilePostsIsLoading = false
                }
            }
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let loadedProfile = try await activeAPI.query("user", args: [activeAPI.domain, [handle]], as: TaggrUser.self)
                guard self.isCurrentRequest(request) else { return }
                let posts: [TaggrPost]
                if let loadedProfile {
                    // Matches the PWA profile list, which keeps the user's replies.
                    posts = try await self.loadPostEnvelopes(
                        "user_posts", args: [activeAPI.domain, String(loadedProfile.id), 0, 0],
                        identity: nil, api: activeAPI
                    )
                } else {
                    posts = []
                }
                guard self.isCurrentRequest(request) else { return }
                self.profile = loadedProfile
                self.contentStore.profilePosts = posts
                self.contentStore.profilePostsPage = 0
                self.contentStore.profilePostsOffset = posts.first?.id ?? 0
                self.contentStore.profilePostsCanLoadMore = posts.count >= (self.cache?.config?.feedPageSize ?? 30)
                if let loadedProfile {
                    self.cacheAuthorName(loadedProfile.name, userID: loadedProfile.id)
                }
            }
        }
    }

    func loadMoreProfilePosts() async {
        guard case .profile = route, let profile,
              !isBusy, !contentStore.profilePostsIsLoading, contentStore.profilePostsCanLoadMore else { return }
        let request = beginRequest(.profile)
        let activeAPI = api
        let page = contentStore.profilePostsPage + 1
        let offset = contentStore.profilePostsOffset
        contentStore.profilePostsIsLoading = true
        await executeRequest(request) {
            defer {
                if self.requestSequences[request.scope] == request.sequence {
                    self.contentStore.profilePostsIsLoading = false
                }
            }
            do {
                let posts = try await self.loadPostEnvelopes(
                    // `user_posts` is the PWA profile list: it keeps the user's replies,
                    // while `journal` drops every post with a parent.
                    "user_posts", args: [activeAPI.domain, String(profile.id), page, offset],
                    identity: nil, api: activeAPI
                )
                guard self.isCurrentRequest(request) else { return }
                self.contentStore.profilePosts += posts
                self.contentStore.profilePostsPage = page
                self.contentStore.profilePostsCanLoadMore = posts.count >= (self.cache?.config?.feedPageSize ?? 30)
            } catch {
                guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func loadUserPosts(handle: String, page: Int, offset: Int) async throws -> [TaggrPost] {
        try await loadPostEnvelopes("user_posts", args: [api.domain, handle, page, offset], identity: nil)
    }

    func authorDisplayName(for post: TaggrPost) -> String {
        if let authorName = post.meta.authorName, !authorName.isEmpty {
            return authorName
        }
        if let authorName = authorNamesByUserID[post.user] {
            return authorName
        }
        return "@\(post.user)"
    }

    func authorProfileHandle(for post: TaggrPost) -> String? {
        if let authorName = post.meta.authorName, !authorName.isEmpty {
            return authorName
        }
        if let authorName = authorNamesByUserID[post.user] {
            return authorName
        }
        return nil
    }

    func authorProfileHandle(for userID: Int) -> String? {
        if currentUser?.id == userID, let name = currentUser?.name, !name.isEmpty {
            return name
        }
        guard let name = authorNamesByUserID[userID], !name.isEmpty else { return nil }
        return name
    }

    func loadRealmsList() async {
        loadedFeedMode = nil
        let request = beginRequest(.realm)
        let generation = request.runtimeGeneration
        let activeAPI = api
        nextAllRealmsPage = 0
        canLoadMoreRealms = false
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                if self.authSession != nil && self.currentUser == nil {
                    try await self.loadCurrentUserIfNeeded(generation: generation, api: activeAPI)
                }
                guard self.isCurrentRequest(request) else { return }
                let ids = self.recentlyUsedJoinedRealms
                guard !ids.isEmpty else {
                    self.realms = []
                    self.feed = []
                    return
                }
                let values = try await activeAPI.query("realms", args: [ids], as: [TaggrRealm].self) ?? []
                guard self.isCurrentRuntimeGeneration(generation) else { return }
                self.realms = zip(ids, values).map { id, realm in
                    realm.renamed(realm.name.isEmpty ? id : realm.name)
                }
                self.feed = []
            }
        }
    }

    func loadAllRealmsList(reset: Bool = true) async {
        loadedFeedMode = nil
        guard reset || (canLoadMoreRealms && !isLoadingMoreRealms) else { return }
        if !reset {
            isLoadingMoreRealms = true
        }
        defer {
            if !reset {
                isLoadingMoreRealms = false
            }
        }
        let request = beginRequest(.realm)
        let activeAPI = api
        let page = reset ? 0 : nextAllRealmsPage
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let values = try await activeAPI.query(
                    "all_realms",
                    args: [activeAPI.domain, "popularity", page],
                    as: [TaggrRealmListEntry].self
                ) ?? []
                guard self.isCurrentRequest(request) else { return }
                let loadedRealms = values.map(\.namedRealm)
                if reset {
                    self.realms = loadedRealms
                } else {
                    var existingNames = Set(self.realms.map { $0.name.lowercased() })
                    self.realms.append(contentsOf: loadedRealms.filter {
                        existingNames.insert($0.name.lowercased()).inserted
                    })
                }
                self.nextAllRealmsPage = page + 1
                self.canLoadMoreRealms = values.count >= Self.allRealmsPageSize
                self.feed = []
            }
        }
    }

    func loadRealm(_ name: String, showsBusyOverlay: Bool = true) async {
        loadedFeedMode = nil
        let request = beginRequest(.realm)
        let activeAPI = api
        let normalized = normalizedRealmName(name)
        guard !normalized.isEmpty else {
            realms = []
            feed = []
            return
        }
        returnFeedMode = .realm(normalized)
        await executeRequest(request) {
            let load = {
                let values = try await activeAPI.query("realms", args: [[normalized]], as: [TaggrRealm].self) ?? []
                let posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, normalized, 0, 0, true], identity: nil, api: activeAPI)
                guard self.isCurrentRequest(request) else { return }
                self.realms = values.map { realm in
                    realm.renamed(realm.name.isEmpty ? normalized : realm.name)
                }
                self.feed = posts
            }
            if showsBusyOverlay {
                await self.runBusy(validWhile: { self.isCurrentRequest(request) }, load)
            } else {
                do {
                    try await load()
                } catch {
                    guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                    NSLog("TAGGR background realm refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }

}
