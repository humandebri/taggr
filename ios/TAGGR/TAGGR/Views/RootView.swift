import SwiftUI
import UIKit

struct RootView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var feedScrollToTopRevision = 0

    var body: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { next in
                let route = next == .feed
                    ? Self.feedRoute(lastHomeFeedMode: state.lastHomeFeedMode)
                    : next.route
                state.selectRootRoute(route)
            }
        )) {
            NavigationStack {
                FeedRouteView(scrollToTopRevision: feedScrollToTopRevision)
            }
            .background(FeedTabReselectionObserver(action: handleFeedTabReselection))
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

    static func feedRoute(lastHomeFeedMode: TaggrFeedMode) -> TaggrRoute {
        .feed(lastHomeFeedMode)
    }

    static func feedTabReselectionAction(for route: TaggrRoute) -> FeedTabReselectionAction {
        switch route {
        case .feed(.hot), .feed(.latest), .feed(.personal):
            return .scrollToTop
        default:
            return .returnToHomeFeed
        }
    }

    private func handleFeedTabReselection() {
        switch Self.feedTabReselectionAction(for: state.route) {
        case .returnToHomeFeed:
            state.navigateToHomeFeed()
        case .scrollToTop:
            feedScrollToTopRevision &+= 1
        }
    }
}

enum FeedTabReselectionAction: Equatable {
    case returnToHomeFeed
    case scrollToTop
}

private struct RouteLoadKey: Hashable {
    let route: TaggrRoute
    let revision: Int
}

private struct FeedRouteView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let scrollToTopRevision: Int

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
            FeedView(scrollToTopRevision: scrollToTopRevision)
        }
    }
}

private struct FeedTabReselectionObserver: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        ObserverViewController(action: action)
    }

    func updateUIViewController(_ viewController: ObserverViewController, context: Context) {
        viewController.action = action
        viewController.installIfPossible()
    }

    static func dismantleUIViewController(_ viewController: ObserverViewController, coordinator: ()) {
        viewController.uninstall()
    }

    final class ObserverViewController: UIViewController, UITabBarControllerDelegate {
        var action: @MainActor () -> Void
        private weak var observedTabViewController: UIViewController?
        private weak var installedTabBarController: UITabBarController?
        private weak var forwardedDelegate: (any UITabBarControllerDelegate)?

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfPossible()
        }

        func installIfPossible() {
            guard let tabBarController else { return }
            observedTabViewController = rootTabViewController(in: tabBarController)

            guard tabBarController.delegate !== self else { return }
            forwardedDelegate = tabBarController.delegate
            tabBarController.delegate = self
            installedTabBarController = tabBarController
        }

        func uninstall() {
            guard let installedTabBarController,
                  installedTabBarController.delegate === self else { return }
            installedTabBarController.delegate = forwardedDelegate
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            shouldSelect viewController: UIViewController
        ) -> Bool {
            let shouldSelect = forwardedDelegate?.tabBarController?(
                tabBarController,
                shouldSelect: viewController
            ) ?? true
            if shouldSelect,
               tabBarController.selectedViewController === viewController,
               observedTabViewController === viewController {
                DispatchQueue.main.async { [action] in action() }
            }
            return shouldSelect
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }

        private func rootTabViewController(in tabBarController: UITabBarController) -> UIViewController? {
            var candidate: UIViewController? = self
            while let current = candidate, current.parent !== tabBarController {
                candidate = current.parent
            }
            return candidate
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
