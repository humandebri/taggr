// TAGGR iOS / IC certificate verification.
// Verifies read_state certificates before trusting update status or reply data.

import CryptoKit
import Foundation

struct TaggrVerifiedCertificate {
    let tree: TaggrCBOR.Value
}

enum TaggrCertificateError: Error, LocalizedError {
    case missingCertificate
    case invalidCertificate
    case invalidRootKey
    case invalidTree
    case invalidTime
    case invalidSignature
    case canisterOutOfRange

    var errorDescription: String? {
        switch self {
        case .missingCertificate:
            return "The IC read_state response did not include a certificate."
        case .invalidCertificate:
            return "The IC certificate is malformed."
        case .invalidRootKey:
            return "The IC root key is malformed."
        case .invalidTree:
            return "The IC certificate tree is malformed."
        case .invalidTime:
            return "The IC certificate time is outside the accepted window."
        case .invalidSignature:
            return "The IC certificate signature is invalid."
        case .canisterOutOfRange:
            return "The IC certificate delegation does not cover the TAGGR canister."
        }
    }
}

struct TaggrCertificateVerifier {
    typealias BLSVerify = (_ publicKey: Data, _ signature: Data, _ message: Data) -> Bool

    static let icRootKey = Data(hex:
        "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100814" +
        "c0e6ec71fab583b08bd81373c255c3c371b2e84863c98a4f1e08b74235d14fb5d9c0cd546d968" +
        "5f913a0c0b2cc5341583bf4b4392e467db96d65b9bb4cb717112f8472e0d5a4d14505ffd7484" +
        "b01291091c5f87b98883463f98091a0baaae"
    )!

    private static let derPrefix = Data(hex: "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100")!
    private let rootKey: Data
    private let maxAge: TimeInterval
    private let blsVerify: BLSVerify

    init(rootKey: Data = Self.icRootKey, maxAge: TimeInterval = 300, blsVerify: @escaping BLSVerify = Self.defaultBLSVerify) {
        self.rootKey = rootKey
        self.maxAge = maxAge
        self.blsVerify = blsVerify
    }

    func verifiedCertificate(from readStateData: Data, canister: Data) throws -> TaggrVerifiedCertificate {
        guard case .bytes(let certificateData)? = TaggrCBOR.mapValue(readStateData, key: "certificate") else {
            throw TaggrCertificateError.missingCertificate
        }
        return try verifyCertificate(certificateData, rootKey: rootKey, canister: canister, checkPastTime: true)
    }

    private func verifyCertificate(_ data: Data, rootKey: Data, canister: Data, checkPastTime: Bool) throws -> TaggrVerifiedCertificate {
        guard case .map(let certificate)? = TaggrCBOR.decode(data),
              let tree = certificate.value(for: "tree"),
              case .bytes(let signature)? = certificate.value(for: "signature") else {
            throw TaggrCertificateError.invalidCertificate
        }

        let signingKey = try signingKey(for: certificate, rootKey: rootKey, canister: canister)
        let rootHash = try reconstruct(tree)
        try validateTime(in: tree, checkPastTime: checkPastTime)
        let message = domainSeparator("ic-state-root") + rootHash
        guard blsVerify(try extractDER(signingKey), signature, message) else {
            throw TaggrCertificateError.invalidSignature
        }
        return TaggrVerifiedCertificate(tree: tree)
    }

    private func signingKey(for certificate: [(TaggrCBOR.Value, TaggrCBOR.Value)], rootKey: Data, canister: Data) throws -> Data {
        guard let delegation = certificate.value(for: "delegation") else {
            return rootKey
        }
        guard case .map(let values) = delegation,
              case .bytes(let subnetId)? = values.value(for: "subnet_id"),
              case .bytes(let certificateData)? = values.value(for: "certificate") else {
            throw TaggrCertificateError.invalidCertificate
        }
        let subnetCertificate = try verifyCertificate(certificateData, rootKey: rootKey, canister: canister, checkPastTime: false)
        try validateCanister(canister, in: subnetCertificate.tree, subnetId: subnetId)
        guard let publicKey = TaggrCBOR.lookup([Data("subnet".utf8), subnetId, Data("public_key".utf8)], in: subnetCertificate.tree) else {
            throw TaggrCertificateError.invalidCertificate
        }
        return publicKey
    }

