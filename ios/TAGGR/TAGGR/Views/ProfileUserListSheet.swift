import SwiftUI

enum ProfileUserListKind: String, Identifiable {
    case follows = "Follows"
    case followers = "Followers"

    var id: String { rawValue }

    func userIDs(in user: TaggrUser) -> [Int] {
        let ids = self == .follows ? user.followees.filter { $0 != user.id } : user.followers
        return Array(Set(ids)).sorted()
    }
}

struct ProfileUserListSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var nameLoadID = UUID()
    @State private var loading = false
    @State private var loadFailed = false
    let kind: ProfileUserListKind
    let profileID: Int
    let selectUser: (Int) -> Void

    private var userIDs: [Int] {
        guard let user = state.profile, user.id == profileID else { return [] }
        return kind.userIDs(in: user)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if loading { ProgressView("Loading users") }
                    if loadFailed {
                        Text("Some names could not be loaded.")
                            .foregroundStyle(TaggrTheme.secondaryText)
                        Button("Retry") { Task { await loadNames() } }
                            .frame(minHeight: 44)
                    }
                    if userIDs.isEmpty { Text("No users") }
                    ForEach(userIDs, id: \.self) { userID in
                        HStack(spacing: 12) {
                            Button { selectUser(userID) } label: {
                                Text(state.authorProfileHandle(for: userID) ?? "@\(userID)")
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ProfileFollowButton(userID: userID)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(TaggrTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }
            .background(TaggrTheme.background)
            .foregroundStyle(TaggrTheme.text)
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task(id: userIDs) { await loadNames() }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadNames() async {
        let ids = userIDs.filter { state.authorProfileHandle(for: $0) == nil }
        guard !ids.isEmpty else { loadFailed = false; return }
        let requestID = UUID()
        nameLoadID = requestID
        loading = true
        loadFailed = false
        defer { if nameLoadID == requestID { loading = false } }
        do {
            let names = try await state.loadAuthorNames(userIDs: ids, generation: state.runtimeGeneration, api: state.api)
            guard !Task.isCancelled, nameLoadID == requestID else { return }
            loadFailed = ids.contains { names[$0] == nil }
        } catch {
            guard !state.isCancellation(error), nameLoadID == requestID else { return }
            loadFailed = true
        }
    }
}
