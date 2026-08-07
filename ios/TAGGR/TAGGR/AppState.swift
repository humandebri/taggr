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

    let navigationStore = NavigationStore()
    let feedStore = FeedStore()
    let contentStore = ContentStore()
    let walletStorageStore = WalletStorageStore()
    let sessionStore: SessionStore

    var route: TaggrRoute {
        get { navigationStore.route }
        set {
            guard navigationStore.route != newValue else { return }
            requestTasks.values.forEach { $0.cancel() }
            requestTasks.removeAll()
            navigationStore.route = newValue
        }
    }
    var returnFeedMode: TaggrFeedMode {
        get { navigationStore.returnFeedMode }
        set { navigationStore.returnFeedMode = newValue }
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
        set { sessionStore.authSession = newValue }
    }
    var currentUser: TaggrUser? {
        get { sessionStore.currentUser }
        set { sessionStore.currentUser = newValue }
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
    var isAuthenticatingIdentity: Bool {
        get { sessionStore.isAuthenticatingIdentity }
        set { sessionStore.isAuthenticatingIdentity = newValue }
    }
    var runtimeNetwork: TaggrRuntimeNetwork {
        get { sessionStore.runtimeNetwork }
        set { sessionStore.runtimeNetwork = newValue }
    }
    var runtimeConfig: TaggrRuntimeConfig {
        get { sessionStore.runtimeConfig }
        set { sessionStore.runtimeConfig = newValue }
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
    var authorProfilesByUserID: [Int: TaggrUser] {
        get { feedStore.authorProfilesByUserID }
        set { feedStore.authorProfilesByUserID = newValue }
    }
    var authorNamesByUserID: [Int: String] {
        get { feedStore.authorNamesByUserID }
        set { feedStore.authorNamesByUserID = newValue }
    }
    var loadingAuthorProfileIDs: Set<Int> {
        get { feedStore.loadingAuthorProfileIDs }
        set { feedStore.loadingAuthorProfileIDs = newValue }
    }
    var authorProfileRetryAfter: [Int: Date] {
        get { feedStore.authorProfileRetryAfter }
        set { feedStore.authorProfileRetryAfter = newValue }
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

    var api: TaggrAPI
    var identityStore: ICIdentityStore
    var identityAuthenticator: ICInternetIdentityAuthenticator
    let postDraftStore: PostDraftStore
    static let authorProfileRetryInterval: TimeInterval = 5 * 60
    static let maxAuthorProfileCacheEntries = 500
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

    var authorProfileCacheOrder: [Int] = []
    var runtimeGeneration = 0
    var requestSequences: [RequestScope: Int] = [:]
    var requestTasks: [RequestScope: Task<Void, Never>] = [:]
    var activeOperationIDs: Set<UUID> = []
    var latestOperationID: UUID?
    var tagCostCache: [[String]: Int] = [:]
    var tagCostRequestSequence = 0
    var tagCostTask: Task<Int, Error>?
    let apiFactory: @MainActor (TaggrRuntimeConfig) -> TaggrAPI
    let identityStoreFactory: @MainActor (TaggrRuntimeConfig) -> ICIdentityStore
    let identityAuthenticatorFactory: @MainActor (TaggrRuntimeConfig) -> ICInternetIdentityAuthenticator
    let persistRuntimeNetwork: (TaggrRuntimeNetwork) -> Void

    init(
        api: TaggrAPI? = nil,
        identityStore: ICIdentityStore? = nil,
        identityAuthenticator: ICInternetIdentityAuthenticator? = nil,
        postDraftStore: PostDraftStore = PostDraftStore(),
        buildConfig: TaggrRuntimeConfig = .current,
        initialNetwork: TaggrRuntimeNetwork? = nil,
        persistRuntimeNetwork: @escaping (TaggrRuntimeNetwork) -> Void = { _ in },
        apiFactory: @escaping @MainActor (TaggrRuntimeConfig) -> TaggrAPI = { TaggrAPI(config: $0) },
        identityStoreFactory: @escaping @MainActor (TaggrRuntimeConfig) -> ICIdentityStore = { runtimeConfig in
            ICIdentityStore(
                configuration: runtimeConfig.icClientConfiguration,
                service: TaggrAppCoordinator.identityStoreService
            )
        },
        identityAuthenticatorFactory: @escaping @MainActor (TaggrRuntimeConfig) -> ICInternetIdentityAuthenticator = { runtimeConfig in
            ICInternetIdentityAuthenticator(
                configuration: runtimeConfig.icClientConfiguration,
                callbackDomain: runtimeConfig.callbackDomain
            )
        }
    ) {
        let restoredNetwork = buildConfig.canonicalNetworkPreset == nil ? nil : initialNetwork
        let config = if let restoredNetwork {
            TaggrRuntimeConfig.config(for: restoredNetwork)
        } else {
            buildConfig
        }
        let network = restoredNetwork ?? TaggrRuntimeNetwork.from(config: config) ?? .mainnet
        self.sessionStore = SessionStore(network: network, config: config)
        self.apiFactory = apiFactory
        self.identityStoreFactory = identityStoreFactory
        self.identityAuthenticatorFactory = identityAuthenticatorFactory
        self.persistRuntimeNetwork = persistRuntimeNetwork
        self.api = api ?? apiFactory(config)
        self.identityStore = identityStore ?? identityStoreFactory(config)
        self.identityAuthenticator = identityAuthenticator ?? identityAuthenticatorFactory(config)
        self.postDraftStore = postDraftStore
    }

    var isStagingNetwork: Bool {
        runtimeNetwork == .staging
    }

    var canChangeRuntimeNetwork: Bool {
        !isBusy && !isAuthenticatingIdentity
    }

    func setStagingNetworkEnabled(_ enabled: Bool) {
        let nextNetwork: TaggrRuntimeNetwork = enabled ? .staging : .mainnet
        let nextConfig = TaggrRuntimeConfig.config(for: nextNetwork)
        guard runtimeNetwork != nextNetwork || runtimeConfig != nextConfig else { return }
        guard canChangeRuntimeNetwork else { return }
        runtimeGeneration += 1
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        tagCostRequestSequence += 1
        tagCostTask?.cancel()
        tagCostTask = nil
        tagCostCache.removeAll()
        signOut()
        runtimeNetwork = nextNetwork
        runtimeConfig = nextConfig
        api = apiFactory(nextConfig)
        identityStore = identityStoreFactory(nextConfig)
        identityAuthenticator = identityAuthenticatorFactory(nextConfig)
        persistRuntimeNetwork(nextNetwork)
        Task {
            await reloadCache()
            routeLoadRevision += 1
        }
    }

    func bootstrap() async {
        authSession = identityStore.load()
        await reloadCache()
        await refreshCurrentUser()
        routeLoadRevision += 1
    }

    func open(_ url: URL) {
        route = TaggrNavigation.route(from: url) ?? .feed(.hot)
        routeLoadRevision += 1
    }

    func loadCurrentRoute() async {
        switch route {
        case .feed(let mode):
            await loadFeed(mode: mode, reset: true)
        case .post(let id):
            await loadPost(id)
        case .profile(let handle):
            await loadProfile(handle)
        case .userPhotos:
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
                await refreshWallet()
                await loadStorageStatus()
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
            await loadCurrentRoute()
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

    func loadFeed(mode: TaggrFeedMode, reset: Bool) async {
        let request = beginRequest(.feed)
        let activeAPI = api
        returnFeedMode = mode
        if reset {
            authorProfileRetryAfter.removeAll()
        }
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let pageSize = self.cache?.config?.feedPageSize ?? 30
                let page = reset ? 0 : max(self.feed.count / max(pageSize, 1), 0)
                let offset = reset ? 0 : (self.feed.first?.id ?? 0)
                let posts: [TaggrPost]
                switch mode {
                case .hot:
                    posts = try await self.loadPostEnvelopes("hot_posts", args: [activeAPI.domain, "", page, offset, true], identity: nil, api: activeAPI)
                case .latest:
                    posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, "", page, offset, true], identity: nil, api: activeAPI)
                case .personal:
                    if let authSession = self.authSession {
                        posts = try await self.loadPostEnvelopes("personal_feed", args: [activeAPI.domain, page, offset], identity: authSession, api: activeAPI)
                    } else {
                        posts = []
                    }
                case .realm(let name):
                    posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, name, page, offset, true], identity: nil, api: activeAPI)
                case .tags(let tokens):
                    posts = try await self.loadPostEnvelopes("posts_by_tags", args: [activeAPI.domain, "", tokens, page, offset], identity: nil, api: activeAPI)
                }
                guard self.isCurrentRequest(request) else { return }
                self.feed = reset ? posts : self.feed + posts
                self.canLoadMoreFeed = posts.count >= pageSize
            }
        }
    }

    func loadMoreFeed(mode: TaggrFeedMode) async {
        guard canLoadMoreFeed else { return }
        await loadFeed(mode: mode, reset: false)
    }

    func navigateToPost(_ id: Int, from mode: TaggrFeedMode? = nil) {
        if let mode {
            returnFeedMode = mode
        }
        route = .post(id)
    }

    func navigateToFeed(_ mode: TaggrFeedMode) {
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

    func loadNotificationPost(_ id: Int) async throws -> TaggrPost? {
        try await loadPostEnvelopes("posts", args: [[id]], identity: nil).first
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

    func loadPost(_ id: Int) async {
        let request = beginRequest(.post)
        let activeAPI = api
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let thread = try await self.loadPostEnvelopes("thread", args: [id], identity: nil, api: activeAPI)
                guard self.isCurrentRequest(request) else { return }
                self.focusedPost = thread.first
                self.feed = thread
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
            let replies: [TaggrPost]
            if !post.children.isEmpty {
                replies = try await loadPostEnvelopes("posts", args: [post.children], identity: nil, api: activeAPI)
            } else {
                replies = []
            }
            guard isCurrentRuntimeGeneration(generation) else { return }
            repliesByPostID[post.id] = replies
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            NSLog("TAGGR replies load failed: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func refreshReplyThread(postID: Int) async {
        let generation = runtimeGeneration
        let activeAPI = api
        loadingReplyPostIDs.insert(postID)
        defer { loadingReplyPostIDs.remove(postID) }
        do {
            let thread = try await loadPostEnvelopes("thread", args: [postID], identity: nil, api: activeAPI)
            guard isCurrentRuntimeGeneration(generation) else { return }
            repliesByPostID[postID] = Array(thread.dropFirst())
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            NSLog("TAGGR reply thread refresh failed: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func loadProfile(_ handle: String) async {
        let request = beginRequest(.profile)
        let activeAPI = api
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let loadedProfile = try await activeAPI.query("user", args: [activeAPI.domain, [handle]], as: TaggrUser.self)
                guard self.isCurrentRequest(request) else { return }
                self.profile = loadedProfile
                if let loadedProfile {
                    self.cacheAuthorProfile(loadedProfile)
                }
            }
        }
    }

    func loadUserPosts(handle: String, page: Int, offset: Int) async throws -> [TaggrPost] {
        try await loadPostEnvelopes("user_posts", args: [api.domain, handle, page, offset], identity: nil)
    }

    func loadJournalPosts(handle: String, page: Int, offset: Int) async throws -> [TaggrPost] {
        try await loadPostEnvelopes("journal", args: [api.domain, handle, page, offset], identity: nil)
    }

    func avatarURLString(for post: TaggrPost) -> String? {
        if let authorAvatarURL = post.meta.authorAvatarURL {
            return authorAvatarURL
        }
        if currentUser?.id == post.user {
            return currentUser?.avatarURLString
        }
        return authorProfilesByUserID[post.user]?.avatarURLString
    }

    func authorDisplayName(for post: TaggrPost) -> String {
        if let authorName = post.meta.authorName, !authorName.isEmpty {
            return authorName
        }
        if let profile = authorProfilesByUserID[post.user] {
            return profile.name
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
        if let profile = authorProfilesByUserID[post.user] {
            return profile.name
        }
        if let authorName = authorNamesByUserID[post.user] {
            return authorName
        }
        return nil
    }

    func prefetchAuthorProfile(for post: TaggrPost) async {
        let generation = runtimeGeneration
        let activeAPI = api
        guard avatarURLString(for: post) == nil else { return }
        guard authorProfilesByUserID[post.user] == nil else { return }
        guard !loadingAuthorProfileIDs.contains(post.user) else { return }
        if let retryAfter = authorProfileRetryAfter[post.user], retryAfter > Date.now {
            return
        }
        if let currentUser, currentUser.id == post.user {
            cacheAuthorProfile(currentUser)
            return
        }

        loadingAuthorProfileIDs.insert(post.user)
        defer { loadingAuthorProfileIDs.remove(post.user) }

        do {
            guard let handle = try await resolveAuthorName(for: post, generation: generation, api: activeAPI) else {
                guard isCurrentRuntimeGeneration(generation) else { return }
                delayAuthorProfileRetry(for: post.user)
                return
            }
            guard let profile = try await activeAPI.query("user", args: [activeAPI.domain, [handle]], as: TaggrUser.self),
                  profile.id == post.user else {
                guard isCurrentRuntimeGeneration(generation) else { return }
                delayAuthorProfileRetry(for: post.user)
                return
            }
            guard isCurrentRuntimeGeneration(generation) else { return }
            cacheAuthorProfile(profile)
        } catch {
            guard isCurrentRuntimeGeneration(generation) else { return }
            guard !isCancellation(error) else { return }
            NSLog("TAGGR author profile prefetch failed: %@", error.localizedDescription)
            delayAuthorProfileRetry(for: post.user)
        }
    }

    func updateCurrentUserAvatarURL(_ rawURL: String?) async {
        await runBusy {
            guard let currentUser else {
                throw TaggrAPIError.rejected("Create a TAGGR user before setting an icon.")
            }
            let normalized = try TaggrAvatar.validatedURLString(rawURL ?? "")
            var settings = currentUser.settings
            if let normalized {
                settings[TaggrAvatar.settingKey] = normalized
            } else {
                settings.removeValue(forKey: TaggrAvatar.settingKey)
            }
            _ = try await api.updateJSON("update_user_settings", args: [settings], identity: authSession)
            try await loadCurrentUserIfNeeded()
            if profile?.id == currentUser.id {
                profile = self.currentUser
            }
            if let refreshedUser = self.currentUser {
                cacheAuthorProfile(refreshedUser)
            }
        }
    }

    func loadRealmsList() async {
        let request = beginRequest(.realm)
        let generation = request.runtimeGeneration
        let activeAPI = api
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                if self.authSession != nil && self.currentUser == nil {
                    try await self.loadCurrentUserIfNeeded(generation: generation, api: activeAPI)
                }
                guard self.isCurrentRequest(request) else { return }
                let ids = self.currentUser?.realms ?? []
                guard !ids.isEmpty else {
                    self.realms = []
                    self.feed = []
                    return
                }
                let values = try await activeAPI.query("realms", args: [ids], as: [TaggrRealm].self) ?? []
                guard self.isCurrentRuntimeGeneration(generation) else { return }
                self.realms = values
                self.feed = []
            }
        }
    }

    func loadAllRealmsList() async {
        let request = beginRequest(.realm)
        let activeAPI = api
        await executeRequest(request) {
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let values = try await activeAPI.query(
                    "all_realms",
                    args: [activeAPI.domain, "popularity", 0],
                    as: [TaggrRealmListEntry].self
                ) ?? []
                guard self.isCurrentRequest(request) else { return }
                self.realms = values.map(\.namedRealm)
                self.feed = []
            }
        }
    }

    func loadRealm(_ name: String) async {
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
            await self.runBusy(validWhile: { self.isCurrentRequest(request) }) {
                let values = try await activeAPI.query("realms", args: [[normalized]], as: [TaggrRealm].self) ?? []
                let posts = try await self.loadPostEnvelopes("last_posts", args: [activeAPI.domain, normalized, 0, 0, true], identity: nil, api: activeAPI)
                guard self.isCurrentRequest(request) else { return }
                self.realms = values.map { realm in
                    TaggrRealm(
                        name: realm.name.isEmpty ? normalized : realm.name,
                        description: realm.description,
                        labelColor: realm.labelColor,
                        logo: realm.logo,
                        numMembers: realm.numMembers,
                        numPosts: realm.numPosts
                    )
                }
                self.feed = posts
            }
        }
    }

}
