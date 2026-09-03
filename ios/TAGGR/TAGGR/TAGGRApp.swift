import Foundation
import SwiftUI

@main
struct TAGGRApp: App {
    @State private var state: TaggrAppCoordinator

    init() {
        let postDraftStore = PostDraftStore()
        _state = State(
            initialValue: TaggrAppCoordinator(
                postDraftStore: postDraftStore,
                buildConfig: .current
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .task {
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
        }
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
