import SwiftUI

struct ProfileView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var showingReport = false
    @State private var blockConfirmationPresented = false
    @State private var presentedRealmList: ProfileRealmList?
    @State private var journalPosts: [TaggrPost] = []
    @State private var journalPage = 0
    @State private var journalOffset = 0
    @State private var journalCanLoadMore = false
    @State private var journalIsLoading = false

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
        .task(id: profileHandle) {
            await loadJournalForCurrentProfile()
        }
        .taggrRefreshable {
            await reloadJournal()
        }
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

    @ViewBuilder private func profileActionRow(_ user: TaggrUser) -> some View {
        if canShowPhotos(user) || canModerate(user) {
            HStack(spacing: 10) {
                if canShowPhotos(user) { profilePhotosButton(user) }
                if canModerate(user) { profileMoreActionsMenu(user) }
            }
        }
    }

    private func profileMoreActionsMenu(_ user: TaggrUser) -> some View {
        Menu {
            Button(role: isBlocked(user) ? nil : .destructive) {
                blockConfirmationPresented = true
            } label: {
                Label(
                    isBlocked(user) ? "Unblock" : "Block",
                    systemImage: isBlocked(user) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark"
                )
            }
            Button(role: .destructive) {
                showingReport = true
            } label: {
                Label("Report", systemImage: "exclamationmark.bubble")
            }
        } label: {
            Label("More actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TaggrTheme.text)
                .frame(width: 42, height: 42)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(state.isBusy)
    }

    private var blockConfirmationTitle: String {
        guard let user = state.profile else { return "Block user?" }
        return isBlocked(user) ? "Unblock \(user.name)?" : "Block \(user.name)?"
    }

    private var blockConfirmationMessage: String {
        guard let user = state.profile else { return "" }
        return isBlocked(user)
            ? "You will be able to see \(user.name)'s content again."
            : "\(user.name)'s content will immediately be hidden in this app, and the iOS safety operator will be notified."
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
            profileStat("Follows", value: follows),
            profileStat("Followers", value: user.followers.count),
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Journal")
                    .font(.headline.weight(.black))
                    .foregroundStyle(TaggrTheme.text)
                Spacer()
                if Self.showsJournalHeaderSpinner(isLoading: journalIsLoading, hasPosts: !journalPosts.isEmpty) {
                    ProgressView()
                        .tint(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(TaggrTheme.panel)
            if journalPosts.isEmpty && !journalIsLoading {
                Text("No posts")
                    .font(.headline)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaggrTheme.background)
            } else {
                ForEach(journalPosts) { post in
                    PostRow(post: post) {
                        state.navigateToPost(post.id, from: .latest)
                    }
                }
                if journalCanLoadMore {
                    TaggrLoadMoreView(loading: journalIsLoading, height: 44, load: loadMoreJournalPosts)
                }
            }
        }
    }

    private func profileStat(_ label: String, value: Int, realms: [String] = []) -> ProfileStatistic? {
        guard value > 0 else { return nil }
        return ProfileStatistic(label: label, value: value.formatted(), realms: realms)
    }

    private func profileTokenStat(_ label: String, value: Int) -> ProfileStatistic? {
        value > 0 ? ProfileStatistic(label: label, value: TaggrTokenAmount.format(value, decimals: state.cache?.config?.tokenDecimals)) : nil
    }

    @ViewBuilder private func profileStatCard(_ stat: ProfileStatistic) -> some View {
        if !stat.realms.isEmpty {
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

    private var profileHandle: String? {
        guard case .profile(let handle) = state.route else { return nil }
        return handle
    }

    private func loadJournalForCurrentProfile() async {
        guard let handle = profileHandle else { return }
        resetJournalPosts()
        await loadJournalPosts(handle: handle, reset: true)
    }

    private func reloadJournal() async {
        guard let handle = profileHandle else { return }
        resetJournalPosts()
        await loadJournalPosts(handle: handle, reset: true)
    }

    private func loadMoreJournalPosts() {
        guard let handle = profileHandle else { return }
        Task { await loadJournalPosts(handle: handle, reset: false) }
    }

    static func showsJournalHeaderSpinner(isLoading: Bool, hasPosts: Bool) -> Bool {
        isLoading && !hasPosts
    }

    private func loadJournalPosts(handle: String, reset: Bool) async {
        guard !journalIsLoading else { return }
        journalIsLoading = true
        defer { journalIsLoading = false }
        do {
            let page = reset ? 0 : journalPage + 1
            let offset = reset ? 0 : journalOffset
            let posts = try await state.loadJournalPosts(handle: handle, page: page, offset: offset)
            journalPosts = reset ? posts : journalPosts + posts
            journalPage = page
            if reset {
                journalOffset = posts.first?.id ?? 0
            }
            journalCanLoadMore = posts.count >= (state.cache?.config?.feedPageSize ?? 30)
        } catch {
            guard !state.isCancellation(error) else { return }
            state.errorMessage = error.localizedDescription
        }
    }

    private func resetJournalPosts() {
        journalPosts = []
        journalPage = 0
        journalOffset = 0
        journalCanLoadMore = false
    }
}

private struct ReportUserSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let user: TaggrUser
    @Binding var isPresented: Bool
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var reportConfirmationPresented = false
    @State private var requestID = UUID()
    @State private var resultMessage: String?
    @State private var received = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { isPresented = false }
                    .foregroundStyle(TaggrTheme.secondaryText)
                Spacer()
                Button("Report") { reportConfirmationPresented = true }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(canSubmit ? .red : TaggrTheme.panelRaised)
                    .clipShape(Capsule())
                    .disabled(!canSubmit || isSubmitting || state.isBusy)
            }
            Text(user.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TaggrTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $reason)
                .scrollContentBackground(.hidden)
                .foregroundStyle(TaggrTheme.text)
                .frame(minHeight: 150)
                .padding(8)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
        .padding(16)
        .background(TaggrTheme.background)
        .presentationDetents([.medium])
        .onChange(of: reason) { _, _ in requestID = UUID() }
        .alert(received ? "Report received" : "Report not sent", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { if received { isPresented = false } }
        } message: { Text(resultMessage ?? "") }
        .confirmationDialog(
            "Report \(user.name)?",
            isPresented: $reportConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Report", role: .destructive) { submit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends your report to the iOS safety operator. No tokens or credits are required.")
        }
    }

    private var canSubmit: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                try await state.report(userId: user.id, reason: trimmed, requestID: requestID)
                received = true
                resultMessage = "The iOS safety operator received your report."
            } catch { resultMessage = error.localizedDescription }
            isSubmitting = false
        }
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

    init(label: String, value: String, realms: [String] = []) {
        self.label = label
        self.value = value
        self.realms = realms
    }

    var id: String { label }
}
