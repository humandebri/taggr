import Foundation

struct TaggrPollPresentation: Equatable {
    static let maximumSafeUserID = 9_007_199_254_740_991
    static let specialUserRange = 1_000

    let poll: TaggrPoll
    let postTimestamp: LosslessInt
    let userID: Int?
    let revoteDeadlineHours: Int
    let changingVote: Bool
    let now: Date

    var createdHoursAgo: Int {
        let created = Double(postTimestamp.value) / 1_000_000_000
        return Int(floor((now.timeIntervalSince1970 - created) / 3_600))
    }

    var remainingHours: Int {
        poll.deadline - createdHoursAgo
    }

    var isExpired: Bool {
        createdHoursAgo >= poll.deadline
    }

    var hasVisibleVote: Bool {
        guard let userID else { return false }
        return poll.votes.values.contains { $0.contains(userID) }
    }

    var votedAnonymously: Bool {
        guard let userID else { return false }
        return poll.voters.contains(userID) && !hasVisibleVote
    }

    var hasVoted: Bool {
        guard let userID else { return false }
        return poll.voters.contains(userID) || hasVisibleVote
    }

    var showsVotingControls: Bool {
        userID != nil && (!hasVoted || changingVote) && !isExpired
    }

    var canChangeVote: Bool {
        !changingVote && hasVisibleVote && !votedAnonymously && remainingHours > revoteDeadlineHours
    }

    var displayedVotes: [Int: [Int]] {
        guard changingVote, let userID else { return poll.votes }
        return poll.votes.mapValues { voters in
            voters.filter { $0 != userID }
        }
    }

    var totalVotes: Int {
        displayedVotes.values.reduce(0) { $0 + $1.count }
    }

    var expirationText: String {
        let days = remainingHours / 24
        if days > 0 {
            return "EXPIRES IN \(days) DAY\(days == 1 ? "" : "S")"
        }
        return "EXPIRES IN \(max(1, remainingHours))H"
    }

    func percentage(for option: Int) -> Int {
        guard totalVotes > 0 else { return 0 }
        let votes = displayedVotes[option]?.count ?? 0
        return Int(ceil(Double(votes) / Double(totalVotes) * 100))
    }

    func votingPower(for option: Int, tokenDecimals: Int?) -> String? {
        guard let amount = poll.weightedByTokens[option] else { return nil }
        let decimals = max(tokenDecimals ?? 0, 0)
        let base = (0..<decimals).reduce(1) { value, _ in value * 10 }
        let roundedUp = amount / base + (amount % base == 0 ? 0 : 1)
        return roundedUp.formatted()
    }

    static func isResolvableUserID(_ userID: Int) -> Bool {
        userID >= 0 && userID < maximumSafeUserID - specialUserRange
    }
}
