import SwiftUI

struct ProfileView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var showingReport = false
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
                            if canModerate(user) { moderationControls(user) }
                            if canShowPhotos(user) { profilePhotosButton(user) }
                            profileStats(user)
                            profileDetails(user)
                        } else {
                            Text("No profile")
                                .font(.headline)
                                .foregroundStyle(TaggrTheme.secondaryText)
                                .padding(16)
                        }
                    }
                    .padding(16)
                    if state.profile != nil {
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
    }

    private func returnToPreviousScreen() {
        state.navigateBackFromProfile()
    }

    private func profileHeader(_ user: TaggrUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(user.name)
                .font(.title2.weight(.black))
                .foregroundStyle(TaggrTheme.text)
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

    private func moderationControls(_ user: TaggrUser) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await state.toggleBlock(userId: user.id) }
            } label: {
                Label(isBlocked(user) ? "Unblock" : "Block", systemImage: isBlocked(user) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(state.isBusy)
            Button(role: .destructive) { showingReport = true } label: {
                Label("Report", systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(state.isBusy)
        }
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
            if !user.realms.isEmpty {
                Text("Realms")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(user.realms, id: \.self) { realm in
                        realmButton(realm)
                    }
                }
            }
            if !user.controlledRealms.isEmpty {
                Text("Controls realms")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(user.controlledRealms, id: \.self) { realm in
                        realmButton(realm)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func profileStats(_ user: TaggrUser) -> some View {
        let follows = max(0, user.followees.count - (user.followees.contains(user.id) ? 1 : 0))
        let stats = [
            profileStat("Posts", value: user.numPosts ?? 0),
            profileStat("Follows", value: follows),
            profileStat("Followers", value: user.followers.count),
            profileStat("Joined realms", value: user.realms.count),
            profileStat("Controls realms", value: user.controlledRealms.count),
            profileStat("Bookmarks", value: user.bookmarks.count),
            profileStat("Pinned", value: user.pinnedPosts.count),
            profileStat("Active weeks", value: user.activeWeeks ?? 0),
            profileStat("Credits", value: user.cycles ?? 0),
            profileTokenStat("Balance", value: user.balance ?? 0),
        ].compactMap { $0 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(stats, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                    Text(value)
                        .font(.headline.weight(.black))
                        .foregroundStyle(TaggrTheme.text)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TaggrTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                if journalIsLoading {
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
                    Button("More", action: loadMoreJournalPosts)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TaggrTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(16)
                        .disabled(journalIsLoading)
                }
            }
        }
    }

    private func profileStat(_ label: String, value: Int) -> (String, String)? {
        value > 0 ? (label, value.formatted()) : nil
    }

    private func profileTokenStat(_ label: String, value: Int) -> (String, String)? {
        value > 0 ? (label, TaggrTokenAmount.format(value, decimals: state.cache?.config?.tokenDecimals)) : nil
    }

    private func realmButton(_ realm: String) -> some View {
        Button {
            state.navigateToRealm(realm)
        } label: {
            Text("#\(realm.lowercased())")
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.text)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
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
        guard state.authSession != nil, let currentUser = state.currentUser else { return false }
        return currentUser.id != user.id
    }

    private func canShowPhotos(_ user: TaggrUser) -> Bool {
        (user.numPosts ?? 1) > 0
    }

    private func isBlocked(_ user: TaggrUser) -> Bool {
        state.currentUser?.blacklist.contains(user.id) == true
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

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { isPresented = false }
                    .foregroundStyle(TaggrTheme.secondaryText)
                Spacer()
                Button("Report") { submit() }
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
    }

    private var canSubmit: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await state.report(userId: user.id, reason: trimmed)
            isSubmitting = false
            if state.errorMessage == nil { isPresented = false }
        }
    }
}
