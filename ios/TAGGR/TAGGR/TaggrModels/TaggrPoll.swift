import Foundation

struct TaggrPoll: Equatable {
    let options: [String]
    let votes: [Int: [Int]]
    let voters: [Int]
    let deadline: Int
    let weightedByKarma: [Int: Int]
    let weightedByTokens: [Int: Int]

    init?(value: JSONValue) {
        guard case .object(let object) = value else { return nil }
        options = object["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        votes = Self.intArrayMap(from: object["votes"])
        voters = object["voters"]?.arrayValue?.compactMap(\.intValue) ?? []
        deadline = object["deadline"]?.intValue ?? 0
        weightedByKarma = Self.intMap(from: object["weighted_by_karma"])
        weightedByTokens = Self.intMap(from: object["weighted_by_tokens"])
    }

    func voting(option: Int, userId: Int, anonymously: Bool) -> TaggrPoll {
        let anonymousMarker = -1
        var nextVotes = votes
        var nextVoters = voters
        for key in nextVotes.keys {
            nextVotes[key]?.removeAll { $0 == userId || $0 == anonymousMarker }
        }
        nextVotes[option, default: []].append(anonymously ? anonymousMarker : userId)
        if !nextVoters.contains(userId) {
            nextVoters.append(userId)
        }
        return TaggrPoll(
            options: options,
            votes: nextVotes,
            voters: nextVoters,
            deadline: deadline,
            weightedByKarma: weightedByKarma,
            weightedByTokens: weightedByTokens
        )
    }

    var jsonValue: JSONValue {
        .object([
            "options": .array(options.map { .string($0) }),
            "votes": .object(Self.jsonObject(from: votes)),
            "voters": .array(voters.map { .number(Double($0)) }),
            "deadline": .number(Double(deadline)),
            "weighted_by_karma": .object(Self.jsonObject(from: weightedByKarma)),
            "weighted_by_tokens": .object(Self.jsonObject(from: weightedByTokens)),
        ])
    }

    private init(
        options: [String],
        votes: [Int: [Int]],
        voters: [Int],
        deadline: Int,
        weightedByKarma: [Int: Int],
        weightedByTokens: [Int: Int]
    ) {
        self.options = options
        self.votes = votes
        self.voters = voters
        self.deadline = deadline
        self.weightedByKarma = weightedByKarma
        self.weightedByTokens = weightedByTokens
    }

    private static func intArrayMap(from value: JSONValue?) -> [Int: [Int]] {
        value?.objectValue?.reduce(into: [Int: [Int]]()) { result, pair in
            guard let key = Int(pair.key) else { return }
            result[key] = pair.value.arrayValue?.compactMap(\.intValue) ?? []
        } ?? [:]
    }

    private static func intMap(from value: JSONValue?) -> [Int: Int] {
        value?.objectValue?.reduce(into: [Int: Int]()) { result, pair in
            guard let key = Int(pair.key), let amount = pair.value.intValue else { return }
            result[key] = amount
        } ?? [:]
    }

    private static func jsonObject(from values: [Int: [Int]]) -> [String: JSONValue] {
        values.reduce(into: [String: JSONValue]()) { result, pair in
            result[String(pair.key)] = .array(pair.value.map { .number(Double($0)) })
        }
    }

    private static func jsonObject(from values: [Int: Int]) -> [String: JSONValue] {
        values.reduce(into: [String: JSONValue]()) { result, pair in
            result[String(pair.key)] = .number(Double(pair.value))
        }
    }
}
