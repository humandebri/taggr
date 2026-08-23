import SwiftUI

struct RealmDetailView: View {
    @Environment(TaggrAppCoordinator.self) private var state
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
    }

    private var currentRealm: TaggrRealm? {
        state.realms.first { $0.name.uppercased() == realmName.uppercased() } ?? state.realms.first
    }

    private func showRealmList() {
        state.route = .realm("")
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
    let realm: TaggrRealm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            TaggrMarkdownText(text: realm.description)
                .font(.subheadline)
                .foregroundStyle(TaggrTheme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
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
