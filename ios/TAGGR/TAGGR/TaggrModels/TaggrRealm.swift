import Foundation

struct TaggrRealmFilter: Codable, Equatable, Sendable {
    let ageDays: Int
    let safe: Bool
    let balance: Int
    let numFollowers: Int

    init(ageDays: Int = 0, safe: Bool = false, balance: Int = 0, numFollowers: Int = 0) {
        self.ageDays = ageDays
        self.safe = safe
        self.balance = balance
        self.numFollowers = numFollowers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ageDays = try values.decodeIfPresent(Int.self, forKey: .ageDays) ?? 0
        safe = try values.decodeIfPresent(Bool.self, forKey: .safe) ?? false
        balance = try values.decodeIfPresent(Int.self, forKey: .balance) ?? 0
        numFollowers = try values.decodeIfPresent(Int.self, forKey: .numFollowers) ?? 0
    }

    var jsonObject: [String: Any] {
        [
            "age_days": ageDays,
            "safe": safe,
            "balance": balance,
            "num_followers": numFollowers,
        ]
    }
}

struct TaggrRealm: Decodable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let cleanupPenalty: Int
    let controllers: [Int]
    let description: String
    let filter: TaggrRealmFilter
    let labelColor: String?
    let lastSettingUpdate: UInt64
    let lastUpdate: UInt64
    let logo: String?
    let maxDownvotes: Int
    let numMembers: Int?
    let numPosts: Int?
    let revenue: Int
    let theme: String
    let whitelist: [Int]
    let created: UInt64
    let posts: [Int]
    let adultContent: Bool
    let commentsFiltering: Bool
    let hasCompleteSettings: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case cleanupPenalty
        case controllers
        case description
        case filter
        case labelColor
        case lastSettingUpdate
        case lastUpdate
        case logo
        case maxDownvotes
        case numMembers
        case numPosts
        case revenue
        case theme
        case whitelist
        case created
        case posts
        case adultContent
        case commentsFiltering
    }

    init(
        name: String,
        description: String,
        labelColor: String?,
        logo: String?,
        numMembers: Int?,
        numPosts: Int?,
        cleanupPenalty: Int = 0,
        controllers: [Int] = [],
        filter: TaggrRealmFilter = TaggrRealmFilter(),
        lastSettingUpdate: UInt64 = 0,
        lastUpdate: UInt64 = 0,
        maxDownvotes: Int = 0,
        revenue: Int = 0,
        theme: String = "",
        whitelist: [Int] = [],
        created: UInt64 = 0,
        posts: [Int] = [],
        adultContent: Bool = false,
        commentsFiltering: Bool = true,
        hasCompleteSettings: Bool = false
    ) {
        self.name = name
        self.cleanupPenalty = cleanupPenalty
        self.controllers = controllers
        self.description = description
        self.filter = filter
        self.labelColor = labelColor
        self.lastSettingUpdate = lastSettingUpdate
        self.lastUpdate = lastUpdate
        self.logo = logo
        self.maxDownvotes = maxDownvotes
        self.numMembers = numMembers
        self.numPosts = numPosts
        self.revenue = revenue
        self.theme = theme
        self.whitelist = whitelist
        self.created = created
        self.posts = posts
        self.adultContent = adultContent
        self.commentsFiltering = commentsFiltering
        self.hasCompleteSettings = hasCompleteSettings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        cleanupPenalty = try values.decodeIfPresent(Int.self, forKey: .cleanupPenalty) ?? 0
        controllers = try values.decodeIfPresent([Int].self, forKey: .controllers) ?? []
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        filter = try values.decodeIfPresent(TaggrRealmFilter.self, forKey: .filter) ?? TaggrRealmFilter()
        labelColor = try values.decodeIfPresent(String.self, forKey: .labelColor)
        lastSettingUpdate = try values.decodeIfPresent(UInt64.self, forKey: .lastSettingUpdate) ?? 0
        lastUpdate = try values.decodeIfPresent(UInt64.self, forKey: .lastUpdate) ?? 0
        logo = try values.decodeIfPresent(String.self, forKey: .logo)
        maxDownvotes = try values.decodeIfPresent(Int.self, forKey: .maxDownvotes) ?? 0
        numMembers = try values.decodeIfPresent(Int.self, forKey: .numMembers)
        numPosts = try values.decodeIfPresent(Int.self, forKey: .numPosts)
        revenue = try values.decodeIfPresent(Int.self, forKey: .revenue) ?? 0
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? ""
        whitelist = try values.decodeIfPresent([Int].self, forKey: .whitelist) ?? []
        created = try values.decodeIfPresent(UInt64.self, forKey: .created) ?? 0
        posts = try values.decodeIfPresent([Int].self, forKey: .posts) ?? []
        adultContent = try values.decodeIfPresent(Bool.self, forKey: .adultContent) ?? false
        commentsFiltering = try values.decodeIfPresent(Bool.self, forKey: .commentsFiltering) ?? true
        hasCompleteSettings = values.contains(.controllers) && values.contains(.filter) && values.contains(.whitelist)
    }

    func renamed(_ name: String) -> TaggrRealm {
        TaggrRealm(
            name: name,
            description: description,
            labelColor: labelColor,
            logo: logo,
            numMembers: numMembers,
            numPosts: numPosts,
            cleanupPenalty: cleanupPenalty,
            controllers: controllers,
            filter: filter,
            lastSettingUpdate: lastSettingUpdate,
            lastUpdate: lastUpdate,
            maxDownvotes: maxDownvotes,
            revenue: revenue,
            theme: theme,
            whitelist: whitelist,
            created: created,
            posts: posts,
            adultContent: adultContent,
            commentsFiltering: commentsFiltering,
            hasCompleteSettings: hasCompleteSettings
        )
    }

    func editPayload(
        description: String,
        labelColor: String,
        logo: String?,
        cleanupPenalty: Int,
        maxDownvotes: Int,
        adultContent: Bool,
        commentsFiltering: Bool
    ) throws -> [String: Any] {
        guard hasCompleteSettings else {
            throw TaggrAPIError.invalidResponse("Realm settings are incomplete. Reload the realm and try again")
        }
        return [
            "cleanup_penalty": cleanupPenalty,
            "controllers": controllers,
            "description": description,
            "filter": filter.jsonObject,
            "label_color": labelColor,
            "last_setting_update": lastSettingUpdate,
            "last_update": lastUpdate,
            "logo": logo ?? self.logo ?? "",
            "max_downvotes": maxDownvotes,
            "num_members": numMembers ?? 0,
            "num_posts": numPosts ?? 0,
            "revenue": revenue,
            "theme": theme,
            "whitelist": whitelist,
            "created": created,
            "posts": posts,
            "adult_content": adultContent,
            "comments_filtering": commentsFiltering,
        ]
    }
}

