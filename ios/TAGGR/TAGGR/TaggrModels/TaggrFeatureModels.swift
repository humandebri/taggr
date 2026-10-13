import Foundation
import ICNativeClient

enum TaggrRealmCreationProgress: Equatable {
    case editing, uncertain, created(String)
    var canCreate: Bool { self == .editing }
    var createdName: String? { if case .created(let name) = self { name } else { nil } }
}

struct TaggrSearchResult: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let userId: Int
    let genericId: String
    let result: String
    let relevant: String
    var key: String { "\(result):\(id):\(genericId):\(relevant)" }
}

struct TaggrProfileDraft: Equatable, Sendable {
    var name: String
    var about: String
    var links: String
    var mode: String
    var governance: Bool
    var controllers: String
    init(_ user: TaggrUser) {
        name = user.name; about = user.about; links = user.settings["links"] ?? ""
        mode = user.mode ?? "Mining"; governance = user.governance
        controllers = user.controllers.joined(separator: "\n")
    }
    var controllerIDs: [String] {
        controllers.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func profileChanged(from user: TaggrUser) -> Bool {
        name != user.name || about != user.about || mode != user.mode ||
            governance != user.governance || controllerIDs != user.controllers
    }
    func unsavedFields(comparedTo user: TaggrUser) -> [String] {
        var fields: [String] = []
        if name != user.name { fields.append("Name") }
        if about != user.about { fields.append("About") }
        if links != (user.settings["links"] ?? "") { fields.append("Links") }
        if mode != user.mode { fields.append("Usage mode") }
        if governance != user.governance { fields.append("Governance") }
        if controllerIDs != user.controllers { fields.append("Controllers") }
        return fields
    }
    func validate() throws {
        guard !name.isEmpty else { throw TaggrAPIError.rejected("Name is required.") }
        for id in controllerIDs { _ = try CandidPrincipal(id) }
        guard Set(controllerIDs).count == controllerIDs.count else { throw TaggrAPIError.rejected("Duplicate Controller Principal.") }
        for line in links.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let separator = line.range(of: ": ") else { throw TaggrAPIError.rejected("Use Label: https://example.com for each link.") }
            let label = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let url = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count <= 50, url.hasPrefix("https://") else {
                throw TaggrAPIError.rejected("Links need a label of 1–50 characters and an https:// URL.")
            }
        }
    }
}

struct TaggrInvite: Decodable, Equatable, Sendable {
    let credits: Int
    let creditsPerUser: Int
    let joinedUserIds: [Int]
    let realmId: String?
    let inviterUserId: Int
    var canStop: Bool { credits > 0 && !joinedUserIds.isEmpty }
    func validateCredits(_ amount: Int) throws {
        guard amount >= 0, creditsPerUser > 0, amount % creditsPerUser == 0 else {
            throw TaggrAPIError.rejected("Credits must be a nonnegative multiple of credits per user.")
        }
        if amount == 0 && joinedUserIds.isEmpty {
            throw TaggrAPIError.rejected("An unused invite cannot be stopped.")
        }
    }
}

struct TaggrInviteEntry: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let invite: TaggrInvite
    init(from decoder: Decoder) throws {
        var row = try decoder.unkeyedContainer()
        id = try row.decode(String.self)
        invite = try row.decode(TaggrInvite.self)
    }
}

struct TaggrTransaction: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let owner: String
        let subaccount: [UInt8]?
        var address: String {
            TaggrFeatureAccount.address(owner: owner, subaccount: subaccount)
        }
    }
    let timestamp: UInt64
    let from: Account
    let to: Account
    let amount: UInt64
    let fee: UInt64
    let memo: [UInt8]?
}

struct TaggrFeatureAccount: Equatable, Sendable {
    let owner: String
    let subaccount: String

    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let principalPart = parts.first, !principalPart.isEmpty else { throw TaggrAPIError.rejected("Invalid account.") }
        if parts.count == 1 {
            owner = try CandidPrincipal(text).text
            subaccount = String(repeating: "0", count: 64)
            return
        }
        guard let separator = principalPart.lastIndex(of: "-") else { throw TaggrAPIError.rejected("Missing account checksum.") }
        owner = try CandidPrincipal(String(principalPart[..<separator])).text
        let hex = String(parts[1])
        guard !hex.isEmpty, hex.count <= 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw TaggrAPIError.rejected("Invalid subaccount.") }
        subaccount = String(repeating: "0", count: 64 - hex.count) + hex.lowercased()
        let bytes = stride(from: 0, to: 64, by: 2).map { offset in
            let start = subaccount.index(subaccount.startIndex, offsetBy: offset)
            return UInt8(subaccount[start..<subaccount.index(start, offsetBy: 2)], radix: 16)!
        }
        guard Self.checksum(owner: owner, bytes: bytes) == principalPart[principalPart.index(after: separator)...] else {
            throw TaggrAPIError.rejected("Invalid account checksum.")
        }
    }

    static func address(owner: String, subaccount: [UInt8]?) -> String {
        guard let subaccount, subaccount.contains(where: { $0 != 0 }) else { return owner }
        let hex = Data(subaccount).icHexString.drop(while: { $0 == "0" })
        return owner + "-" + checksum(owner: owner, bytes: subaccount) + "." + hex
    }

    // ICRC-1 textual accounts checksum the owner bytes followed by the subaccount.
    private static func checksum(owner: String, bytes: [UInt8]) -> String {
        var crc: UInt32 = 0xffffffff
        for byte in Array(ICPrincipal.parse(owner) ?? Data()) + bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        crc ^= 0xffffffff
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        let padded = UInt64(crc) << 3
        return stride(from: 30, through: 0, by: -5).map { String(alphabet[Int((padded >> $0) & 31)]) }.joined()
    }
}

struct TaggrTransactionEntry: Decodable, Identifiable, Sendable {
    let id: Int
    let transaction: TaggrTransaction
    init(from decoder: Decoder) throws {
        var row = try decoder.unkeyedContainer()
        id = try row.decode(Int.self)
        transaction = try row.decode(TaggrTransaction.self)
    }
}

enum FeatureAmount {
    static func format(_ amount: UInt64, decimals: Int) -> String {
        let decimals = min(max(decimals, 0), 19)
        guard decimals > 0 else { return String(amount) }
        let digits = String(amount)
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[split...])
        while fraction.last == "0" { fraction.removeLast() }
        return String(padded[..<split]) + (fraction.isEmpty ? "" : "." + fraction)
    }

    static func parse(_ text: String, decimals: Int) -> UInt64? {
        guard (0...19).contains(decimals) else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals else { return nil }
        return UInt64(String(whole) + fraction + String(repeating: "0", count: decimals - fraction.count))
    }
}
