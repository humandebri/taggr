import PhotosUI
import SwiftUI

struct RealmDetailView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var showingJoinConfirmation = false
    @State private var showingLeaveConfirmation = false
    @State private var showingManagement = false
    let realmName: String

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Button("Realms", action: showRealmList)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.clickable)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    if let realm = currentRealm {
                        RealmDetailHeader(realm: realm)
                        RealmDetailAbout(realm: realm)
                        Text("Posts")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                            .padding(.horizontal, 16)
                        if state.feed.isEmpty {
                            Text("No posts")
                                .font(.subheadline)
                                .foregroundStyle(TaggrTheme.secondaryText)
                                .padding(.horizontal, 16)
                        } else {
                            ForEach(state.feed) { post in
                                PostRow(post: post) {
                                    state.navigateToPost(post.id, from: .realm(realm.name))
                                }
                            }
                        }
                    } else if state.isBusy {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        Text("Realm not found.")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                            .padding(16)
                    }
                }
                .padding(.bottom, 16)
            }
            .taggrRefreshable()
        }
        .taggrNavigationChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let realm = currentRealm {
                    realmMenu(realm)
                }
            }
        }
        .confirmationDialog(
            "Join \(currentRealm?.name ?? realmName)?",
            isPresented: $showingJoinConfirmation,
            titleVisibility: .visible
        ) {
            Button("Agree and Join") {
                updateMembership(joined: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let realm = currentRealm {
                Text(
                    "By joining, you agree to the Realm description and rules. Rule violations may remove a post and charge up to \(realm.cleanupPenalty) credits and reward points."
                )
            }
        }
        .confirmationDialog(
            "Leave \(currentRealm?.name ?? realmName)?",
            isPresented: $showingLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Realm", role: .destructive) {
                updateMembership(joined: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can continue reading this Realm and join it again later.")
        }
        .sheet(isPresented: $showingManagement) {
            if let realm = currentRealm {
                RealmManagementView(realm: realm)
            }
        }
        .task(id: currentRealm?.controllers) {
            await loadControllerNames()
        }
    }

    private var currentRealm: TaggrRealm? {
        state.realms.first { $0.name.uppercased() == realmName.uppercased() } ?? state.realms.first
    }

    private func showRealmList() {
        state.route = .realm("")
    }

    private var isJoined: Bool {
        state.isJoinedRealm(realmName)
    }

    private var isController: Bool {
        state.canManageRealm(realmName)
    }

    @ViewBuilder
    private func realmMenu(_ realm: TaggrRealm) -> some View {
        Menu {
            ShareLink(item: TaggrNavigation.universalURL(for: .realm(realm.name))) {
                Label("Share Realm", systemImage: "square.and.arrow.up")
            }
            if state.currentUser == nil {
                Button {
                    state.selectRootRoute(.settings)
                } label: {
                    Label("Sign in to Join", systemImage: "person.crop.circle")
                }
            } else if isJoined {
                Button(role: .destructive) {
                    showingLeaveConfirmation = true
                } label: {
                    Label("Leave Realm", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    showingJoinConfirmation = true
                } label: {
                    Label("Join Realm", systemImage: "person.badge.plus")
                }
            }
            if isController {
                Divider()
                Button {
                    showingManagement = true
                } label: {
                    Label("Manage Realm", systemImage: "slider.horizontal.3")
                }
                .disabled(!realm.hasCompleteSettings)
            }
        } label: {
            Image(systemName: state.realmMembershipOperation == nil ? "ellipsis.circle" : "progress.indicator")
                .accessibilityLabel("Realm actions")
        }
        .disabled(state.realmMembershipOperation != nil)
    }

    private func updateMembership(joined: Bool) {
        Task {
            _ = await state.setRealmMembership(name: realmName, joined: joined)
        }
    }

    @MainActor
    private func loadControllerNames() async {
        guard let realm = currentRealm else { return }
        let missingIDs = realm.controllers.filter {
            $0 != state.currentUser?.id && state.authorNamesByUserID[$0] == nil
        }
        guard !missingIDs.isEmpty else { return }
        _ = try? await state.loadAuthorNames(
            userIDs: missingIDs,
            generation: state.runtimeGeneration,
            api: state.api
        )
    }
}

private struct RealmDetailHeader: View {
    let realm: TaggrRealm

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RealmBadgeView(realm: realm, size: 72)
            VStack(alignment: .leading, spacing: 10) {
                Text(realm.name)
                    .font(.title2.weight(.black))
                    .foregroundStyle(TaggrTheme.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let numMembers = realm.numMembers {
                        RealmStatBadge(label: "\(numMembers.formatted()) members")
                    }
                    if let numPosts = realm.numPosts {
                        RealmStatBadge(label: "\(numPosts.formatted()) posts")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
    }
}

private struct RealmDetailAbout: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let realm: TaggrRealm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            TaggrMarkdownText(text: realm.description)
                .font(.subheadline)
                .foregroundStyle(TaggrTheme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
            Divider().overlay(TaggrTheme.panelRaised)
            RealmInfoRow(label: "Clean-up penalty", value: "\(realm.cleanupPenalty.formatted()) credits")
            RealmInfoRow(label: "Posting", value: postingRestriction)
            RealmInfoRow(label: "Comments", value: realm.commentsFiltering ? "Realm posting rules apply" : "Open to everyone")
            RealmInfoRow(label: "Adult content", value: realm.adultContent ? "Allowed" : "Not allowed")
            VStack(alignment: .leading, spacing: 6) {
                Text("Controllers")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                if realm.controllers.isEmpty {
                    Text("No controllers")
                        .font(.subheadline)
                        .foregroundStyle(TaggrTheme.text)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(realm.controllers, id: \.self) { userID in
                            controllerButton(userID)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    private var postingRestriction: String {
        if !realm.whitelist.isEmpty {
            return "Limited to \(realm.whitelist.count.formatted()) approved users"
        }
        var rules: [String] = []
        if realm.filter.safe { rules.append("non-controversial users") }
        if realm.filter.balance > 0 { rules.append("balance ≥ \(realm.filter.balance.formatted())") }
        if realm.filter.ageDays > 0 { rules.append("account age ≥ \(realm.filter.ageDays.formatted()) days") }
        if realm.filter.numFollowers > 0 { rules.append("followers ≥ \(realm.filter.numFollowers.formatted())") }
        return rules.isEmpty ? "Open to all members" : rules.joined(separator: ", ")
    }

    @ViewBuilder
    private func controllerButton(_ userID: Int) -> some View {
        let name = state.currentUser?.id == userID ? state.currentUser?.name : state.authorNamesByUserID[userID]
        if let name {
            Button("@\(name)") {
                state.navigateToProfile(name, from: .realm(realm.name))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(TaggrTheme.clickable)
        } else {
            Text("@\(userID)")
                .font(.caption.monospaced())
                .foregroundStyle(TaggrTheme.secondaryText)
        }
    }
}

private struct RealmInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(TaggrTheme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct RealmManagementView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaggrRealmSettingsDraft
    @State private var selectedLogo: PhotosPickerItem?
    @State private var localError: String?
    let realm: TaggrRealm

    init(realm: TaggrRealm) {
        self.realm = realm
        _draft = State(initialValue: TaggrRealmSettingsDraft(realm: realm))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.caption.weight(.bold))
                        TextEditor(text: $draft.description)
                            .frame(minHeight: 140)
                        Text("\(draft.description.count.formatted()) / 2,000")
                            .font(.caption)
                            .foregroundStyle(draft.description.count > 2_000 ? .red : TaggrTheme.secondaryText)
                    }
                    TextField("Label color (#RRGGBB)", text: $draft.labelColor)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: draft.labelColor) ?? TaggrTheme.panelRaised)
                            .frame(width: 36, height: 36)
                        PhotosPicker(selection: $selectedLogo, matching: .images) {
                            Label("Replace Logo", systemImage: "photo")
                        }
                    }
                }

                Section("Moderation") {
                    Toggle("Adult content", isOn: $draft.adultContent)
                    Toggle(
                        "Allow comments from everyone",
                        isOn: Binding(
                            get: { !draft.commentsFiltering },
                            set: { draft.commentsFiltering = !$0 }
                        )
                    )
                    TextField("Clean-up penalty", value: $draft.cleanupPenalty, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Maximum downvotes", value: $draft.maxDownvotes, format: .number)
                        .keyboardType(.numberPad)
                    if let maximum = state.cache?.config?.maxRealmCleanupPenalty {
                        Text("Maximum clean-up penalty: \(maximum.formatted()) credits")
                            .font(.caption)
                            .foregroundStyle(TaggrTheme.secondaryText)
                    }
                }

                if let localError {
                    Section {
                        Text(localError)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TaggrTheme.background)
            .navigationTitle("Manage \(realm.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(state.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.bold)
                    .disabled(state.isBusy)
                }
            }
            .onChange(of: selectedLogo) { _, item in
                guard let item else { return }
                Task { await loadLogo(item) }
            }
            .taggrBusyOverlay(state.isBusy)
            .taggrNavigationChrome()
            .interactiveDismissDisabled(state.isBusy)
        }
    }

    private func save() {
        localError = nil
        Task {
            if await state.saveRealmSettings(draft, realm: realm) {
                dismiss()
            } else {
                localError = state.errorMessage ?? "Realm settings could not be saved."
            }
        }
    }

    @MainActor
    private func loadLogo(_ item: PhotosPickerItem) async {
        localError = nil
        guard let source = try? await item.loadTransferable(type: Data.self) else {
            localError = "The selected logo could not be loaded."
            return
        }
        let maxEncodedLength = state.cache?.config?.maxRealmLogoLen ?? 16 * 1_024
        let maxImageBytes = max(1, (maxEncodedLength / 4 * 3) - 2)
        guard let normalized = ImageDrafts.normalizedImageData(source, maxBytes: maxImageBytes) else {
            localError = "The selected logo could not be resized below the Realm logo limit."
            return
        }
        let encoded = normalized.base64EncodedString()
        guard encoded.utf8.count <= maxEncodedLength else {
            localError = "The selected logo is larger than the Realm logo limit."
            return
        }
        draft.logo = encoded
    }
}

private struct RealmStatBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(TaggrTheme.text)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(TaggrTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

@MainActor
struct RealmBadgeView: View {
    private static let logoCache = NSCache<NSString, UIImage>()
    let realm: TaggrRealm
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: realm.labelColor) ?? TaggrTheme.accent)
            if let image = realmLogo {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text(initials)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let letters = realm.name
            .filter { $0.isLetter || $0.isNumber }
            .prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    private var realmLogo: UIImage? {
        guard let logo = realm.logo else { return nil }
        if let cached = Self.logoCache.object(forKey: logo as NSString) {
            return cached
        }
        guard
              let data = Data(base64Encoded: logo, options: .ignoreUnknownCharacters) else {
            return nil
        }
        guard let image = UIImage(data: data) else { return nil }
        Self.logoCache.setObject(image, forKey: logo as NSString)
        return image
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6,
              let integer = UInt64(value, radix: 16) else {
            return nil
        }
        let red = Double((integer >> 16) & 0xff) / 255.0
        let green = Double((integer >> 8) & 0xff) / 255.0
        let blue = Double(integer & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
