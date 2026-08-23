import Foundation
import SwiftUI

@main
struct TAGGRApp: App {
    @UIApplicationDelegateAdaptor(TaggrApplicationDelegate.self) private var appDelegate
    @State private var state: TaggrAppCoordinator

    init() {
        let preferences = TaggrRuntimeNetworkPreferences()
        let postDraftStore = PostDraftStore()
        let buildConfig = TaggrRuntimeConfig.current
        _state = State(
            initialValue: TaggrAppCoordinator(
                postDraftStore: postDraftStore,
                buildConfig: buildConfig,
                initialNetwork: preferences.load(),
                persistRuntimeNetwork: preferences.save
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .task {
                    appDelegate.pushNotifications = state.pushNotifications
                    if !ProcessInfo.processInfo.isRunningXCTest {
                        await state.bootstrap()
#if DEBUG
                        if let routeURL = ProcessInfo.processInfo.taggrScreenshotRouteURL {
                            // Screenshot captures launch from a deterministic route without changing release behavior.
                            state.open(routeURL)
                        }
#endif
                    }
                }
                .onOpenURL { url in
                    state.open(url)
                }
                .sheet(
                    isPresented: Binding(
                        get: { state.showPushPrePrompt },
                        set: { state.showPushPrePrompt = $0 }
                    )
                ) {
                    PushNotificationPrePromptView()
                        .environment(state)
                }
        }
    }
}

private struct PushNotificationPrePromptView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(TaggrTheme.clickable)
                Text("Keep up with TAGGR")
                    .font(.title.bold())
                Text("Get notified about replies, mentions, reposts, and updates to threads you watch. You can change each type under Account at any time.")
                    .foregroundStyle(TaggrTheme.secondaryText)
                Button("Enable notifications") {
                    Task {
                        await state.pushNotifications.requestAuthorization()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Not now") {
                    state.showPushPrePrompt = false
                    dismiss()
                }
                .foregroundStyle(TaggrTheme.secondaryText)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.background)
        }
        .presentationDetents([.medium])
    }
}

private extension ProcessInfo {
    var isRunningXCTest: Bool {
        // Unit tests inject the test bundle into the app process. Avoid live
        // Keychain/network bootstrap before XCTest enumerates tests.
        environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil
    }

#if DEBUG
    var taggrScreenshotRouteURL: URL? {
        guard let route = environment["TAGGR_SCREENSHOT_ROUTE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !route.isEmpty else {
            return nil
        }
        if let absoluteURL = URL(string: route), absoluteURL.scheme != nil {
            return absoluteURL
        }
        let normalizedRoute = route.hasPrefix("/") ? route : "/\(route)"
        return URL(string: "https://\(TaggrRuntimeConfig.productionDomain)\(normalizedRoute)")
    }
#endif
}
