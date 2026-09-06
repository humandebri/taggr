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
    var runtimeGeneration = 0
    var requestSequences: [RequestScope: Int] = [:]
    var requestTasks: [RequestScope: Task<Void, Never>] = [:]
    var activeOperationIDs: Set<UUID> = []
    var latestOperationID: UUID?
    var realmMembershipOperation: String?
    var tagCostCache: [[String]: Int] = [:]
    var tagCostRequestSequence = 0
    var tagCostTask: Task<Int, Error>?
    var postSubmissionTasks: [TaggrPostSubmissionKey: Task<Void, Never>] = [:]
    var postSubmissionNoticeDismissTask: Task<Void, Never>?

    init(
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
        self.sessionStore = SessionStore(config: buildConfig)
        self.apiFactory = apiFactory
        self.identityStoreFactory = identityStoreFactory
        self.identityAuthenticatorFactory = identityAuthenticatorFactory
        self.injectedAPI = api
        self.injectedIdentityStore = identityStore
        self.injectedIdentityAuthenticator = identityAuthenticator
        self.api = api ?? apiFactory(buildConfig)
        self.identityStore = identityStore ?? identityStoreFactory(buildConfig)
        self.identityAuthenticator = identityAuthenticator ?? identityAuthenticatorFactory(buildConfig)
        self.postDraftStore = postDraftStore
        self.realmPostingPreferences = realmPostingPreferences
        self.youtubeUpload = youtubeUpload ?? YouTubeUploadCoordinator()
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
        await youtubeUpload.bootstrap()
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
        if case .post(let id) = destination {
            navigateToPost(id)
        } else {
            route = destination
        }
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

    func loadFeed(mode: TaggrFeedMode, reset: Bool, showsBusyOverlay: Bool = true) async {
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
        if let mode {
            returnFeedMode = mode
        }
        let returnRoute: TaggrRoute
        if case .post(let currentPostID) = route {
            returnRoute = postReturnRoute(for: currentPostID)
            postReturnRoutesByPostID.removeValue(forKey: currentPostID)
        } else {
            returnRoute = route
        }
        postReturnRoutesByPostID[id] = returnRoute
        route = .post(id)
    }

    func postReturnRoute(for postID: Int) -> TaggrRoute {
        postReturnRoutesByPostID[postID] ?? .feed(effectiveHomeFeedMode)
    }

    var currentPostReturnRoute: TaggrRoute {
        guard case .post(let postID) = route else {
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
        case .post:
            return "Timeline"
        }
    }

    func navigateBackFromPost() {
        guard case .post(let postID) = route else {
            navigateToHomeFeed()
            return
        }
        let destination = postReturnRoute(for: postID)
        postReturnRoutesByPostID.removeValue(forKey: postID)
        switch destination {
        case .feed(let mode):
            navigateToFeed(mode)
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
        returnFeedMode = mode
        navigationStore.rememberHomeFeedMode(mode)
        focusedPost = nil
        route = .feed(mode)
    }

    func navigateToHomeFeed() {
        navigateToFeed(effectiveHomeFeedMode)
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

    func loadPost(_ id: Int, showsBusyOverlay: Bool = true) async {
        let request = beginRequest(.post)
        let activeAPI = api
        await executeRequest(request) {
            let load = {
                let thread = try await self.loadPostEnvelopes("thread", args: [id], identity: nil, api: activeAPI)
                guard self.isCurrentRequest(request) else { return }
                self.focusedPost = thread.last
                self.feed = thread
            }
            if showsBusyOverlay {
                await self.runBusy(validWhile: { self.isCurrentRequest(request) }, load)
            } else {
                do {
                    try await load()
                } catch {
                    guard self.isCurrentRequest(request), !self.isCancellation(error) else { return }
                    NSLog("TAGGR background post refresh failed: %@", error.localizedDescription)
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

    func refreshReplyThread(postID: Int, reportsErrors: Bool = true) async {
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
            if reportsErrors {
                errorMessage = error.localizedDescription
            }
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
                    self.cacheAuthorName(loadedProfile.name, userID: loadedProfile.id)
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
