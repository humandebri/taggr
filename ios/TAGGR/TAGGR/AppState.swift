import Foundation
import SwiftUI

struct TaggrDraftImage: Equatable {
    let id: String
    let data: Data

    var markdown: String {
        "![image](/blob/\(id))"
    }
}

@MainActor
final class TaggrAppState: ObservableObject {
    @Published var route: TaggrRoute = .feed(.hot)
    @Published var authSession: TaggrAuthSession?
    @Published var feed: [TaggrPost] = []
    @Published var focusedPost: TaggrPost?
    @Published var profile: TaggrUser?
    @Published var realms: [TaggrRealm] = []
    @Published var cache: TaggrBackendCache?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var showingIdentity = false

    let api: TaggrAPI
    let identityStore: TaggrIdentityStore

    init(api: TaggrAPI = TaggrAPI(), identityStore: TaggrIdentityStore = TaggrIdentityStore()) {
        self.api = api
        self.identityStore = identityStore
    }

    func bootstrap() async {
        authSession = identityStore.load()
        if TaggrRuntimeConfig.current.automateLocalIdentity && authSession == nil {
            route = .settings
            showingIdentity = true
        }
        await reloadCache()
        await loadCurrentRoute()
    }

    func open(_ url: URL) {
        route = TaggrNavigation.route(from: url) ?? .feed(.hot)
        Task { await loadCurrentRoute() }
    }

    func loadCurrentRoute() async {
        switch route {
        case .feed(let mode):
            await loadFeed(mode: mode, reset: true)
        case .post(let id):
            await loadPost(id)
        case .profile(let handle):
            await loadProfile(handle)
        case .realm(let name):
            await loadRealm(name)
        case .settings:
            break
        case .readOnlyNotice:
            break
        }
    }

    func reloadCache() async {
        do {
            async let stats: TaggrStats? = api.query("stats", as: TaggrStats.self)
            async let config: TaggrConfig? = api.query("config", as: TaggrConfig.self)
            cache = TaggrBackendCache(stats: try await stats, config: try await config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadFeed(mode: TaggrFeedMode, reset: Bool) async {
        await runBusy {
            let posts: [TaggrPost]
            switch mode {
            case .hot:
                posts = try await loadPostEnvelopes("hot_posts", api.domain, "", 0, 0, true)
            case .latest:
                posts = try await loadPostEnvelopes("last_posts", api.domain, "", 0, 0, true)
            case .personal:
                if let authSession {
                    posts = try await loadPostEnvelopes("personal_feed", args: [api.domain, 0, 0], identity: authSession)
                } else {
                    posts = []
                }
            case .realm(let name):
                posts = try await loadPostEnvelopes("last_posts", api.domain, name, 0, 0, true)
            }
            feed = posts
        }
    }

    func loadPost(_ id: Int) async {
        await runBusy {
            let thread = try await loadPostEnvelopes("thread", id)
            focusedPost = thread.first
            feed = thread
        }
    }

    func loadProfile(_ handle: String) async {
        await runBusy {
            profile = try await api.query("user", api.domain, [handle], as: TaggrUser.self)
        }
    }

    func loadRealm(_ name: String) async {
        await runBusy {
            let values = try await api.query("realms", [name.uppercased()], as: [TaggrRealm].self) ?? []
            realms = values
        }
    }

    func submitPost(text: String, parent: Int? = nil, realm: String? = nil, image: TaggrDraftImage? = nil) async {
        await runBusy {
            let body = [text, image?.markdown]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if let image, parent == nil {
                _ = try await api.addPostData(text: body, realm: realm, identity: authSession)
                _ = try await api.addPostBlob(id: image.id, blob: image.data, identity: authSession)
                _ = try await api.commitPost(identity: authSession)
            } else {
                _ = try await api.addPost(text: body, parent: parent, realm: realm, identity: authSession)
            }
            await loadFeed(mode: .latest, reset: true)
        }
    }

    func react(postId: Int, reaction: Int) async {
        await runBusy {
            _ = try await api.updateJSON("react", postId, reaction, identity: authSession)
            await loadCurrentRoute()
        }
    }

    func report(postId: Int, reason: String) async {
        await runBusy {
            _ = try await api.updateJSON("report", postId, reason, identity: authSession)
        }
    }

    func toggleBlock(userId: Int) async {
        await runBusy {
            _ = try await api.updateJSON("toggle_blacklist", userId, identity: authSession)
        }
    }

    func completeIdentity(_ session: TaggrAuthSession) async {
        await runBusy {
            logLocalIdentity("signed user query starting")
            // This signed canister query is the practical verifier before the II delegation is saved.
            _ = try await api.signedQuery("user", args: [api.domain, []], identity: session, as: Optional<TaggrUser>.self)
            logLocalIdentity("signed user query succeeded")
            try identityStore.save(session)
            logLocalIdentity("session saved")
            authSession = session
            showingIdentity = false
            await reloadCache()
            await loadCurrentRoute()
        }
    }

    func signOut() {
        identityStore.clear()
        authSession = nil
    }

    private func runBusy(_ operation: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await operation()
        } catch {
            NSLog("TAGGR operation failed: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func logLocalIdentity(_ message: String) {
        if TaggrRuntimeConfig.current.automateLocalIdentity {
            NSLog("TAGGR local II %@", message)
        }
    }

    private func loadPostEnvelopes(_ method: String, _ args: Any?...) async throws -> [TaggrPost] {
        try await loadPostEnvelopes(method, args: args, identity: nil)
    }

    private func loadPostEnvelopes(_ method: String, args: [Any?], identity: TaggrAuthSession?) async throws -> [TaggrPost] {
        let rows: [TaggrPostEnvelope]?
        if let identity {
            rows = try await api.signedQuery(method, args: args, identity: identity, as: [TaggrPostEnvelope].self)
        } else {
            rows = try await api.query(method, args: args, as: [TaggrPostEnvelope].self)
        }
        return (rows ?? []).map(\.post)
    }
}
