import SwiftUI
import UIKit

struct RootView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var feedScrollToTopRevision = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if !state.canAccessUGC || state.safetyPolicy.map({ $0.expiresAt <= timeline.date.timeIntervalSince1970 }) != false {
                SafetyGateView()
            } else {
                tabs.id("\(state.safetyScope):\(state.safety.contentRevision)")
            }
        }
        .task(id: "\(state.safetyScope):\(scenePhase)") {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                  ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
                if state.safetySuspended { await state.youtubeUpload.cancel() }
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .task(id: "\(state.safetyScope):\(scenePhase)") {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                  ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
                  scenePhase == .active else { return }
            while !Task.isCancelled {
                await state.safety.flushBlockNotifications()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .tint(TaggrTheme.clickable)
        .preferredColorScheme(.dark)
    }

    private var tabs: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { next in
                let route = next == .feed
                    ? Self.feedRoute(lastHomeFeedMode: state.effectiveHomeFeedMode)
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
            state.navigate(to: route)
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
            VStack(spacing: 8) {
                if let message = state.errorMessage {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .padding(10)
                        .background(.red)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let notice = state.postSubmissionNotice {
                    HStack(spacing: 8) {
                        if notice.phase == .submitting {
                            ProgressView()
                                .tint(.white)
                                .accessibilityHidden(true)
                        }
                        Text(notice.message)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if notice.phase != .submitting && notice.phase != .succeeded {
                            Button("Dismiss", systemImage: "xmark", action: state.dismissPostSubmissionNotice)
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(10)
                    .background(postSubmissionNoticeColor(notice.phase))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Sign in with Internet Identity",
            isPresented: Binding(
                get: { state.identitySignInMethodPickerPresented },
                set: { state.identitySignInMethodPickerPresented = $0 }
            ),
            titleVisibility: .visible
        ) {
            ForEach(state.runtimeConfig.availableIdentitySignInMethods, id: \.self) { method in
                Button(method.title) {
                    state.startIdentitySignIn(method, reason: state.identitySignInReason)
                }
            }
        } message: {
            if let reason = state.identitySignInReason {
                Text(reason)
            } else {
                Text("Choose a sign-in method.")
            }
        }
        .tint(TaggrTheme.clickable)
        .preferredColorScheme(.dark)
    }

    private func postSubmissionNoticeColor(_ phase: TaggrPostSubmissionPhase) -> Color {
        switch phase {
        case .submitting:
            TaggrTheme.panelRaised
        case .succeeded:
            .green
        case .retryableFailure:
            .red
        case .uncertain:
            .orange
        }
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

struct SafetyLinksView: View {
    var body: some View {
        Link("Terms of Use", destination: TaggrSafetyStore.siteURL.appendingPathComponent("terms"))
        Link("Privacy Policy", destination: TaggrSafetyStore.siteURL.appendingPathComponent("privacy-policy"))
        Link("Contact / appeal a restriction", destination: TaggrSafetyStore.siteURL.appendingPathComponent("safety"))
    }
}

private struct SafetyGateView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var agrees = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(state.acceptedSafetyTerms ? (state.safetySuspended ? "Account suspended" : "Safety check unavailable") : "Terms & safety")
                    .font(.largeTitle.bold())
                if !state.acceptedSafetyTerms {
                    Text("Objectionable content and abusive behavior are not tolerated. Do not post pornography, exploitation, threats, hateful abuse, harassment, or illegal material. NSFW posts are unavailable in this iOS app.")
                    Text("Report posts or users without a token or credit requirement. Blocking immediately hides their content and notifies the iOS operator. The operator reviews reports and acts on violations within 24 hours, removing content and suspending responsible users in the official iOS app. These actions do not delete data or accounts from the decentralized TAGGR network.")
                    SafetyLinksView()
                    Toggle("I agree to the Terms of Use and safety rules", isOn: $agrees)
                    Button("Agree and continue") { state.safety.accept(scope: state.safetyScope) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!agrees)
                } else {
                    Text(state.safetySuspended ? "Your access to the official TAGGR iOS app is suspended. You can contact the operator to appeal. Your on-chain account is not deleted." : "We need a recent safety policy before displaying or publishing posts. Check your connection and retry.")
                    SafetyLinksView()
                    Button("Retry safety check") {
                        Task {
                            if state.safetyUserUnconfirmed { await state.refreshCurrentUser() }
                            await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
                        }
                    }
                }
                if state.authSession != nil { Button("Sign out", role: .destructive) { state.signOut() } }
            }
            .padding(24)
        }
        .background(TaggrTheme.background)
        .onChange(of: state.safetyScope) { _, _ in agrees = false }
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
