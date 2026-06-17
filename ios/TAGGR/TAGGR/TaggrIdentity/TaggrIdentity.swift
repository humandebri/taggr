import CryptoKit
import Foundation
import Security

struct TaggrAuthSession: Codable, Equatable {
    let principal: String
    let sessionPublicKey: Data
    let sessionPrivateKey: Data
    let delegation: TaggrDelegationChain
    let createdAt: Date
}

struct TaggrDelegationChain: Codable, Equatable {
    struct SignedDelegation: Codable, Equatable {
        struct Delegation: Codable, Equatable {
            let publicKey: Data
            let expiration: UInt64
            let targets: [Data]?
        }

        let delegation: Delegation
        let signature: Data
    }

    let publicKey: Data
    let delegations: [SignedDelegation]
}

enum TaggrIdentityError: Error, LocalizedError {
    case invalidPayload
    case authorizationFailed(String)
    case expiredDelegation
    case encodingFailure
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Internet Identity returned an invalid payload."
        case .authorizationFailed(let message):
            return message
        case .expiredDelegation:
            return "Internet Identity delegation expired."
        case .encodingFailure:
            return "Internet Identity session could not be encoded."
        case .keychainFailure(let status):
            return "Keychain operation failed: \(status)."
        }
    }
}

final class TaggrIdentityStore {
    private let service = "network.taggr.ios.identity"
    private let account = "internet-identity-session"

    func load() -> TaggrAuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(TaggrAuthSession.self, from: data)
    }

    func save(_ session: TaggrAuthSession) throws {
        guard let data = try? JSONEncoder().encode(session) else {
            throw TaggrIdentityError.encodingFailure
        }
        clear()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw TaggrIdentityError.keychainFailure(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum TaggrIdentityBridge {
    static var authorizeURL: URL { TaggrRuntimeConfig.current.identityURL }
    static let ed25519DERPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])

    static func makeSession(from payload: String, privateKey: Curve25519.Signing.PrivateKey) throws -> TaggrAuthSession {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else {
            throw TaggrIdentityError.invalidPayload
        }

        if kind == "authorize-client-failure" {
            let message = object["text"] as? String ?? object["message"] as? String ?? "Internet Identity authorization failed."
            throw TaggrIdentityError.authorizationFailed(message)
        }
        guard kind == "authorize-client-success" else {
            throw TaggrIdentityError.invalidPayload
        }

        let chain = try parseDelegationChain(from: object)
        try validate(chain)
        let sessionPublicKey = derPublicKey(from: privateKey.publicKey.rawRepresentation)
        guard chain.delegations.last?.delegation.publicKey == sessionPublicKey else {
            throw TaggrIdentityError.invalidPayload
        }
        let principal = PrincipalBlob.text(from: PrincipalBlob.selfAuthenticatingPublicKey(chain.publicKey))
        return TaggrAuthSession(
            principal: principal,
            sessionPublicKey: sessionPublicKey,
            sessionPrivateKey: privateKey.rawRepresentation,
            delegation: chain,
            createdAt: Date()
        )
    }

    static func authorizeClientRequest(publicKey: Data) -> String {
        let request: [String: Any] = [
            "kind": "authorize-client",
            "sessionPublicKey": Array(publicKey),
            "maxTimeToLive": "2592000000000000",
        ]
        let data = try? JSONSerialization.data(withJSONObject: request)
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    static func derPublicKey(from rawPublicKey: Data) -> Data {
        ed25519DERPrefix + rawPublicKey
    }

    private static func parseDelegationChain(from object: [String: Any]) throws -> TaggrDelegationChain {
        let chainObject = object["delegation"] as? [String: Any] ?? object
        guard let publicKey = parseBytes(chainObject["userPublicKey"] ?? chainObject["publicKey"]),
              let rawDelegations = chainObject["delegations"] as? [[String: Any]] else {
            throw TaggrIdentityError.invalidPayload
        }

        let delegations = try rawDelegations.map { raw in
            guard let signature = parseBytes(raw["signature"]),
                  let delegation = raw["delegation"] as? [String: Any],
                  let delegatedPublicKey = parseBytes(delegation["pubkey"]),
                  let expirationValue = delegation["expiration"],
                  let expiration = parseExpiration(expirationValue) else {
                throw TaggrIdentityError.invalidPayload
            }
            let targets = try parseTargets(delegation["targets"])
            return TaggrDelegationChain.SignedDelegation(
                delegation: .init(publicKey: delegatedPublicKey, expiration: expiration, targets: targets),
                signature: signature
            )
        }

        guard !delegations.isEmpty else {
            throw TaggrIdentityError.invalidPayload
        }
        return TaggrDelegationChain(publicKey: publicKey, delegations: delegations)
    }

    private static func parseBytes(_ value: Any?) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let hex = value as? String {
            return Data(hex: hex)
        }
        if let values = value as? [NSNumber] {
            var data = Data()
            for value in values {
                let integer = value.intValue
                guard integer >= 0 && integer <= Int(UInt8.max) else { return nil }
                data.append(UInt8(integer))
            }
            return data
        }
        if let values = value as? [Any] {
            var data = Data()
            for value in values {
                guard let number = value as? NSNumber else { return nil }
                let integer = number.intValue
                guard integer >= 0 && integer <= Int(UInt8.max) else { return nil }
                data.append(UInt8(integer))
            }
            return data
        }
        return nil
    }

    private static func parseTargets(_ value: Any?) throws -> [Data]? {
        guard let value else {
            return nil
        }
        guard let targets = value as? [Any] else {
            throw TaggrIdentityError.invalidPayload
        }
        return try targets.map { target in
            guard let data = parseBytes(target) else {
                throw TaggrIdentityError.invalidPayload
            }
            return data
        }
    }

    private static func parseExpiration(_ value: Any) -> UInt64? {
        if let string = value as? String {
            if string.hasPrefix("0x") {
                return UInt64(string.dropFirst(2), radix: 16)
            }
            return UInt64(string, radix: 10)
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private static func validate(_ chain: TaggrDelegationChain) throws {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        guard let canister = PrincipalBlob.parse(TaggrRuntimeConfig.current.canisterId) else {
            throw TaggrIdentityError.invalidPayload
        }
        for signed in chain.delegations {
            guard signed.delegation.expiration > now else {
                throw TaggrIdentityError.expiredDelegation
            }
            if let targets = signed.delegation.targets, !targets.contains(canister) {
                throw TaggrIdentityError.invalidPayload
            }
        }
    }
}

extension Data {
    init?(hex: String) {
        let text = hex.lowercased().filter { !$0.isWhitespace }
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
