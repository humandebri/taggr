import Foundation
import Observation

enum TaggrSafetyError: LocalizedError {
    case unavailable, consentRequired, nsfw, reportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "This content or account could not be verified. Please retry."
        case .consentRequired: "Accept the Terms of Use before accessing posts."
        case .nsfw: "NSFW content cannot be posted from the TAGGR iOS app."
        case .reportFailed(let message): message
        }
    }
}

struct TaggrModerationList: Codable, Equatable {
    let canisterID: String
    let version: Int
    let postIDs: Set<Int>
    let userIDs: Set<Int>

    var isValid: Bool { version >= 0 && postIDs.allSatisfy { $0 >= 0 } && userIDs.allSatisfy { $0 >= 0 } }
}

struct TaggrContentReport: Codable {
    let id: String
    let canisterID: String
    let userID: Int
    let postID: Int?
    let reason: String
}

@MainActor
@Observable
final class TaggrSafetyStore {
    static let termsVersion = "2026-09-09"
    static let siteURL = URL(string: "https://taggr.kasane.network")!
    static let contactURL = URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF")!
    private let defaults: UserDefaults
    private let session: URLSession
    private let baseURL: URL
    private var moderation: [String: TaggrModerationList]
    private var refreshing: Set<String> = []
    private var agreements: [String: Agreement]
    private var blockOverrides: [String: [String: Bool]]
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
        moderation = stored("taggr.moderation.lists", fallback: [:])
        agreements = stored("taggr.safety.agreements", fallback: [:])
        blockOverrides = stored("taggr.safety.blocks", fallback: [:])
    }

    func isPostHidden(_ id: Int, canisterID: String) -> Bool { list(canisterID)?.postIDs.contains(id) == true }
    func isUserHidden(_ id: Int, canisterID: String) -> Bool { list(canisterID)?.userIDs.contains(id) == true }

    private func list(_ canisterID: String) -> TaggrModerationList? {
        guard let value = moderation[canisterID], value.canisterID == canisterID, value.isValid else { return nil }
        return value
    }

    func refresh(canisterID: String) async {
        guard refreshing.insert(canisterID).inserted else { return }
        defer { refreshing.remove(canisterID) }
        do {
            var url = URLComponents(url: baseURL.appendingPathComponent("api/moderation"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "canisterID", value: canisterID)]
            let data = try await request(URLRequest(url: url.url!))
            let next = try JSONDecoder().decode(TaggrModerationList.self, from: data)
            try Task.checkCancellation()
            guard next.canisterID == canisterID, next.isValid, next.version >= (list(canisterID)?.version ?? 0) else { return }
            guard moderation[canisterID] != next else { return }
            moderation[canisterID] = next
            save(moderation, key: "taggr.moderation.lists")
            contentRevision += 1
        } catch {
            // An unavailable list never blocks the app or clears previously known restrictions.
        }
    }

    func sendReport(_ report: TaggrContentReport) async throws {
        var source = URLRequest(url: baseURL.appendingPathComponent("api/reports"))
        source.httpMethod = "POST"
        source.setValue("application/json", forHTTPHeaderField: "Content-Type")
        source.httpBody = try JSONEncoder().encode(report)
        struct Receipt: Decodable { let id: String; let status: String }
        let data = try await request(source)
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.id.lowercased() == report.id.lowercased(), receipt.status == "received" else {
            throw TaggrSafetyError.reportFailed("The report could not be confirmed. Please retry.")
        }
    }

    private func request(_ source: URLRequest) async throws -> Data {
        var source = source
        source.timeoutInterval = 10
        source.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: source)
        guard let http = response as? HTTPURLResponse else { throw TaggrSafetyError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw TaggrSafetyError.unavailable }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw TaggrSafetyError.reportFailed((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Service unavailable (HTTP \(http.statusCode)). Please retry.")
        }
        return data
    }

    func accepted(scope: String) -> Bool { agreements[scope]?.version == Self.termsVersion }

    func accept(scope: String) {
        agreements[scope] = Agreement(version: Self.termsVersion, date: Date())
        save(agreements, key: "taggr.safety.agreements")
    }

    func isBlocked(userID: Int, scope: String, remote: [Int]) -> Bool {
        blockOverrides[scope]?[String(userID)] ?? remote.contains(userID)
    }

    func setBlocked(_ blocked: Bool, userID: Int, scope: String) {
        blockOverrides[scope, default: [:]][String(userID)] = blocked
        save(blockOverrides, key: "taggr.safety.blocks")
        contentRevision += 1
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

extension TaggrAppCoordinator {
    var safetyScope: String { "\(runtimeConfig.canisterId):\(authSession?.principal ?? "guest")" }
    var acceptedSafetyTerms: Bool { safety.accepted(scope: safetyScope) }
    var canAccessUGC: Bool { acceptedSafetyTerms }

    func isUserBlocked(_ id: Int) -> Bool {
        safety.isBlocked(userID: id, scope: safetyScope, remote: currentUser?.blacklist ?? [])
    }

    func isUserRestricted(_ id: Int) -> Bool { isUserBlocked(id) || safety.isUserHidden(id, canisterID: runtimeConfig.canisterId) }

    func canDisplayPost(_ post: TaggrPost) -> Bool {
        guard canAccessUGC, !isUserRestricted(post.user), !safety.isPostHidden(post.id, canisterID: runtimeConfig.canisterId) else { return false }
        // Evaluate NSFW independently; another restriction must not make it revealable.
        return !post.isNSFW && post.meta.maxDownvotesReached != true
    }

    func requireSafePublishing(text: String = "", realm: String? = nil, parentID: Int? = nil) async throws {
        let scope = safetyScope
        guard acceptedSafetyTerms else { throw TaggrSafetyError.consentRequired }
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
