import CryptoKit
import Foundation
import ICNativeClient
import Security
import UIKit
import UserNotifications

struct TaggrPushPreferences: Codable, Equatable, Sendable {
    var masterEnabled = false
    var replies = true
    var mentions = true
    var reposts = true
    var watchedThreads = true

    var enabledKinds: UInt8 {
        guard masterEnabled else { return 0 }
        return (replies ? UInt8(1) : 0)
            | (mentions ? UInt8(2) : 0)
            | (reposts ? UInt8(4) : 0)
            | (watchedThreads ? UInt8(8) : 0)
    }
}

enum TaggrPushAuthorizationStatus: Equatable, Sendable {
    case unknown
    case denied
    case authorized
}

private struct TaggrPushCredentials: Codable {
    let installationId: String
    let bindingSecret: String
}

private struct TaggrPendingPushCleanup: Codable, Equatable {
    let canisterId: String
    let relayURL: URL
}

@MainActor
final class TaggrPushOperationBarrier {
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = next
        return next
    }
}

@MainActor
final class TaggrPushNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static let keychainService = "network.taggr.ios.push"
    private static let keychainAccount = "installation"
    private weak var state: TaggrAppCoordinator?
    private var deviceToken: Data?
    private let operations = TaggrPushOperationBarrier()

    func attach(to state: TaggrAppCoordinator) {
        self.state = state
        UNUserNotificationCenter.current().delegate = self
        state.pushPreferences = loadPreferences(canisterId: state.runtimeConfig.canisterId)
        operations.enqueue { [weak self] in
            await self?.retryPendingRelayCleanups()
        }
    }

    func prepareAfterAccountLoad() async {
        guard let state, let user = state.currentUser, state.authSession != nil else { return }
        await refreshAuthorizationStatus()
        if state.pushPreferences.masterEnabled {
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        let promptKey = "taggr.push.prompted.\(state.runtimeConfig.canisterId).\(user.id)"
        if !UserDefaults.standard.bool(forKey: promptKey) {
            UserDefaults.standard.set(true, forKey: promptKey)
            state.showPushPrePrompt = true
        }
    }

    func requestAuthorization() async {
        guard let state else { return }
        state.showPushPrePrompt = false
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            state.pushAuthorizationStatus = granted ? .authorized : .denied
            if granted {
                state.pushPreferences.masterEnabled = true
                savePreferences(state.pushPreferences, canisterId: state.runtimeConfig.canisterId)
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                state.pushPreferences.masterEnabled = false
                savePreferences(state.pushPreferences, canisterId: state.runtimeConfig.canisterId)
            }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func refreshAuthorizationStatus() async {
        guard let state else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            state.pushAuthorizationStatus = .authorized
        case .denied:
            state.pushAuthorizationStatus = .denied
        default:
            state.pushAuthorizationStatus = .unknown
        }
    }

    func setMasterEnabled(_ enabled: Bool) async {
        guard let state else { return }
        if enabled {
            await requestAuthorization()
            return
        }
        state.pushPreferences.masterEnabled = false
        savePreferences(state.pushPreferences, canisterId: state.runtimeConfig.canisterId)
        await removeCurrentRegistration()
    }

    func preferencesChanged() async {
        guard let state else { return }
        if state.pushPreferences.enabledKinds == 0 {
            state.pushPreferences.masterEnabled = false
            savePreferences(state.pushPreferences, canisterId: state.runtimeConfig.canisterId)
            await removeCurrentRegistration()
            return
        }
        savePreferences(state.pushPreferences, canisterId: state.runtimeConfig.canisterId)
        if let deviceToken {
            await synchronize(deviceToken: deviceToken)
        } else {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken
        Task { await synchronize(deviceToken: deviceToken) }
    }

    func didFailToRegister(_ error: Error) {
        state?.errorMessage = "Push registration failed: \(error.localizedDescription)"
    }

    func signOut() {
        guard let state else { return }
        UIApplication.shared.unregisterForRemoteNotifications()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        deviceToken = nil
        let api = state.api
        let config = state.runtimeConfig
        let identity = state.authSession
        enqueueCleanup(for: config)
        operations.enqueue {
            await self.removeRegistration(api: api, config: config, identity: identity)
        }
    }

    func runtimeDidChange() {
        guard let state else { return }
        state.pushPreferences = loadPreferences(canisterId: state.runtimeConfig.canisterId)
        Task { await refreshAuthorizationStatus() }
    }

    private func synchronize(deviceToken: Data) async {
        let task = operations.enqueue { [weak self] in
            await self?.performSynchronization(deviceToken: deviceToken)
        }
        await task.value
    }

    private func performSynchronization(deviceToken: Data) async {
        guard let state,
              state.pushPreferences.enabledKinds != 0,
              let identity = state.authSession,
              state.currentUser != nil else { return }
        guard let relayURL = state.runtimeConfig.pushRelayURL else {
            state.errorMessage = "TAGGR_PUSH_RELAY_URL is not configured."
            return
        }
        do {
            let credentials = try credentials()
            let token = deviceToken.map { String(format: "%02x", $0) }.joined()
            let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            try await state.api.registerPushInstallation(
                installationId: credentials.installationId,
                bindingSecret: credentials.bindingSecret,
                tokenHash: tokenHash,
                enabledKinds: state.pushPreferences.enabledKinds,
                identity: identity
            )
            try await relayRequest(
                url: relayURL,
                method: "POST",
                body: [
                    "canisterId": state.runtimeConfig.canisterId,
                    "installationId": credentials.installationId,
                    "bindingSecret": credentials.bindingSecret,
                    "deviceToken": token,
                    "apnsEnvironment": apnsEnvironment,
                ]
            )
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func removeCurrentRegistration() async {
        guard let state else { return }
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        let api = state.api
        let config = state.runtimeConfig
        let identity = state.authSession
        enqueueCleanup(for: config)
        let task = operations.enqueue {
            await self.removeRegistration(api: api, config: config, identity: identity)
        }
        await task.value
    }

    private func removeRegistration(api: TaggrAPI, config: TaggrRuntimeConfig, identity: ICAuthSession?) async {
        guard let credentials = try? credentials() else { return }
        if let relayURL = config.pushRelayURL {
            do {
                try await relayRequest(
                    url: relayURL,
                    method: "DELETE",
                    body: [
                        "canisterId": config.canisterId,
                        "installationId": credentials.installationId,
                        "bindingSecret": credentials.bindingSecret,
                    ]
                )
                removePendingCleanup(canisterId: config.canisterId)
            } catch {
                NSLog("TAGGR push relay cleanup deferred: %@", error.localizedDescription)
            }
        }
        guard let identity else { return }
        do {
            try await api.removePushInstallation(
                installationId: credentials.installationId,
                bindingSecret: credentials.bindingSecret,
                identity: identity
            )
        } catch {
            NSLog("TAGGR push cleanup failed: %@", error.localizedDescription)
        }
    }

    private func retryPendingRelayCleanups() async {
        guard let credentials = try? credentials() else { return }
        for cleanup in pendingCleanups() {
            do {
                try await relayRequest(
                    url: cleanup.relayURL,
                    method: "DELETE",
                    body: [
                        "canisterId": cleanup.canisterId,
                        "installationId": credentials.installationId,
                        "bindingSecret": credentials.bindingSecret,
                    ]
                )
                removePendingCleanup(canisterId: cleanup.canisterId)
            } catch {
                NSLog("TAGGR push relay cleanup still pending: %@", error.localizedDescription)
            }
        }
    }

    private func enqueueCleanup(for config: TaggrRuntimeConfig) {
        guard let relayURL = config.pushRelayURL else { return }
        var cleanups = pendingCleanups().filter { $0.canisterId != config.canisterId }
        cleanups.append(TaggrPendingPushCleanup(canisterId: config.canisterId, relayURL: relayURL))
        savePendingCleanups(cleanups)
    }

    private func removePendingCleanup(canisterId: String) {
        savePendingCleanups(pendingCleanups().filter { $0.canisterId != canisterId })
    }

    private func pendingCleanups() -> [TaggrPendingPushCleanup] {
        guard let data = UserDefaults.standard.data(forKey: "taggr.push.pending-cleanups") else {
            return []
        }
        return (try? JSONDecoder().decode([TaggrPendingPushCleanup].self, from: data)) ?? []
    }

    private func savePendingCleanups(_ cleanups: [TaggrPendingPushCleanup]) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(cleanups),
            forKey: "taggr.push.pending-cleanups"
        )
    }

    private func relayRequest(url: URL, method: String, body: [String: String]) async throws {
        var request = URLRequest(url: url.appendingPathComponent("v1/subscriptions"))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TaggrAPIError.backendUnavailable("Push relay rejected the device registration.")
        }
    }

    private var apnsEnvironment: String {
#if DEBUG
        "sandbox"
#else
        "production"
#endif
    }

    private func credentials() throws -> TaggrPushCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let stored = try? JSONDecoder().decode(TaggrPushCredentials.self, from: data) {
            return stored
        }
        guard status == errSecItemNotFound else {
            throw TaggrAPIError.backendUnavailable("Push credential access failed (\(status)).")
        }
        var random = Data(count: 32)
        let randomStatus = random.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw TaggrAPIError.backendUnavailable("Push credential generation failed.")
        }
        let created = TaggrPushCredentials(
            installationId: UUID().uuidString.lowercased(),
            bindingSecret: random.map { String(format: "%02x", $0) }.joined()
        )
        let data = try JSONEncoder().encode(created)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw TaggrAPIError.backendUnavailable("Push credential storage failed.")
        }
        return created
    }

    private func loadPreferences(canisterId: String) -> TaggrPushPreferences {
        guard let data = UserDefaults.standard.data(forKey: "taggr.push.preferences.\(canisterId)"),
              let preferences = try? JSONDecoder().decode(TaggrPushPreferences.self, from: data) else {
            return TaggrPushPreferences()
        }
        return preferences
    }

    private func savePreferences(_ preferences: TaggrPushPreferences, canisterId: String) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(preferences),
            forKey: "taggr.push.preferences.\(canisterId)"
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
        Task { @MainActor [weak self] in
            await self?.state?.handleForegroundPush()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let postId = Self.intValue(info["postId"])
        let notificationId = Self.intValue(info["notificationId"])
        completionHandler()
        Task { @MainActor [weak self] in
            await self?.state?.handlePushTap(postId: postId, notificationId: notificationId)
        }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

@MainActor
final class TaggrApplicationDelegate: NSObject, UIApplicationDelegate {
    weak var pushNotifications: TaggrPushNotificationManager?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushNotifications?.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushNotifications?.didFailToRegister(error)
    }
}
