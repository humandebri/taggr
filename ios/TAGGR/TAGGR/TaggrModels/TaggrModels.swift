import Foundation

struct TaggrBackendCache {
    let stats: TaggrStats?
    let config: TaggrConfig?
}

enum TaggrFeedMode: Equatable {
    case hot
    case latest
    case personal
    case realm(String)
}

struct TaggrPost: Identifiable, Equatable {
    let id: Int
    let parent: Int?
    let user: Int
    let body: String
    let effBody: String?
    let realm: String?
    let timestamp: LosslessInt
    let reactions: [String: [Int]]
    let children: [Int]
    let meta: TaggrPostMeta
    let watchers: [Int]
    let reposts: [Int]
    let files: [String: [LosslessInt]]
    let patches: [[JSONValue]]
    let tips: [[LosslessInt]]
    let hashes: [String]
    let extensionValue: JSONValue?
    let treeSize: Int?
    let treeUpdate: LosslessInt?
    let encrypted: Bool
    let hiddenFor: [Int]

    var displayBody: String {
        TaggrPostImages.textWithoutImageMarkdown(effBody ?? body)
    }

    func imageAttachments(config: TaggrRuntimeConfig = .current) -> [TaggrPostImageAttachment] {
        let bodyIds = TaggrPostImages.imageIDs(in: effBody ?? body)
        let ids = bodyIds.isEmpty ? files.keys.compactMap { $0.split(separator: "@").first.map(String.init) } : bodyIds
        var seen = Set<String>()
        return ids.compactMap { id in
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            guard let file = files.first(where: { $0.key.split(separator: "@").first.map(String.init) == id }),
                  let bucketId = file.key.split(separator: "@").dropFirst().first.map(String.init),
                  let offset = UInt64(exactly: file.value[0].value),
                  let length = Int(exactly: file.value[1].value),
                  let url = TaggrPostImages.imageURL(bucketId: bucketId, offset: offset, length: length, config: config) else {
                return nil
            }
            return TaggrPostImageAttachment(id: id, url: url)
        }
    }
}

struct TaggrPostImageAttachment: Identifiable, Equatable {
    let id: String
    let url: URL
}

enum TaggrPostImages {
    static func imageIDs(in text: String) -> [String] {
        matches(in: text).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    static func textWithoutImageMarkdown(_ text: String) -> String {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return imageMarkdownExpression
            .stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func imageURL(bucketId: String, offset: UInt64, length: Int, config: TaggrRuntimeConfig) -> URL? {
        var components = URLComponents()
        if config.apiBaseURL.scheme == "http" {
            components.scheme = "http"
            components.host = "\(bucketId).raw.localhost"
            components.port = config.apiBaseURL.port
        } else {
            components.scheme = "https"
            components.host = "\(bucketId).raw.icp0.io"
        }
        components.path = "/image"
        components.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "len", value: String(length)),
        ]
        return components.url
    }

    private static func matches(in text: String) -> [NSTextCheckingResult] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return imageMarkdownExpression.matches(in: text, range: nsRange)
    }

    private static let imageMarkdownExpression = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(/blob/([A-Za-z0-9_-]{1,32})\)"#
    )
}

struct TaggrPostMeta: Codable, Equatable {
    let authorName: String?
    let realmColor: String?
    let nsfw: Bool?
    let viewerBlocked: Bool?

    enum CodingKeys: String, CodingKey {
        case authorName = "author_name"
        case realmColor = "realm_color"
        case nsfw
        case viewerBlocked = "viewer_blocked"
    }
}

struct TaggrPostEnvelope: Decodable, Equatable {
    let post: TaggrPost

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let payload = try container.decode(TaggrPostPayload.self)
        let meta = try container.decode(TaggrPostMeta.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "TAGGR post envelope must contain exactly [post, meta]."
            )
        }
        post = payload.toPost(meta: meta)
    }
}

