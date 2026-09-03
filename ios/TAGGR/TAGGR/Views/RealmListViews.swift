import SwiftUI

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
                                Button {
                                    state.navigateToRealm(realm.name)
                                } label: {
                                    Text("# \(realm.name.lowercased())")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(TaggrTheme.clickable)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open realm \(realm.name)")
                                TaggrMarkdownText(text: realm.description)
                                    .font(.subheadline)
                                    .foregroundStyle(TaggrTheme.secondaryText)
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
                    if showingAllRealms, state.canLoadMoreRealms {
                        TaggrLoadMoreView(loading: state.isLoadingMoreRealms) {
                            Task { await state.loadAllRealmsList(reset: false) }
                        }
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
