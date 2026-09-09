import Foundation
import Observation

struct TaggrSafetyPolicy: Codable, Equatable {
    let canisterID: String
    let version: Int
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let postIDs: Set<Int>
    let userIDs: Set<Int>

    func isValid(at now: Date) -> Bool {
        let time = now.timeIntervalSince1970
        return version > 0 && issuedAt <= time + 60 && expiresAt > time
            && expiresAt > issuedAt && expiresAt - issuedAt <= 900
            && postIDs.allSatisfy { $0 >= 0 } && userIDs.allSatisfy { $0 >= 0 }
    }
}

struct TaggrSafetyReport: Codable, Equatable {
    let id: String
    let canisterID: String
    let kind: String
    let postID: Int?
    let userID: Int
    let reason: String
}

enum TaggrSafetyError: LocalizedError {
    case unavailable, consentRequired, suspended, nsfw, rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Safety checks are temporarily unavailable. Please retry."
        case .consentRequired: "Accept the Terms of Use before accessing posts."
        case .suspended: "This account is suspended in the TAGGR iOS app. You can appeal using Terms & safety."
        case .nsfw: "NSFW content cannot be posted from the TAGGR iOS app."
        case .rejected(let message): message
        }
    }
}

@MainActor
@Observable
final class TaggrSafetyStore {
    static let termsVersion = "2026-09-09"
    static let siteURL = URL(string: "https://taggr.kasane.network")!
    private let defaults: UserDefaults
    private let session: URLSession
    private let baseURL: URL
    private var policies: [String: TaggrSafetyPolicy]
    private var agreements: [String: Agreement]
    private var blockOverrides: [String: [String: Bool]]
    private var pendingBlocks: [TaggrSafetyReport]
    private var refreshing: Set<String> = []
    private var sendingBlocks = false
    private(set) var clock = Date()
    private(set) var contentRevision = 0

    private struct Agreement: Codable {
        let version: String
        let date: Date
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, baseURL: URL = TaggrSafetyStore.siteURL) {
        self.defaults = defaults
        self.session = session
        self.baseURL = baseURL
        func stored<T: Decodable>(_ key: String, fallback: T) -> T {
            guard let data = defaults.data(forKey: key) else { return fallback }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }
        policies = stored("taggr.safety.policies", fallback: [:])
        agreements = stored("taggr.safety.agreements", fallback: [:])
        blockOverrides = stored("taggr.safety.blocks", fallback: [:])
        pendingBlocks = stored("taggr.safety.pending-blocks", fallback: [])
    }

    func accepted(scope: String) -> Bool { agreements[scope]?.version == Self.termsVersion }

    func accept(scope: String) {
        agreements[scope] = Agreement(version: Self.termsVersion, date: Date())
        save(agreements, key: "taggr.safety.agreements")
    }

    func policy(canisterID: String) -> TaggrSafetyPolicy? {
        _ = clock
        guard let policy = policies[canisterID], policy.isValid(at: Date()) else { return nil }
        return policy
    }

    func isBlocked(userID: Int, scope: String, remote: [Int]) -> Bool {
        blockOverrides[scope]?[String(userID)] ?? remote.contains(userID)
    }

    func setBlocked(_ blocked: Bool, userID: Int, scope: String, canisterID: String) {
        blockOverrides[scope, default: [:]][String(userID)] = blocked
        if blocked {
            pendingBlocks.append(TaggrSafetyReport(id: UUID().uuidString, canisterID: canisterID, kind: "block", postID: nil, userID: userID, reason: "A user blocked this account in the iOS app. Review is required; this is not proof of a violation."))
        }
        save(blockOverrides, key: "taggr.safety.blocks")
        save(pendingBlocks, key: "taggr.safety.pending-blocks")
        contentRevision += 1
    }

    func refresh(canisterID: String) async {
        clock = Date()
        guard refreshing.insert(canisterID).inserted else { return }
        defer { refreshing.remove(canisterID); clock = Date() }
        do {
            var components = URLComponents(url: baseURL.appendingPathComponent("api/safety/policy"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "canisterID", value: canisterID)]
            let data = try await request(URLRequest(url: components.url!))
            let next = try JSONDecoder().decode(TaggrSafetyPolicy.self, from: data)
            guard !Task.isCancelled, next.canisterID == canisterID, next.isValid(at: Date()), next.version >= (policies[canisterID]?.version ?? 0) else { return }
            let previous = policies[canisterID]
            policies[canisterID] = next
            save(policies, key: "taggr.safety.policies")
            if previous?.postIDs != next.postIDs || previous?.userIDs != next.userIDs { contentRevision += 1 }
        } catch {
            // Only a still-valid saved policy may be used during an outage.
        }
    }

