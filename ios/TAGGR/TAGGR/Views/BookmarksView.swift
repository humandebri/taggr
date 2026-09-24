import SwiftUI

struct BookmarksView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var postIDs: [Int] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading) {
                FeatureStatus(loading: loading, error: error, retry: { Task { await load() } })
                if state.currentUser == nil { Text("Sign in to view your bookmarks.") }
                else if !loading && error == nil && displayed.isEmpty { Text("No bookmarks.") }
                FeaturePostList(postIDs: displayed)
            }
        }
        .navigationTitle("Bookmarks")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Back") { state.returnFromFeature(fallback: .settings) } } }
        .task(id: "\(state.safetyScope):\(state.runtimeGeneration)") { await load() }
        .refreshable { await load() }
    }
    private var displayed: [Int] {
        let ids = Set(state.currentUser?.bookmarks ?? [])
        return postIDs.filter { ids.contains($0) }
    }
    private func load() async {
        guard !loading else { return }
        postIDs = []; error = nil
        state.featurePosts.clearPosts(keepingOperations: true)
        let listGeneration = state.featurePosts.listGeneration
        let context = TaggrFeatureContext(state)
        guard context.identity != nil, context.userID != nil else { return }
        loading = true
        defer { loading = false }
        do {
            try await context.refreshUser(state)
            let ids = state.currentUser?.bookmarks ?? []
            var fetched: [TaggrPost] = []
            var failures = 0
            for offset in stride(from: 0, to: ids.count, by: 50) {
                let chunk = Array(ids[offset..<min(offset + 50, ids.count)])
                do {
                    let values = try await state.loadPostEnvelopes("posts", args: [chunk], identity: context.identity, api: context.api)
                    fetched += try await context.visiblePosts(values, in: state)
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
                try context.requireCurrent(state)
                guard state.featurePosts.listGeneration == listGeneration else { return }
                var seen = Set<Int>()
                state.featurePosts.register(fetched)
                postIDs = fetched.filter { seen.insert($0.id).inserted }.map(\.id)
            }
            if failures > 0 { error = "Some bookmarks could not be loaded. Retry to fetch them again." }
        } catch is CancellationError {} catch { if context.matches(state) { self.error = error.localizedDescription } }
    }
}
