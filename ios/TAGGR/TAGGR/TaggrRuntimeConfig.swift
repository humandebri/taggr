import Foundation
import ICNativeClient

enum TaggrIdentitySignInMethod: CaseIterable, Equatable, Hashable, Sendable {
    case passkey
    case apple
    case google

    var title: String {
        switch self {
        case .passkey: "Continue with passkey"
        case .apple: "Continue with Apple"
        case .google: "Continue with Google"
        }
    }
}

struct TaggrRuntimeConfig: Equatable, Sendable {
    static let productionCanisterId = "6qfxa-ryaaa-aaaai-qbhsq-cai"
    static let productionAPIBaseURL = URL(string: "https://ic0.app")!
    static let productionDomain = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"
    static let productionIdentityURL = URL(string: "https://id.ai/authorize")!
    static let productionDerivationOrigin = "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"

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

    func apiURL(for requestType: String) -> URL {
        do {
            return try icClientConfiguration.apiURL(for: requestType)
        } catch {
            preconditionFailure("Invalid IC API request path: \(error)")
        }
    }

    var icClientConfiguration: ICClientConfiguration {
        icClientConfiguration(trustRoot: .mainnet)
    }

    func icClientConfiguration(trustRoot: ICTrustRoot) -> ICClientConfiguration {
        do {
            return try ICClientConfiguration(
                canisterId: canisterId,
                apiBaseURL: apiBaseURL,
                internetIdentityURL: identityURL,
                derivationOrigin: derivationOrigin,
                trustRoot: trustRoot
            )
        } catch {
            preconditionFailure("Invalid TAGGR runtime configuration: \(error)")
        }
    }

    var shouldLoadBucketImagesThroughAPI: Bool {
        apiBaseURL != Self.productionAPIBaseURL
    }

    var availableIdentitySignInMethods: [TaggrIdentitySignInMethod] {
        isProductionInternetIdentity ? TaggrIdentitySignInMethod.allCases : [.passkey]
    }

    func config(for signInMethod: TaggrIdentitySignInMethod) -> TaggrRuntimeConfig {
        guard isProductionInternetIdentity else { return self }
        var components = URLComponents(url: identityURL, resolvingAgainstBaseURL: false)!
        switch signInMethod {
        case .passkey:
            components.queryItems = nil
        case .apple:
            components.queryItems = [URLQueryItem(name: "openid", value: "https://appleid.apple.com")]
        case .google:
            components.queryItems = [URLQueryItem(name: "openid", value: "https://accounts.google.com")]
        }
        return TaggrRuntimeConfig(
            canisterId: canisterId,
            apiBaseURL: apiBaseURL,
            domain: domain,
            callbackDomain: callbackDomain,
            identityURL: components.url!,
            derivationOrigin: derivationOrigin
        )
    }

    private var isProductionInternetIdentity: Bool {
        guard let components = URLComponents(url: identityURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "id.ai"
            && components.port == nil
            && components.path == "/authorize"
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
