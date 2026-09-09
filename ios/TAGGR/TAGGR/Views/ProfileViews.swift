import SwiftUI

struct ProfileView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var showingReport = false
    @State private var blockConfirmationPresented = false
    @State private var presentedRealmList: ProfileRealmList?
    @State private var presentedUserList: ProfileUserListKind?
    @State private var creditRecipient: TaggrUser?
    @State private var muteConfirmationPresented = false

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let user = state.profile {
                            if state.isUserRestricted(user.id) {
                                Text("This user's content is unavailable.")
                                profileMoreActionsMenu(user)
                            } else {
                            profileHeader(user)
                            if user.deactivated == true {
                                Text("This account is deactivated.")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(TaggrTheme.secondaryText)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(TaggrTheme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            profileActionRow(user)
                            profileStats(user)
                            profileDetails(user)
                            }
                        } else {
                            Text("No profile")
                                .font(.headline)
                                .foregroundStyle(TaggrTheme.secondaryText)
                                .padding(16)
                        }
                    }
                    .padding(16)
                    if let user = state.profile, !state.isUserRestricted(user.id) {
                        journalSection()
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(state.profile?.name ?? "Profile")
        .taggrInlineNavigationChrome()
        .taggrBusyOverlay(state.isBusy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TaggrBackToolbarButton(title: "Back", action: returnToPreviousScreen)
            }
        }
        .taggrRefreshable()
        .sheet(isPresented: $showingReport) {
            if let user = state.profile {
                ReportUserSheet(user: user, isPresented: $showingReport)
                .environment(state)
            }
        }
        .sheet(item: $presentedRealmList) { list in
            ProfileRealmListSheet(list: list) { realm in
                presentedRealmList = nil
                state.navigateToRealm(realm)
            }
        }
        .sheet(item: $presentedUserList) { kind in
            if let profile = state.profile {
                ProfileUserListSheet(kind: kind, profileID: profile.id) { userID in
                    presentedUserList = nil
                    state.navigateToProfile(String(userID))
                }
            }
        }
        .sheet(item: $creditRecipient) { recipient in
            ProfileCreditTransferSheet(recipient: recipient)
        }
        .confirmationDialog("Mute this user?", isPresented: $muteConfirmationPresented, titleVisibility: .visible) {
            if let user = state.profile {
                Button("Mute") { Task { await state.setMutedUser(user.id, muted: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their posts will be hidden from filtered feeds and you will unfollow them. You can still open their profile. Following them again will unmute them.")
        }
        .confirmationDialog(
            blockConfirmationTitle,
            isPresented: $blockConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let user = state.profile {
                Button(isBlocked(user) ? "Unblock" : "Block", role: isBlocked(user) ? nil : .destructive) {
                    Task { await state.toggleBlock(userId: user.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(blockConfirmationMessage)
        }
    }

    private func returnToPreviousScreen() {
        state.navigateBackFromProfile()
    }

    private func profileHeader(_ user: TaggrUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(user.name)
                .font(.title2.weight(.black))
                .foregroundStyle(TaggrTheme.text)
            UserAttributeBadgesView(
                badges: TaggrUserBadge.badges(
                    for: user,
                    viewerID: state.currentUser?.id,
                    votingPowerActivityWeeks: state.cache?.config?.votingPowerActivityWeeks
                )
            )
            if !user.about.isEmpty {
                TaggrMarkdownText(text: user.about)
                    .font(.body)
                    .foregroundStyle(TaggrTheme.text)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func profileActionRow(_ user: TaggrUser) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ProfileFollowButton(userID: user.id)
                if canShowPhotos(user) { profilePhotosButton(user) }
                profileMoreActionsMenu(user)
            }
            VStack(alignment: .leading, spacing: 10) {
                ProfileFollowButton(userID: user.id)
                HStack(spacing: 10) {
                    if canShowPhotos(user) { profilePhotosButton(user) }
                    profileMoreActionsMenu(user)
                }
            }
        }
    }

    private func profileMoreActionsMenu(_ user: TaggrUser) -> some View {
        Menu {
            ShareLink(item: TaggrNavigation.universalURL(for: .profile(String(user.id)))) {
                Label("Share profile", systemImage: "square.and.arrow.up")
            }
            ShareLink(item: TaggrNavigation.journalURL(userID: user.id)) {
                Label("Share journal", systemImage: "book")
            }
            if state.canInteractWithProfile(userID: user.id) {
                Button {
                    if state.isMutedUser(user.id) {
                        Task { await state.setMutedUser(user.id, muted: false) }
                    } else {
                        muteConfirmationPresented = true
                    }
                } label: {
                    Label(state.isMutedUser(user.id) ? "Unmute" : "Mute", systemImage: "speaker.slash")
                }
                Button { creditRecipient = user } label: {
                    Label("Send credits", systemImage: "arrow.up.forward.circle")
                }
            }
            if canModerate(user) {
                Button(role: isBlocked(user) ? nil : .destructive) {
                    blockConfirmationPresented = true
                } label: {
                    Label(isBlocked(user) ? "Unblock" : "Block", systemImage: "person.crop.circle.badge.xmark")
                }
                Button(role: .destructive) { showingReport = true } label: {
                    Label("Report", systemImage: "exclamationmark.bubble")
                }
            }
        } label: {
            Label("More actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TaggrTheme.text)
                .frame(width: 44, height: 44)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(state.isBusy || state.contentStore.profileActionInFlight)
    }

    private var blockConfirmationTitle: String {
        guard let user = state.profile else { return "Block user?" }
        return isBlocked(user) ? "Unblock \(user.name)?" : "Block \(user.name)?"
    }

    private var blockConfirmationMessage: String {
        guard let user = state.profile else { return "" }
        return isBlocked(user)
            ? "Your personal block of \(user.name) will be removed."
            : "\(user.name)'s content will immediately be hidden in this app."
    }

    private func profilePhotosButton(_ user: TaggrUser) -> some View {
        Button {
            state.route = .userPhotos(user.name)
        } label: {
            Label("Photos", systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func profileDetails(_ user: TaggrUser) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let links = profileLinks(user)
            if !links.isEmpty {
                Text("Links")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                ForEach(links, id: \.url) { link in
                    if let url = URL(string: link.url) {
                        Link(link.label, destination: url)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TaggrTheme.clickable)
                    }
                }
            }
            if let principal = user.principal, !principal.isEmpty {
                Text("Principal")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                Text(principal)
                    .font(.caption.monospaced())
                    .foregroundStyle(TaggrTheme.text)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func profileStats(_ user: TaggrUser) -> some View {
        let follows = max(0, user.followees.count - (user.followees.contains(user.id) ? 1 : 0))
        let stats: [ProfileStatistic] = [
            profileStat("Posts", value: user.numPosts ?? 0),
            profileStat("Follows", value: follows, users: .follows),
            profileStat("Followers", value: user.followers.count, users: .followers),
            profileStat("Joined realms", value: user.realms.count, realms: user.realms),
            profileStat("Controls realms", value: user.controlledRealms.count, realms: user.controlledRealms),
            profileStat("Bookmarks", value: user.bookmarks.count),
            profileStat("Pinned", value: user.pinnedPosts.count),
            profileStat("Active weeks", value: user.activeWeeks ?? 0),
            profileStat("Credits", value: user.cycles ?? 0),
            profileTokenStat("Balance", value: user.balance ?? 0),
        ].compactMap { $0 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(stats) { stat in
                profileStatCard(stat)
            }
        }
    }

    private func journalSection() -> some View {
        let journal = state.contentStore
        let isLoading = state.isBusy || journal.journalIsLoading
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Journal")
                    .font(.headline.weight(.black))
                    .foregroundStyle(TaggrTheme.text)
                Spacer()
                if Self.showsJournalHeaderSpinner(isLoading: isLoading, hasPosts: !journal.journalPosts.isEmpty) {
                    ProgressView()
                        .tint(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(TaggrTheme.panel)
            if journal.journalPosts.isEmpty && !isLoading {
                Text("No posts")
                    .font(.headline)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaggrTheme.background)
            } else {
                ForEach(journal.journalPosts) { post in
                    PostRow(post: post) {
                        state.navigateToPost(post.id, from: .latest)
                    }
                }
                if journal.journalCanLoadMore {
                    TaggrLoadMoreView(loading: isLoading, height: 44) {
                        Task { await state.loadMoreProfileJournal() }
                    }
                }
            }
        }
    }

    private func profileStat(_ label: String, value: Int, realms: [String] = [], users: ProfileUserListKind? = nil) -> ProfileStatistic? {
        guard value > 0 else { return nil }
        return ProfileStatistic(label: label, value: value.formatted(), realms: realms, users: users)
    }

    private func profileTokenStat(_ label: String, value: Int) -> ProfileStatistic? {
        value > 0 ? ProfileStatistic(label: label, value: TaggrTokenAmount.format(value, decimals: state.cache?.config?.tokenDecimals)) : nil
    }

    @ViewBuilder private func profileStatCard(_ stat: ProfileStatistic) -> some View {
        if let users = stat.users {
            Button { presentedUserList = users } label: {
                profileStatCardContent(stat)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(stat.label), \(stat.value)")
            .accessibilityHint("Opens the user list")
        } else if !stat.realms.isEmpty {
            Button {
                presentedRealmList = ProfileRealmList(title: stat.label, realms: stat.realms)
            } label: {
                profileStatCardContent(stat)
            }
            .buttonStyle(.plain)
        } else {
            profileStatCardContent(stat)
        }
    }

    private func profileStatCardContent(_ stat: ProfileStatistic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            Text(stat.value)
                .font(.headline.weight(.black))
                .foregroundStyle(TaggrTheme.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func profileLinks(_ user: TaggrUser) -> [(label: String, url: String)] {
        (user.settings["links"] ?? "")
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[1].hasPrefix("https://") else { return nil }
                return (label: parts[0], url: parts[1])
            }
    }

    private func canModerate(_ user: TaggrUser) -> Bool {
        state.currentUser?.id != user.id
    }

    private func canShowPhotos(_ user: TaggrUser) -> Bool {
        (user.numPosts ?? 1) > 0
    }

    private func isBlocked(_ user: TaggrUser) -> Bool {
        state.isUserBlocked(user.id)
    }

    static func showsJournalHeaderSpinner(isLoading: Bool, hasPosts: Bool) -> Bool {
        isLoading && !hasPosts
    }
}

private struct ReportUserSheet: View {
    let user: TaggrUser
    @Binding var isPresented: Bool

    var body: some View {
        ContentReportSheet(userID: user.id, postID: nil, isPresented: $isPresented)
    }
}

private struct ProfileRealmList: Identifiable {
    let title: String
    let realms: [String]

    var id: String { title }
}

private struct ProfileRealmListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let list: ProfileRealmList
    let selectRealm: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list.realms, id: \.self) { realm in
                            Button {
                                selectRealm(realm)
                            } label: {
                                Text("#\(realm.lowercased())")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(TaggrTheme.text)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background(TaggrTheme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(list.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ProfileStatistic: Identifiable {
    let label: String
    let value: String
    let realms: [String]
    let users: ProfileUserListKind?

    init(label: String, value: String, realms: [String] = [], users: ProfileUserListKind? = nil) {
        self.label = label
        self.value = value
        self.realms = realms
        self.users = users
    }

    var id: String { label }
}
