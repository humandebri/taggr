import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: TaggrAppState

    var body: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { next in state.route = next.route }
        )) {
            NavigationStack {
                FeedView()
            }
            .tabItem { Label("Feed", systemImage: "list.bullet") }
            .tag(RootTab.feed)

            NavigationStack {
                RealmsView()
            }
            .tabItem { Label("Realms", systemImage: "circle.grid.2x2") }
            .tag(RootTab.realms)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
            .tag(RootTab.settings)
        }
        .overlay(alignment: .top) {
            if let message = state.errorMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(10)
                    .background(.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .sheet(isPresented: $state.showingIdentity) {
            IdentityWebView { result in
                Task { @MainActor in
                    switch result {
                    case .success(let session):
                        if TaggrRuntimeConfig.current.automateLocalIdentity {
                            NSLog("TAGGR local II completed with principal %@", session.principal)
                        }
                        await state.completeIdentity(session)
                    case .failure(let error):
                        if TaggrRuntimeConfig.current.automateLocalIdentity {
                            NSLog("TAGGR local II failed: %@", error.localizedDescription)
                        }
                        state.errorMessage = error.localizedDescription
                        state.showingIdentity = false
                    }
                }
            }
            .ignoresSafeArea()
        }
        .tint(DiscordTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var tab: RootTab {
        switch state.route {
        case .realm:
            return .realms
        case .settings:
            return .settings
        default:
            return .feed
        }
    }
}

private enum RootTab: Hashable {
    case feed
    case realms
    case settings

    var route: TaggrRoute {
        switch self {
        case .feed:
            return .feed(.hot)
        case .realms:
            return .realm("")
        case .settings:
            return .settings
        }
    }
}
