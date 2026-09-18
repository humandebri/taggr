import SwiftUI
import ICNativeClient

extension TaggrAppCoordinator {
    func returnFromFeature(fallback: TaggrRoute) {
        route = navigationStore.featureReturnRoutes.removeValue(forKey: route) ?? fallback
    }
}

@MainActor
struct TaggrFeatureContext {
    let api: TaggrAPI
    let generation: Int
    let userID: Int?
    let identity: ICAuthSession?
    let scope: String

    init(_ state: TaggrAppCoordinator) {
        api = state.api
        generation = state.runtimeGeneration
        userID = state.currentUser?.id
        identity = state.authSession
        scope = state.safetyScope
    }

    func matches(_ state: TaggrAppCoordinator) -> Bool {
        api === state.api && generation == state.runtimeGeneration &&
            userID == state.currentUser?.id && identity?.principal == state.authSession?.principal &&
            scope == state.safetyScope
    }

    func requireCurrent(_ state: TaggrAppCoordinator) throws {
        guard matches(state), !Task.isCancelled else { throw CancellationError() }
    }

    func refreshUser(_ state: TaggrAppCoordinator) async throws {
        guard let identity else { throw TaggrAPIError.missingIdentity }
        let user = try await api.featureUser(identity: identity)
        try requireCurrent(state)
        state.currentUser = user
        state.cacheAuthorName(user.name, userID: user.id)
        if state.profile?.id == user.id { state.profile = user }
    }

    func visiblePosts(_ posts: [TaggrPost], in state: TaggrAppCoordinator) async throws -> [TaggrPost] {
        try requireCurrent(state)
        let candidates = posts.filter(state.canDisplayPost)
        var safeRealms = Set<String>()
        for name in Set(candidates.compactMap(\.realm)).filter({ !$0.isEmpty }) {
            let realms = try await api.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
            try requireCurrent(state)
            if let realm = realms.first, !realm.adultContent { safeRealms.insert(name) }
        }
        return candidates.filter { post in
            post.realm.map { $0.isEmpty || safeRealms.contains($0) } ?? true
        }
    }
}

struct FeatureStatus: View {
    let loading: Bool
    let error: String?
    var retry: (() -> Void)? = nil
    var body: some View {
        if loading { ProgressView().frame(maxWidth: .infinity) }
        if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
            if let retry { Button("Retry", action: retry) }
        }
    }
}

struct FeaturePostList: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postIDs: [Int]
    var body: some View {
        ForEach(postIDs, id: \.self) { id in
            if let post = state.featurePosts.posts[id], state.canDisplayPost(post) {
                PostRow(post: post) { state.navigateToPost(post.id) }
                    .disabled(state.featurePosts.operations[id] != nil)
            }
            if let error = state.featurePosts.errors[id] {
                FeatureStatus(loading: state.featurePosts.operations[id] == .updating, error: error,
                    retry: { Task { await state.refreshFeaturePost(id) } })
            }
        }
    }
}

struct AccountFeatureLinks: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.currentUser != nil {
                Button("Edit profile", systemImage: "person.crop.circle") { editing = true }
                Button("Bookmarks", systemImage: "bookmark") { state.navigate(to: .bookmarks) }
                Button("Invites", systemImage: "person.badge.plus") { state.navigate(to: .invites) }
            }
            Button("Proposals", systemImage: "checkmark.seal") { state.navigate(to: .proposals) }
        }
        .sheet(isPresented: $editing) {
            ProfileEditView().id("\(state.safetyScope):\(state.runtimeGeneration)")
        }
    }
}