struct TaggrPostPayload: Decodable, Equatable {
    let id: Int
    let parent: Int?
    let user: Int
    let body: String
    let effBody: String?
    let realm: String?
    let timestamp: LosslessInt
    let reactions: [String: [Int]]
    let children: [Int]
    let watchers: [Int]
    let reposts: [Int]
    let files: [String: [LosslessInt]]
    let patches: [[JSONValue]]
    let tips: [[LosslessInt]]
    let hashes: [String]
    let extensionValue: JSONValue?
    let treeSize: Int?
    let treeUpdate: LosslessInt?
    let encrypted: Bool
    let hiddenFor: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case parent
        case user
        case body
        case effBody
        case realm
        case timestamp
        case reactions
        case children
        case watchers
        case reposts
        case files
        case patches
        case tips
        case hashes
        case extensionValue = "extension"
        case treeSize = "tree_size"
        case treeUpdate = "tree_update"
        case encrypted
        case hiddenFor = "hidden_for"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        parent = try values.decodeIfPresent(Int.self, forKey: .parent)
        user = try values.decode(Int.self, forKey: .user)
        body = try values.decode(String.self, forKey: .body)
        effBody = try values.decodeIfPresent(String.self, forKey: .effBody)
        realm = try values.decodeIfPresent(String.self, forKey: .realm)
        timestamp = try values.decode(LosslessInt.self, forKey: .timestamp)
        reactions = try values.decodeIfPresent([String: [Int]].self, forKey: .reactions) ?? [:]
        children = try values.decodeIfPresent([Int].self, forKey: .children) ?? []
        watchers = try values.decodeIfPresent([Int].self, forKey: .watchers) ?? []
        reposts = try values.decodeIfPresent([Int].self, forKey: .reposts) ?? []
        files = try values.decodeIfPresent([String: [LosslessInt]].self, forKey: .files) ?? [:]
        patches = try values.decodeIfPresent([[JSONValue]].self, forKey: .patches) ?? []
        tips = try values.decodeIfPresent([[LosslessInt]].self, forKey: .tips) ?? []
        hashes = try values.decodeIfPresent([String].self, forKey: .hashes) ?? []
        extensionValue = try values.decodeIfPresent(JSONValue.self, forKey: .extensionValue)
        treeSize = try values.decodeIfPresent(Int.self, forKey: .treeSize)
        treeUpdate = try values.decodeIfPresent(LosslessInt.self, forKey: .treeUpdate)
        encrypted = try values.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        hiddenFor = try values.decodeIfPresent([Int].self, forKey: .hiddenFor) ?? []
    }

    func toPost(meta: TaggrPostMeta) -> TaggrPost {
        TaggrPost(
            id: id,
            parent: parent,
            user: user,
            body: body,
            effBody: effBody,
            realm: realm,
            timestamp: timestamp,
            reactions: reactions,
            children: children,
            meta: meta,
            watchers: watchers,
            reposts: reposts,
            files: files,
            patches: patches,
            tips: tips,
            hashes: hashes,
            extensionValue: extensionValue,
            treeSize: treeSize,
            treeUpdate: treeUpdate,
            encrypted: encrypted,
            hiddenFor: hiddenFor
        )
    }
}

enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

struct TaggrUser: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let about: String
    let principal: String?
    let realms: [String]
    let followees: [Int]
    let followers: [Int]
    let blacklist: [Int]
    let mode: String?
}

struct TaggrRealm: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let labelColor: String?
    let numMembers: Int?
    let numPosts: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case labelColor = "label_color"
        case numMembers = "num_members"
        case numPosts = "num_posts"
    }
}

struct TaggrStats: Codable, Equatable {
    let users: Int?
    let posts: Int?
    let comments: Int?
    let realms: Int?
    let canisterId: String?

    enum CodingKeys: String, CodingKey {
        case users
        case posts
        case comments
        case realms
        case canisterId = "canister_id"
    }
}

struct TaggrConfig: Codable, Equatable {
    let name: String?
    let tokenSymbol: String?
    let maxPostLength: Int?
    let maxReportLength: Int?
    let reactions: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case name
        case tokenSymbol = "token_symbol"
        case maxPostLength = "max_post_length"
        case maxReportLength = "max_report_length"
        case reactions
    }
}

struct LosslessInt: Codable, Equatable, Comparable {
    let value: Int64

    init(_ value: Int64) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self), let intValue = Int64(stringValue) {
            value = intValue
            return
        }
        value = 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func < (lhs: LosslessInt, rhs: LosslessInt) -> Bool {
        lhs.value < rhs.value
    }
}
