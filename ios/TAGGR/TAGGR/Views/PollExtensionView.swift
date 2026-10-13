import SwiftUI

struct PollExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let post: TaggrPost
    let poll: TaggrPoll
    @State private var selectedOption: Int?
    @State private var changingVote = false
    @State private var loadingNames = false
    @State private var nameLoadFailed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = presentation(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Poll", systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                }

                ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                    if presentation.showsVotingControls {
                        PollVotingOptionRow(
                            title: option,
                            selected: selectedOption == index
                        ) {
                            selectedOption = index
                        }
                    } else {
                        PollResultOptionRow(
                            title: option,
                            votes: presentation.displayedVotes[index]?.count ?? 0,
                            percentage: presentation.percentage(for: index),
                            voters: userList(for: presentation.displayedVotes[index] ?? [])
                        )
                    }
                }

                if presentation.showsVotingControls {
                    HStack(spacing: 10) {
                        Button("SUBMIT ANONYMOUSLY") {
                            vote(anonymously: true)
                        }
                        .disabled(selectedOption == nil)
                        Button("SUBMIT") {
                            vote(anonymously: false)
                        }
                        .disabled(selectedOption == nil)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                }

                if !presentation.showsVotingControls {
                    if loadingNames {
                        ProgressView("Loading voters")
                            .font(.caption)
                    } else if nameLoadFailed {
                        Text("Some voter names could not be loaded.")
                            .font(.caption)
                            .foregroundStyle(TaggrTheme.secondaryText)
                    }
                }

                if !presentation.isExpired {
                    HStack(spacing: 6) {
                        Text(presentation.expirationText)
                            .foregroundStyle(TaggrTheme.secondaryText)
                        if presentation.canChangeVote {
                            Text("·")
                                .foregroundStyle(TaggrTheme.secondaryText)
                            Button("CHANGE VOTE", action: beginChangingVote)
                                .foregroundStyle(TaggrTheme.clickable)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                } else if poll.weightedByTokens.isEmpty {
                    Text("RESULTS ARE PENDING")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RESULTS BY VOTING POWER")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                        ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                            if let votingPower = presentation.votingPower(
                                for: index,
                                tokenDecimals: state.cache?.config?.tokenDecimals
                            ) {
                                HStack(alignment: .firstTextBaseline) {
                                    TaggrMarkdownText(text: option)
                                    Spacer()
                                    Text(votingPower)
                                        .font(.body.monospaced())
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .task(id: resolvableUserIDs) {
            await loadNames()
        }
        .onChange(of: poll) { _, _ in
            selectedOption = nil
            changingVote = false
        }
    }

    private var resolvableUserIDs: [Int] {
        Array(Set(poll.votes.values.flatMap { $0 }))
            .filter(TaggrPollPresentation.isResolvableUserID)
            .sorted()
    }

    private func presentation(at now: Date) -> TaggrPollPresentation {
        TaggrPollPresentation(
            poll: poll,
            postTimestamp: post.timestamp,
            userID: state.currentUser?.id,
            revoteDeadlineHours: state.cache?.config?.pollRevoteDeadlineHours ?? 0,
            changingVote: changingVote,
            now: now
        )
    }

    private func beginChangingVote() {
        selectedOption = nil
        changingVote = true
    }

    private func vote(anonymously: Bool) {
        guard let selectedOption else { return }
        changingVote = false
        self.selectedOption = nil
        Task {
            await state.voteOnPoll(postId: post.id, option: selectedOption, anonymously: anonymously)
        }
    }

    private func displayName(for userID: Int) -> String {
        guard TaggrPollPresentation.isResolvableUserID(userID) else { return "N/A" }
        if state.currentUser?.id == userID, let name = state.currentUser?.name {
            return name
        }
        return state.authorNamesByUserID[userID] ?? String(userID)
    }

    private func userList(for userIDs: [Int]) -> AttributedString {
        userIDs.enumerated().reduce(into: AttributedString()) { result, entry in
            if entry.offset > 0 {
                result.append(AttributedString(", "))
            }
            let userID = entry.element
            var name = AttributedString(displayName(for: userID))
            if TaggrPollPresentation.isResolvableUserID(userID) {
                name.foregroundColor = TaggrTheme.clickable
                name.link = URL(string: "taggr-profile://\(userID)")
            } else {
                name.foregroundColor = TaggrTheme.secondaryText
            }
            result.append(name)
        }
    }

    @MainActor
    private func loadNames() async {
        nameLoadFailed = false
        let missingIDs = resolvableUserIDs.filter {
            $0 != state.currentUser?.id && state.authorNamesByUserID[$0] == nil
        }
        guard !missingIDs.isEmpty else { return }
        loadingNames = true
        defer { loadingNames = false }
        do {
            let loaded = try await state.loadAuthorNames(
                userIDs: missingIDs,
                generation: state.runtimeGeneration,
                api: state.api
            )
            nameLoadFailed = missingIDs.contains { loaded[$0] == nil }
        } catch {
            guard !state.isCancellation(error) else { return }
            nameLoadFailed = true
        }
    }
}

private struct PollVotingOptionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? TaggrTheme.accent : TaggrTheme.secondaryText)
                TaggrMarkdownText(text: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TaggrTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(selected ? TaggrTheme.accent.opacity(0.22) : TaggrTheme.panelRaised.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PollResultOptionRow: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let title: String
    let votes: Int
    let percentage: Int
    let voters: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TaggrMarkdownText(text: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TaggrTheme.text)
                Spacer()
                Text("\(votes) (\(percentage)%)")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(TaggrTheme.panelRaised)
                    Capsule()
                        .fill(TaggrTheme.secondaryText.opacity(0.55))
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100)
                }
            }
            .frame(height: 6)
            if !voters.characters.isEmpty {
                Text(voters)
                    .font(.caption.weight(.semibold))
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "taggr-profile", let userID = Int(url.host ?? "") else {
                            return .systemAction
                        }
                        state.navigateToProfile(String(userID))
                        return .handled
                    })
            }
        }
        .padding(10)
        .background(TaggrTheme.panelRaised.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
