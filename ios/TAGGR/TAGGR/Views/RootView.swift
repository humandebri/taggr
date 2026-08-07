import SwiftUI

struct RootView: View {
    @Environment(TaggrAppCoordinator.self) private var state

    var body: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { next in
                let route = next == .feed
                    ? Self.feedRoute(returnFeedMode: state.returnFeedMode)
                    : next.route
                state.selectRootRoute(route)
            }
        )) {
            NavigationStack {
                FeedRouteView()
            }
            .tabItem { Label("Feed", systemImage: "list.bullet") }
            .tag(RootTab.feed)

            NavigationStack {
                RealmRouteView()
            }
            .tabItem { Label("Realms", systemImage: "circle.grid.2x2") }
            .tag(RootTab.realms)

            NavigationStack {
                InboxView()
            }
            .tabItem { Label("Inbox", systemImage: "bell") }
            .badge(state.unreadNotificationCount)
            .tag(RootTab.inbox)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
            .tag(RootTab.settings)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let route = TaggrNavigation.route(from: url) else {
                return .systemAction
            }
            state.route = route
            return .handled
        })
        .task(id: RouteLoadKey(route: state.route, revision: state.routeLoadRevision)) {
            guard state.routeLoadRevision > 0 else { return }
            await state.loadCurrentRoute()
        }
        .overlay(alignment: .top) {
            if usesFeedHeaderStatusBarColor {
                TopSafeAreaFill(color: TaggrTheme.panel)
            }
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
        .tint(TaggrTheme.clickable)
        .preferredColorScheme(.dark)
    }

    private var tab: RootTab {
        switch state.route {
        case .realm:
            return .realms
        case .inbox:
            return .inbox
        case .settings:
            return .settings
        default:
            return .feed
        }
    }

    private var usesFeedHeaderStatusBarColor: Bool {
        if case .feed = state.route {
            return true
        }
        return false
    }

    static func feedRoute(returnFeedMode: TaggrFeedMode) -> TaggrRoute {
        .feed(returnFeedMode)
    }
}

private struct RouteLoadKey: Hashable {
    let route: TaggrRoute
    let revision: Int
}

private struct FeedRouteView: View {
    @Environment(TaggrAppCoordinator.self) private var state

    var body: some View {
        switch state.route {
        case .post:
            PostDetailView()
        case .profile:
            ProfileView()
        case .userPhotos(let handle):
            UserImageLibraryView(
                handle: handle,
                title: "\(handle)'s Photos",
                backRoute: .profile(handle)
            )
        default:
            FeedView()
        }
    }
}

private struct RealmRouteView: View {
    @Environment(TaggrAppCoordinator.self) private var state

    var body: some View {
        if case .realm(let name) = state.route, !name.isEmpty {
            RealmDetailView(realmName: name)
        } else {
            RealmsView()
        }
    }
}

private enum RootTab: Hashable {
    case feed
    case realms
    case inbox
    case settings

    var route: TaggrRoute {
        switch self {
        case .feed:
            return .feed(.hot)
        case .realms:
            return .realm("")
        case .inbox:
            return .inbox
        case .settings:
            return .settings
        }
    }
}