    private func validateCanister(_ canister: Data, in tree: TaggrCBOR.Value, subnetId: Data) throws {
        guard let encodedRanges = TaggrCBOR.lookup([Data("subnet".utf8), subnetId, Data("canister_ranges".utf8)], in: tree),
              case .array(let ranges)? = TaggrCBOR.decode(encodedRanges) else {
            throw TaggrCertificateError.invalidCertificate
        }
        for range in ranges {
            guard case .array(let pair) = range, pair.count == 2,
                  case .bytes(let start) = pair[0],
                  case .bytes(let end) = pair[1] else {
                throw TaggrCertificateError.invalidCertificate
            }
            if start.lexicographicallyPrecedesOrEquals(canister) && canister.lexicographicallyPrecedesOrEquals(end) {
                return
            }
        }
        throw TaggrCertificateError.canisterOutOfRange
    }

    private func validateTime(in tree: TaggrCBOR.Value, checkPastTime: Bool) throws {
        guard let encodedTime = TaggrCBOR.lookup([Data("time".utf8)], in: tree),
              let nanos = Self.decodeLEB128(encodedTime) else {
            throw TaggrCertificateError.invalidTime
        }
        let certificateTime = Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
        let now = Date()
        if checkPastTime && certificateTime < now.addingTimeInterval(-maxAge) {
            throw TaggrCertificateError.invalidTime
        }
        if certificateTime > now.addingTimeInterval(300) {
            throw TaggrCertificateError.invalidTime
        }
    }

    private func reconstruct(_ tree: TaggrCBOR.Value) throws -> Data {
        switch tree {
        case .array(let values):
            guard let type = values.first else { throw TaggrCertificateError.invalidTree }
            switch type {
            case .unsigned(0):
                return sha256(domainSeparator("ic-hashtree-empty"))
            case .unsigned(1):
                guard values.count == 3 else { throw TaggrCertificateError.invalidTree }
                return sha256(domainSeparator("ic-hashtree-fork") + (try reconstruct(values[1])) + (try reconstruct(values[2])))
            case .unsigned(2):
                guard values.count == 3, case .bytes(let label) = values[1] else { throw TaggrCertificateError.invalidTree }
                return sha256(domainSeparator("ic-hashtree-labeled") + label + (try reconstruct(values[2])))
            case .unsigned(3):
                guard values.count == 2, case .bytes(let data) = values[1] else { throw TaggrCertificateError.invalidTree }
                return sha256(domainSeparator("ic-hashtree-leaf") + data)
            case .unsigned(4):
                guard values.count == 2, case .bytes(let hash) = values[1], hash.count == 32 else { throw TaggrCertificateError.invalidTree }
                return hash
            default:
                throw TaggrCertificateError.invalidTree
            }
        default:
            throw TaggrCertificateError.invalidTree
        }
    }

    private static func decodeLEB128(_ data: Data) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            guard shift < 64 else { return nil }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func defaultBLSVerify(_ publicKey: Data, _ signature: Data, _ message: Data) -> Bool {
        publicKey.withUnsafeBytes { publicKeyBytes in
            signature.withUnsafeBytes { signatureBytes in
                message.withUnsafeBytes { messageBytes in
                    guard let publicKeyBase = publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                          let signatureBase = signatureBytes.bindMemory(to: UInt8.self).baseAddress,
                          let messageBase = messageBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return false
                    }
                    return taggr_bls_verify_short_signature(
                        publicKeyBase,
                        publicKey.count,
                        signatureBase,
                        signature.count,
                        messageBase,
                        message.count
                    )
                }
            }
        }
    }

    private func extractDER(_ data: Data) throws -> Data {
        guard data.count == Self.derPrefix.count + 96,
              data.prefix(Self.derPrefix.count) == Self.derPrefix else {
            throw TaggrCertificateError.invalidRootKey
        }
        return Data(data.dropFirst(Self.derPrefix.count))
    }

    private func domainSeparator(_ value: String) -> Data {
        Data([UInt8(value.utf8.count)]) + Data(value.utf8)
    }

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

private extension Array where Element == (TaggrCBOR.Value, TaggrCBOR.Value) {
    func value(for key: String) -> TaggrCBOR.Value? {
        first { $0.0 == .text(key) }?.1
    }
}

private extension Data {
    func lexicographicallyPrecedesOrEquals(_ other: Data) -> Bool {
        self == other || lexicographicallyPrecedes(other)
    }
}