struct TaggrRealmSettingsDraft: Equatable, Sendable {
    var description: String
    var labelColor: String
    var logo: String?
    var cleanupPenalty: Int
    var maxDownvotes: Int
    var adultContent: Bool
    var commentsFiltering: Bool

    init(realm: TaggrRealm) {
        description = realm.description
        labelColor = realm.labelColor ?? "#000000"
        logo = nil
        cleanupPenalty = realm.cleanupPenalty
        maxDownvotes = realm.maxDownvotes
        adultContent = realm.adultContent
        commentsFiltering = realm.commentsFiltering
    }

    func payload(
        for realm: TaggrRealm,
        maxCleanupPenalty: Int?,
        maxLogoLength: Int?
    ) throws -> [String: Any] {
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDescription.isEmpty else {
            throw TaggrAPIError.rejected("Realm description is required.")
        }
        guard normalizedDescription.count <= 2_000 else {
            throw TaggrAPIError.rejected("Realm description must be 2,000 characters or fewer.")
        }
        guard labelColor.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            throw TaggrAPIError.rejected("Label color must use #RRGGBB format.")
        }
        guard cleanupPenalty >= 0, maxDownvotes >= 0 else {
            throw TaggrAPIError.rejected("Realm numeric settings cannot be negative.")
        }
        if let maxCleanupPenalty, cleanupPenalty > maxCleanupPenalty {
            throw TaggrAPIError.rejected("Cleanup penalty cannot exceed \(maxCleanupPenalty).")
        }
        if let logo, let maxLogoLength, logo.utf8.count > maxLogoLength {
            throw TaggrAPIError.rejected("Realm logo must be smaller than \(maxLogoLength.formatted()) bytes.")
        }
        return try realm.editPayload(
            description: normalizedDescription,
            labelColor: labelColor.uppercased(),
            logo: logo,
            cleanupPenalty: cleanupPenalty,
            maxDownvotes: maxDownvotes,
            adultContent: adultContent,
            commentsFiltering: commentsFiltering
        )
    }
}

struct TaggrRealmListEntry: Decodable, Equatable, Sendable {
    let name: String
    let realm: TaggrRealm

    var namedRealm: TaggrRealm {
        realm.renamed(realm.name.isEmpty ? name : realm.name)
    }

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        name = try values.decode(String.self)
        realm = try values.decode(TaggrRealm.self)
    }
}
