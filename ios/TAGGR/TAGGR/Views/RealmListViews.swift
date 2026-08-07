import SwiftUI

struct AvatarView: View {
    let name: String
    let avatarURLString: String?
    let size: CGFloat

    init(name: String, avatarURLString: String? = nil, size: CGFloat = 38) {
        self.name = name
        self.avatarURLString = TaggrAvatar.normalizedURLString(avatarURLString)
        self.size = size
    }

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
            .frame(width: size, height: size)
            .background(TaggrTheme.panelRaised)
            .clipShape(Circle())
            .contentShape(Circle())
            .accessibilityLabel("\(name) icon")
    }

    var avatarURL: URL? {
        avatarURLString.flatMap(URL.init(string:))
    }

    var placeholder: some View {
        ZStack {
            Circle()
                .fill(TaggrTheme.panelRaised)
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(TaggrTheme.secondaryText)
                .padding(size * 0.18)
        }
    }
}

struct RealmsView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var realmName = ""
    @State private var showingAllRealms = false

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        TextField("REALM", text: $realmName)
                            .textInputAutocapitalization(.characters)
                            .textFieldStyle(.plain)
                            .foregroundStyle(TaggrTheme.text)
                            .padding(12)
                            .background(TaggrTheme.panelRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            let name = realmName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            guard !name.isEmpty else { return }
                            state.route = .realm(name)
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.body.weight(.bold))
                                .foregroundStyle(TaggrTheme.accentText)
                                .frame(width: 42, height: 42)
                                .background(TaggrTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    ForEach(state.realms) { realm in
                        HStack(alignment: .top, spacing: 12) {
                            RealmBadgeView(realm: realm, size: 42)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("# \(realm.name.lowercased())")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(TaggrTheme.text)
                                TaggrMarkdownText(text: realm.description)
                                    .font(.subheadline)
                                    .foregroundStyle(TaggrTheme.secondaryText)
                                Button("Open feed") {
                                    state.navigateToRealm(realm.name)
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TaggrTheme.clickable)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TaggrTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if state.realms.isEmpty, !state.isBusy {
                        ContentUnavailableView(
                            showingAllRealms ? "No realms" : "No joined realms",
                            systemImage: "circle.grid.2x2"
                        )
                        .foregroundStyle(TaggrTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                    }
                    Button {
                        showingAllRealms.toggle()
                        Task {
                            if showingAllRealms {
                                await state.loadAllRealmsList()
                            } else {
                                await state.loadRealmsList()
                            }
                        }
                    } label: {
                        Label(showingAllRealms ? "Show joined realms" : "Browse all realms", systemImage: "circle.grid.2x2")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(TaggrTheme.clickable)
                }
                .padding(16)
            }
            .taggrRefreshable {
                if showingAllRealms {
                    await state.loadAllRealmsList()
                }
            }
        }
        .taggrNavigationChrome()
    }
}
