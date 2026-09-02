import SwiftUI

struct TaggrReactionGroup: Identifiable, Equatable {
    let id: Int
    let emoji: String
    let userIDs: [Int]

    static func groups(reactions: [String: [Int]], order: [Int]) -> [TaggrReactionGroup] {
        reactions.compactMap { key, userIDs in
            guard let id = Int(key), let emoji = TaggrReactionIcon.emoji(for: id) else { return nil }
            return TaggrReactionGroup(id: id, emoji: emoji, userIDs: userIDs)
        }
        .sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.id) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs.id) ?? Int.max
            return lhsIndex == rhsIndex ? lhs.id < rhs.id : lhsIndex < rhsIndex
        }
    }
}

struct PostReactionDetailsView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let post: TaggrPost
    @State private var loadingNames = false
    @State private var nameLoadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REACTIONS")
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)

            if loadingNames {
                ProgressView("Loading names")
                    .tint(TaggrTheme.clickable)
                    .foregroundStyle(TaggrTheme.secondaryText)
            }

            if nameLoadFailed {
                Text("Some names could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(TaggrTheme.secondaryText)
            }

            ForEach(reactionGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.emoji) \(group.userIDs.count)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TaggrTheme.text)

                    ForEach(group.userIDs, id: \.self) { userID in
                        let profileHandle = state.authorProfileHandle(for: userID)
                        Button {
                            openProfile(userID)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle")
                                    .foregroundStyle(TaggrTheme.secondaryText)
                                Text(displayName(for: userID))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(
                                        profileHandle == nil ? TaggrTheme.secondaryText : TaggrTheme.clickable
                                    )
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40)
                            .background(TaggrTheme.darkPanel)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(profileHandle == nil)
                        .accessibilityLabel(
                            profileHandle == nil
                                ? "Profile unavailable for \(displayName(for: userID))"
                                : "Open profile for \(displayName(for: userID))"
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: userIDs) {
            await loadNames()
        }
    }

    var reactionOrder: [Int] {
        let configuredOrder = state.cache?.config?.reactions?.compactMap { $0.first } ?? []
        return configuredOrder.isEmpty ? TaggrReactionIcon.defaultOrder : configuredOrder
    }

    var reactionGroups: [TaggrReactionGroup] {
        TaggrReactionGroup.groups(reactions: post.reactions, order: reactionOrder)
    }

    var userIDs: [Int] {
        Array(Set(reactionGroups.flatMap(\.userIDs))).sorted()
    }

    func displayName(for userID: Int) -> String {
        if state.currentUser?.id == userID, let name = state.currentUser?.name {
            return name
        }
        return state.authorNamesByUserID[userID] ?? "@\(userID)"
    }

    func openProfile(_ userID: Int) {
        guard let handle = state.authorProfileHandle(for: userID) else { return }
        state.navigateToProfile(handle)
    }

    @MainActor
    func loadNames() async {
        nameLoadFailed = false
        let missingIDs = userIDs.filter {
            $0 != state.currentUser?.id && state.authorNamesByUserID[$0] == nil
        }
        guard !missingIDs.isEmpty else { return }
        loadingNames = true
        do {
            let loadedNames = try await state.loadAuthorNames(
                userIDs: missingIDs,
                generation: state.runtimeGeneration,
                api: state.api
            )
            nameLoadFailed = missingIDs.contains { loadedNames[$0] == nil }
        } catch {
            nameLoadFailed = true
        }
        loadingNames = false
    }
}
