import Foundation

struct TaggrRuntimeConfig: Equatable {
    static let productionCanisterId = "6qfxa-ryaaa-aaaai-qbhsq-cai"
    static let productionAPIBaseURL = URL(string: "https://ic0.app")!
    static let productionDomain = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"
    static let productionIdentityURL = URL(string: "https://id.ai/#authorize")!
    static let productionAuthOrigin = "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"

    let canisterId: String
    let apiBaseURL: URL
    let domain: String
    let identityURL: URL
    let authOrigin: String
    let automateLocalIdentity: Bool

    static var current: TaggrRuntimeConfig {
        from(info: Bundle.main.infoDictionary ?? [:])
    }

    static func from(info: [String: Any]) -> TaggrRuntimeConfig {
        let canisterId = stringValue("TAGGR_CANISTER_ID", in: info) ?? productionCanisterId
        let apiBaseURL = urlValue("TAGGR_API_BASE_URL", in: info) ?? productionAPIBaseURL
        let domain = stringValue("TAGGR_DOMAIN", in: info) ?? productionDomain
        let identityURL = urlValue("TAGGR_II_URL", in: info) ?? productionIdentityURL
        let authOrigin = stringValue("TAGGR_AUTH_ORIGIN", in: info) ?? productionAuthOrigin
        let automateLocalIdentity = boolValue("TAGGR_AUTOMATE_LOCAL_II", in: info)
        return TaggrRuntimeConfig(
            canisterId: canisterId,
            apiBaseURL: apiBaseURL,
            domain: domain,
            identityURL: identityURL,
            authOrigin: authOrigin,
            automateLocalIdentity: automateLocalIdentity
        )
    }

    func apiURL(for requestType: String) -> URL {
        let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/api/v2/canister/\(canisterId)/\(requestType)")!
    }

    private static func urlValue(_ key: String, in info: [String: Any]) -> URL? {
        guard let value = stringValue(key, in: info) else {
            return nil
        }
        return URL(string: value)
    }

    private static func boolValue(_ key: String, in info: [String: Any]) -> Bool {
        guard let value = stringValue(key, in: info)?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    private static func stringValue(_ key: String, in info: [String: Any]) -> String? {
        guard let raw = info[key] as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }
}
