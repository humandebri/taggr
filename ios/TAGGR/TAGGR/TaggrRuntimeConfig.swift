import Foundation
import ICNativeClient

enum TaggrRuntimeNetwork: String, CaseIterable, Identifiable, Sendable {
    case mainnet
    case staging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainnet:
            return "Mainnet"
        case .staging:
            return "Staging"
        }
    }

    static func from(config: TaggrRuntimeConfig) -> TaggrRuntimeNetwork? {
        if config.canisterId == TaggrRuntimeConfig.productionCanisterId {
            return .mainnet
        }
        if config.canisterId == TaggrRuntimeConfig.stagingCanisterId {
            return .staging
        }
        return nil
    }
}

struct TaggrRuntimeNetworkPreferences {
    static let key = "taggr.runtime.network"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TaggrRuntimeNetwork? {
        defaults.string(forKey: Self.key).flatMap(TaggrRuntimeNetwork.init(rawValue:))
    }

    func save(_ network: TaggrRuntimeNetwork) {
        defaults.set(network.rawValue, forKey: Self.key)
    }
}

struct TaggrRuntimeConfig: Equatable, Sendable {
    static let productionCanisterId = "6qfxa-ryaaa-aaaai-qbhsq-cai"
    static let productionAPIBaseURL = URL(string: "https://ic0.app")!
    static let productionDomain = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"
    static let productionIdentityURL = URL(string: "https://id.ai/authorize")!
    static let productionDerivationOrigin = "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"
    static let stagingCanisterId = "e4i5g-biaaa-aaaao-ai7ja-cai"
    static let stagingDomain = "e4i5g-biaaa-aaaao-ai7ja-cai.icp0.io"
    static let stagingDerivationOrigin = "https://e4i5g-biaaa-aaaao-ai7ja-cai.icp0.io"

    let canisterId: String
    let apiBaseURL: URL
    let domain: String
    let callbackDomain: String
    let identityURL: URL
    let derivationOrigin: String

    static var current: TaggrRuntimeConfig {
        from(info: Bundle.main.infoDictionary ?? [:])
    }

    static func from(info: [String: Any]) -> TaggrRuntimeConfig {
        let canisterId = stringValue("TAGGR_CANISTER_ID", in: info) ?? productionCanisterId
        let apiBaseURL = urlValue("TAGGR_API_BASE_URL", in: info) ?? productionAPIBaseURL
        let domain = stringValue("TAGGR_DOMAIN", in: info) ?? productionDomain
        let callbackDomain = stringValue("TAGGR_CALLBACK_DOMAIN", in: info) ?? domain
        let identityURL = urlValue("TAGGR_II_URL", in: info) ?? productionIdentityURL
        let derivationOrigin = httpsStringValue("TAGGR_DERIVATION_ORIGIN", in: info) ?? productionDerivationOrigin
        return TaggrRuntimeConfig(
            canisterId: canisterId,
            apiBaseURL: apiBaseURL,
            domain: domain,
            callbackDomain: callbackDomain,
            identityURL: identityURL,
            derivationOrigin: derivationOrigin
        )
    }

    static func config(for network: TaggrRuntimeNetwork) -> TaggrRuntimeConfig {
        switch network {
        case .mainnet:
            return TaggrRuntimeConfig(
                canisterId: productionCanisterId,
                apiBaseURL: productionAPIBaseURL,
                domain: productionDomain,
                callbackDomain: productionDomain,
                identityURL: productionIdentityURL,
                derivationOrigin: productionDerivationOrigin
            )
        case .staging:
            return TaggrRuntimeConfig(
                canisterId: stagingCanisterId,
                apiBaseURL: productionAPIBaseURL,
                domain: stagingDomain,
                callbackDomain: stagingDomain,
                identityURL: productionIdentityURL,
                derivationOrigin: stagingDerivationOrigin
            )
        }
    }

    var canonicalNetworkPreset: TaggrRuntimeNetwork? {
        TaggrRuntimeNetwork.allCases.first { self == Self.config(for: $0) }
    }

    func apiURL(for requestType: String) -> URL {
        icClientConfiguration.apiURL(for: requestType)
    }

    var icClientConfiguration: ICClientConfiguration {
        ICClientConfiguration(
            canisterId: canisterId,
            apiBaseURL: apiBaseURL,
            identityProvider: identityURL,
            derivationOrigin: derivationOrigin
        )
    }

    var shouldLoadBucketImagesThroughAPI: Bool {
        apiBaseURL != Self.productionAPIBaseURL
    }

    private static func urlValue(_ key: String, in info: [String: Any]) -> URL? {
        guard let value = stringValue(key, in: info) else {
            return nil
        }
        guard let url = URL(string: value), url.scheme == "https" else {
            return nil
        }
        return url
    }

    private static func httpsStringValue(_ key: String, in info: [String: Any]) -> String? {
        guard let value = stringValue(key, in: info),
              let url = URL(string: value),
              url.scheme == "https" else {
            return nil
        }
        return value
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