    func send(_ report: TaggrSafetyReport) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/safety/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        let data = try await self.request(request)
        struct Receipt: Decodable { let id: String; let status: String }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.id == report.id, receipt.status == "received" else { throw TaggrSafetyError.unavailable }
    }

    func flushBlockNotifications() async {
        guard !sendingBlocks else { return }
        sendingBlocks = true
        defer { sendingBlocks = false }
        for report in pendingBlocks.prefix(10) {
            do {
                try await send(report)
                pendingBlocks.removeAll { $0.id == report.id }
                save(pendingBlocks, key: "taggr.safety.pending-blocks")
            } catch { break }
        }
    }

    private func request(_ source: URLRequest) async throws -> Data {
        var request = source
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TaggrSafetyError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw TaggrSafetyError.unavailable }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw TaggrSafetyError.rejected((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Safety service unavailable.")
        }
        return data
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

extension TaggrAppCoordinator {
    var safetyScope: String { "\(runtimeConfig.canisterId):\(authSession?.principal ?? "guest")" }
    var acceptedSafetyTerms: Bool { safety.accepted(scope: safetyScope) }
    var safetyPolicy: TaggrSafetyPolicy? { safety.policy(canisterID: runtimeConfig.canisterId) }
    var safetySuspended: Bool { currentUser.map { safetyPolicy?.userIDs.contains($0.id) == true } ?? false }
    var safetyUserUnconfirmed: Bool {
        authSession != nil && currentUser == nil && safetyConfirmedUserScope != safetyScope
    }
    var canAccessUGC: Bool { acceptedSafetyTerms && safetyPolicy != nil && !safetyUserUnconfirmed && !safetySuspended }

    func isUserBlocked(_ id: Int) -> Bool {
        safety.isBlocked(userID: id, scope: safetyScope, remote: currentUser?.blacklist ?? [])
    }

    func isUserRestricted(_ id: Int) -> Bool { isUserBlocked(id) || safetyPolicy?.userIDs.contains(id) == true }

    func canDisplayPost(_ post: TaggrPost) -> Bool {
        guard canAccessUGC, !isUserRestricted(post.user), safetyPolicy?.postIDs.contains(post.id) != true else { return false }
        // Evaluate NSFW independently; another restriction must not make it revealable.
        return !post.isNSFW && post.meta.maxDownvotesReached != true
    }

    func requireSafePublishing(text: String = "", realm: String? = nil, parentID: Int? = nil) async throws {
        let scope = safetyScope
        guard acceptedSafetyTerms else { throw TaggrSafetyError.consentRequired }
        await safety.refresh(canisterID: runtimeConfig.canisterId)
        guard scope == safetyScope, safetyPolicy != nil else { throw TaggrSafetyError.unavailable }
        guard !safetyUserUnconfirmed else { throw TaggrSafetyError.unavailable }
        guard !safetySuspended else { throw TaggrSafetyError.suspended }
        guard !text.localizedCaseInsensitiveContains("#nsfw") else { throw TaggrSafetyError.nsfw }
        var destination = realm
        // Replies inherit the parent's realm even when a different realm was supplied.
        if let parentID {
            guard let parent = try await loadNotificationPost(parentID), canDisplayPost(parent) else { throw TaggrSafetyError.unavailable }
            destination = parent.realm
        }
        if let destination, !destination.isEmpty {
            let values = try await api.query("realms", args: [[destination]], as: [TaggrRealm].self) ?? []
            try Self.validateSafetyRealm(values.first)
        }
        guard scope == safetyScope, canAccessUGC else { throw TaggrSafetyError.unavailable }
    }

    static func validateSafetyRealm(_ realm: TaggrRealm?) throws {
        guard let realm else { throw TaggrSafetyError.unavailable }
        guard !realm.adultContent else { throw TaggrSafetyError.nsfw }
    }
}
