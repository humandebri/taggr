import SwiftUI

@main
struct TAGGRApp: App {
    @StateObject private var state = TaggrAppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .task {
                    if !ProcessInfo.processInfo.isRunningXCTest {
                        await state.bootstrap()
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
}
