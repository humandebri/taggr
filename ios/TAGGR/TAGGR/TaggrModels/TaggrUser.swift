import Foundation

struct TaggrUserFilters: Codable, Equatable, Sendable {
    let users: [Int]
    var noise = TaggrRealmFilter()

    init(users: [Int] = []) { self.users = users }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        users = try values.decodeIfPresent([Int].self, forKey: .users) ?? []
        noise = try values.decodeIfPresent(TaggrRealmFilter.self, forKey: .noise) ?? TaggrRealmFilter()
    }
}

struct TaggrUser: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let about: String
    let principal: String?
    let realms: [String]
    let followees: [Int]
    let followers: [Int]
    let blacklist: [Int]
    let filters: TaggrUserFilters
    let bookmarks: [Int]
    let pinnedPosts: [Int]
    let settings: [String: String]
    let controlledRealms: [String]
    let controllers: [String]
    var governance: Bool = true
    var showPostsInRealms: Bool = true
    let stalwart: Bool
    let notifications: [Int: TaggrNotificationEntry]
    let bucket: String?
    let mode: String?
    let numPosts: Int?
    let balance: Int?
    let rewards: Int?
    let cycles: Int?
    let treasuryE8s: Int?
    let activeWeeks: Int?
    let timestamp: LosslessInt?
    let lastActivity: LosslessInt?
    let deactivated: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case about
        case principal
        case realms
        case followees
        case followers
        case blacklist
        case filters
        case bookmarks
        case pinnedPosts
        case settings
        case controlledRealms
        case controllers
        case governance, showPostsInRealms
        case stalwart
        case notifications
        case bucket
        case mode
        case numPosts
        case balance
        case rewards
        case cycles
        case treasuryE8s
        case activeWeeks
        case timestamp
        case lastActivity
        case deactivated
    }

    init(
        id: Int,
        name: String,
        about: String,
        principal: String?,
        realms: [String],
        followees: [Int],
        followers: [Int],
        blacklist: [Int],
        filters: TaggrUserFilters = TaggrUserFilters(),
        bookmarks: [Int] = [],
        pinnedPosts: [Int] = [],
        settings: [String: String] = [:],
        controlledRealms: [String] = [],
        controllers: [String] = [],
        stalwart: Bool = false,
        notifications: [Int: TaggrNotificationEntry] = [:],
        bucket: String? = nil,
        mode: String?,
        numPosts: Int? = nil,
        balance: Int? = nil,
        rewards: Int? = nil,
        cycles: Int? = nil,
        treasuryE8s: Int? = nil,
        activeWeeks: Int? = nil,
        timestamp: LosslessInt? = nil,
        lastActivity: LosslessInt? = nil,
        deactivated: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.about = about
        self.principal = principal
        self.realms = realms
        self.followees = followees
        self.followers = followers
        self.blacklist = blacklist
        self.filters = filters
        self.bookmarks = bookmarks
        self.pinnedPosts = pinnedPosts
        self.settings = settings
        self.controlledRealms = controlledRealms
        self.controllers = controllers
        self.stalwart = stalwart
        self.notifications = notifications
        self.bucket = bucket
        self.mode = mode
        self.numPosts = numPosts
        self.balance = balance
        self.rewards = rewards
        self.cycles = cycles
        self.treasuryE8s = treasuryE8s
        self.activeWeeks = activeWeeks
        self.timestamp = timestamp
        self.lastActivity = lastActivity
        self.deactivated = deactivated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        about = try values.decodeIfPresent(String.self, forKey: .about) ?? ""
        principal = try values.decodeIfPresent(String.self, forKey: .principal)
        realms = try values.decodeIfPresent([String].self, forKey: .realms) ?? []
        followees = try values.decodeIfPresent([Int].self, forKey: .followees) ?? []
        followers = try values.decodeIfPresent([Int].self, forKey: .followers) ?? []
        blacklist = try values.decodeIfPresent([Int].self, forKey: .blacklist) ?? []
        filters = try values.decodeIfPresent(TaggrUserFilters.self, forKey: .filters) ?? TaggrUserFilters()
        bookmarks = try values.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        pinnedPosts = try values.decodeIfPresent([Int].self, forKey: .pinnedPosts) ?? []
        settings = try values.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        controlledRealms = try values.decodeIfPresent([String].self, forKey: .controlledRealms) ?? []
        controllers = try values.decodeIfPresent([String].self, forKey: .controllers) ?? []
        governance = try values.decodeIfPresent(Bool.self, forKey: .governance) ?? true
        showPostsInRealms = try values.decodeIfPresent(Bool.self, forKey: .showPostsInRealms) ?? true
        stalwart = try values.decodeIfPresent(Bool.self, forKey: .stalwart) ?? false
        notifications = try values.decodeIfPresent([Int: TaggrNotificationEntry].self, forKey: .notifications) ?? [:]
        bucket = try values.decodeIfPresent(String.self, forKey: .bucket)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        numPosts = try values.decodeIfPresent(Int.self, forKey: .numPosts)
        balance = try values.decodeIfPresent(Int.self, forKey: .balance)
        rewards = try values.decodeIfPresent(Int.self, forKey: .rewards)
        cycles = try values.decodeIfPresent(Int.self, forKey: .cycles)
        treasuryE8s = try values.decodeIfPresent(Int.self, forKey: .treasuryE8s)
        activeWeeks = try values.decodeIfPresent(Int.self, forKey: .activeWeeks)
        timestamp = try values.decodeIfPresent(LosslessInt.self, forKey: .timestamp)
        lastActivity = try values.decodeIfPresent(LosslessInt.self, forKey: .lastActivity)
        deactivated = try values.decodeIfPresent(Bool.self, forKey: .deactivated)
    }

    func updatingNotifications(_ notifications: [Int: TaggrNotificationEntry]) -> TaggrUser {
        var copy = TaggrUser(
            id: id,
            name: name,
            about: about,
            principal: principal,
            realms: realms,
            followees: followees,
            followers: followers,
            blacklist: blacklist,
            filters: filters,
            bookmarks: bookmarks,
            pinnedPosts: pinnedPosts,
            settings: settings,
            controlledRealms: controlledRealms,
            controllers: controllers,
            stalwart: stalwart,
            notifications: notifications,
            bucket: bucket,
            mode: mode,
            numPosts: numPosts,
            balance: balance,
            rewards: rewards,
            cycles: cycles,
            treasuryE8s: treasuryE8s,
            activeWeeks: activeWeeks,
            timestamp: timestamp,
            lastActivity: lastActivity,
            deactivated: deactivated
        )
        copy.governance = governance
        copy.showPostsInRealms = showPostsInRealms
        return copy
    }

    func updatingSettings(_ settings: [String: String]) -> TaggrUser {
        var copy = TaggrUser(
            id: id,
            name: name,
            about: about,
            principal: principal,
            realms: realms,
            followees: followees,
            followers: followers,
            blacklist: blacklist,
            filters: filters,
            bookmarks: bookmarks,
            pinnedPosts: pinnedPosts,
            settings: settings,
            controlledRealms: controlledRealms,
            controllers: controllers,
            stalwart: stalwart,
            notifications: notifications,
            bucket: bucket,
            mode: mode,
            numPosts: numPosts,
            balance: balance,
            rewards: rewards,
            cycles: cycles,
            treasuryE8s: treasuryE8s,
            activeWeeks: activeWeeks,
            timestamp: timestamp,
            lastActivity: lastActivity,
            deactivated: deactivated
        )
        copy.governance = governance
        copy.showPostsInRealms = showPostsInRealms
        return copy
    }

}
