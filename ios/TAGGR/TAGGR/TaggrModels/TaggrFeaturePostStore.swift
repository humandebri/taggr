import Foundation
import Observation

@MainActor
@Observable
final class TaggrFeaturePostStore {
    enum Operation { case updating, refreshRequired, uncertain }
    var posts: [Int: TaggrPost] = [:]
    var operations: [Int: Operation] = [:]
    var errors: [Int: String] = [:]
    private(set) var generation = UUID()
    private(set) var listGeneration = UUID()

    func clearPosts(keepingOperations: Bool = false) {
        listGeneration = UUID()
        posts = keepingOperations ? posts.filter { operations[$0.key] != nil } : [:]
    }

    func register(_ values: [TaggrPost]) {
        for post in values where posts[post.id] == nil { posts[post.id] = post }
    }

    func reset() {
        generation = UUID()
        listGeneration = UUID()
        posts = [:]; operations = [:]; errors = [:]
    }
}

extension TaggrAppCoordinator {
    func performFeaturePostMutation(id: Int, method: String, arguments: sending [Any?],
                                    transform: (TaggrPost) -> TaggrPost) async {
        let store = featurePosts
        guard store.operations[id] == nil, let previous = store.posts[id] else { return }
        let generation = store.generation
        let context = TaggrFeatureContext(self)
        guard context.identity != nil else { store.errors[id] = TaggrAPIError.missingIdentity.localizedDescription; return }
        store.operations[id] = .updating; store.errors[id] = nil
        updatePost(id, transform: transform)
        do {
            _ = try await context.api.updateJSON(method, args: arguments, identity: context.identity)
            guard context.matches(self), store.generation == generation else { return }
            store.operations[id] = .refreshRequired
            await refreshFeaturePost(id)
        } catch {
            guard context.matches(self), store.generation == generation else { return }
            if case TaggrAPIError.rejected = error {
                updatePost(id) { _ in previous }
                store.operations[id] = nil
                store.errors[id] = error.localizedDescription
            } else {
                store.operations[id] = .uncertain
                store.errors[id] = "Result unknown. Reload to check the post; the update will not be resent. " + error.localizedDescription
            }
        }
    }

    func refreshFeaturePost(_ id: Int) async {
        let store = featurePosts
        guard store.operations[id] != .updating else { return }
        let wasUncertain = store.operations[id] == .uncertain
        let generation = store.generation
        let context = TaggrFeatureContext(self)
        store.operations[id] = .updating
        do {
            let rows = try await loadPostEnvelopes("posts", args: [[id]], identity: context.identity, api: context.api)
            let visible = try await context.visiblePosts(rows, in: self)
            try context.requireCurrent(self)
            guard store.generation == generation else { return }
            if let post = visible.first(where: { $0.id == id }) {
                updatePost(id) { _ in post }
            } else {
                store.posts[id] = nil
                invalidateNotificationPost(id)
            }
            // A query cannot prove that a timed-out update will never execute later.
            store.operations[id] = wasUncertain ? .uncertain : nil
            store.errors[id] = wasUncertain ? "Latest post loaded. The earlier update is still unconfirmed; resubmission remains disabled." : nil
        } catch {
            guard context.matches(self), store.generation == generation else { return }
            store.operations[id] = wasUncertain ? .uncertain : .refreshRequired
            store.errors[id] = (wasUncertain ? "Result unknown; " : "Update saved; ") + "post refresh failed: " + error.localizedDescription
        }
    }
}
