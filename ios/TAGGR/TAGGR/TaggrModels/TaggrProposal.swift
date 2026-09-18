import Foundation

struct TaggrProposalReply: Decodable, Sendable {
    let ok: TaggrProposal?
    let err: String?
    enum CodingKeys: String, CodingKey { case ok = "Ok", err = "Err" }
}

struct TaggrProposal: Decodable, Identifiable, Sendable {
    let id: Int
    let proposer: Int
    let timestamp: UInt64
    let postId: Int
    let status: String
    let payload: Payload
    let bulletins: [Bulletin]
    let votingPower: UInt64

    struct Bulletin: Decodable, Sendable {
        let userID: Int
        let adopted: Bool
        let power: UInt64
        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            userID = try row.decode(Int.self)
            adopted = try row.decode(Bool.self)
            power = try row.decode(UInt64.self)
        }
    }

    enum Payload: Decodable, Sendable {
        struct Release: Decodable, Sendable { let commit: String; let hash: String }
        struct Rewards: Decodable, Sendable { let receiver: String; let minted: UInt64 }
        case release(Release), rewards(Rewards), funding(String, UInt64), icpTransfer([UInt8], UInt64), realmController(String, Int), unsupported
        enum CodingKeys: String, CodingKey {
            case release = "Release", rewards = "Rewards", funding = "Funding"
            case icpTransfer = "ICPTransfer", realmController = "AddRealmController"
        }
        init(from decoder: Decoder) throws {
            if (try? decoder.singleValueContainer().decode(String.self)) != nil { self = .unsupported; return }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.release) { self = .release(try values.decode(Release.self, forKey: .release)) }
            else if values.contains(.rewards) { self = .rewards(try values.decode(Rewards.self, forKey: .rewards)) }
            else if values.contains(.funding) {
                var row = try values.nestedUnkeyedContainer(forKey: .funding)
                self = .funding(try row.decode(String.self), try row.decode(UInt64.self))
            } else if values.contains(.realmController) {
                var row = try values.nestedUnkeyedContainer(forKey: .realmController)
                self = .realmController(try row.decode(String.self), try row.decode(Int.self))
            } else if values.contains(.icpTransfer) {
                struct Tokens: Decodable { let e8s: UInt64 }
                var row = try values.nestedUnkeyedContainer(forKey: .icpTransfer)
                self = .icpTransfer(try row.decode([UInt8].self), try row.decode(Tokens.self).e8s)
            } else { self = .unsupported }
        }
        var title: String {
            switch self {
            case .release: "RELEASE"
            case .rewards: "REWARDS"
            case .funding: "FUNDING"
            case .icpTransfer: "ICP TRANSFER"
            case .realmController: "REALM CONTROLLER"
            case .unsupported: "UNSUPPORTED PROPOSAL TYPE"
            }
        }
    }

    func canVote(userID: Int?, canonical: Bool) -> Bool {
        guard let userID, canonical, status == "Open" else { return false }
        if case .unsupported = payload { return false }
        return !bulletins.contains { $0.userID == userID }
    }
    func voteData(adopted: Bool, input: String, decimals: Int, maximum: Int?) throws -> String {
        if case .unsupported = payload { throw TaggrAPIError.rejected("Unsupported proposal type.") }
        guard adopted else { return "" }
        switch payload {
        case .release:
            guard !input.isEmpty else { throw TaggrAPIError.rejected("Enter the reproducible build hash.") }
            return input
        case .rewards:
            guard let maximum, maximum >= 0, UInt64(input) != nil,
                  let quantity = FeatureAmount.parse(input, decimals: decimals), quantity <= UInt64(maximum) else {
                throw TaggrAPIError.rejected("Enter a whole-token reward within the configured maximum.")
            }
            return input
        default: return ""
        }
    }
    func power(adopted: Bool) -> UInt64 {
        bulletins.filter { $0.adopted == adopted }.reduce(0) { $0 &+ $1.power }
    }
    static func displayedPower(_ amount: UInt64, decimals: Int) -> UInt64 {
        guard decimals > 0 else { return amount }
        guard decimals <= 19 else { return amount == 0 ? 0 : 1 }
        let base = (0..<decimals).reduce(UInt64(1)) { value, _ in value * 10 }
        return amount / base + (amount % base == 0 ? 0 : 1)
    }
    func executionDays(threshold: Int) -> Int? {
        guard status == "Open", votingPower > 0, (1..<100).contains(threshold) else { return nil }
        let accepted = Double(power(adopted: true)), rejected = Double(power(adopted: false))
        let total = Double(votingPower)
        let required = accepted > rejected ? accepted / Double(threshold) : rejected / Double(100 - threshold)
        let days = ceil((total - required * 100) / (total / 100))
        guard days.isFinite, days >= Double(Int.min), days < Double(Int.max) else { return nil }
        return Int(days)
    }
    func percentage(adopted: Bool) -> String {
        guard votingPower > 0 else { return "0%" }
        let percent = ceil(Double(power(adopted: adopted)) / Double(votingPower) * 10000) / 100
        return percent.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2))) + "%"
    }
}
