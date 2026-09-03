import Foundation

struct TaggrBackendCache: Sendable {
    let stats: TaggrStats?
    let config: TaggrConfig?
}

enum TaggrFeedMode: Hashable, Sendable {
    case hot
    case latest
    case personal
    case realm(String)
    case tags([String])
}

struct TaggrPost: Identifiable, Equatable, Sendable {
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

    var extensionKind: TaggrPostExtension {
        TaggrPostExtension(value: extensionValue)
    }

    var displayBody: String {
        TaggrPostImages.textWithoutImageMarkdown(effBody ?? body)
    }

    func deletionVersions() throws -> [String] {
        var current = body
        var versions = [current]
        for values in patches.reversed() {
            guard values.count >= 2, let patch = values[1].stringValue else {
                throw TaggrEditPatchError.malformedPatch
            }
            current = try TaggrEditPatch.apply(patch, to: current)
            versions.append(current)
        }
        return Array(versions.reversed())
    }

    func imageAttachments(config: TaggrRuntimeConfig = .current, bodyText: String? = nil) -> [TaggrPostImageAttachment] {
        let references = TaggrPostImages.imageReferences(in: bodyText ?? effBody ?? body)
        var seen = Set<String>()

        if references.isEmpty {
            return files.keys.compactMap { $0.split(separator: "@").first.map(String.init) }.compactMap { id in
                imageAttachment(forBlobID: id, config: config, seen: &seen)
            }
        }

        return references.compactMap { reference in
            if let id = reference.blobID {
                return imageAttachment(forBlobID: id, config: config, seen: &seen)
            }
            guard let url = reference.remoteURL else { return nil }
            let id = "remote-\(url.absoluteString)"
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            return TaggrPostImageAttachment(id: id, url: url)
        }
    }

    func editableImageAttachments(
        config: TaggrRuntimeConfig = .current,
        bodyText: String
    ) -> [TaggrEditablePostImage] {
        let references = TaggrPostImages.imageReferences(in: bodyText)
        guard !references.isEmpty else {
            let originalReferences = TaggrPostImages.imageReferences(in: effBody ?? body)
            guard originalReferences.isEmpty else { return [] }
            return imageAttachments(config: config, bodyText: bodyText).map {
                TaggrEditablePostImage(attachment: $0, markdownReferences: [])
            }
        }

        var items: [TaggrEditablePostImage] = []
        var indexes: [String: Int] = [:]
        var seen = Set<String>()
        for reference in references {
            let attachment: TaggrPostImageAttachment?
            if let id = reference.blobID {
                if let index = indexes[id] {
                    items[index].markdownReferences.append(reference.markdown)
                    continue
                }
                attachment = imageAttachment(forBlobID: id, config: config, seen: &seen)
            } else if let url = reference.remoteURL {
                let id = "remote-\(url.absoluteString)"
                if let index = indexes[id] {
                    items[index].markdownReferences.append(reference.markdown)
                    continue
                }
                attachment = TaggrPostImageAttachment(id: id, url: url)
            } else {
                attachment = nil
            }
            guard let attachment else { continue }
            indexes[attachment.id] = items.count
            items.append(
                TaggrEditablePostImage(
                    attachment: attachment,
                    markdownReferences: [reference.markdown]
                )
            )
        }
        return items
    }

    private func imageAttachment(
        forBlobID id: String,
        config: TaggrRuntimeConfig,
        seen: inout Set<String>
    ) -> TaggrPostImageAttachment? {
        guard !seen.contains(id) else { return nil }
        seen.insert(id)
        guard let file = files.first(where: { $0.key.split(separator: "@").first.map(String.init) == id }),
              file.value.count >= 2,
              let bucketId = file.key.split(separator: "@").dropFirst().first.map(String.init),
              let offset = UInt64(exactly: file.value[0].value),
              let length = Int(exactly: file.value[1].value),
              let url = TaggrPostImages.imageURL(bucketId: bucketId, offset: offset, length: length, config: config) else {
            return nil
        }
        return TaggrPostImageAttachment(id: id, url: url, bucketId: bucketId, offset: offset, length: length)
    }

    func addingReaction(_ reaction: Int, by userId: Int) -> TaggrPost {
        guard !reactions.values.contains(where: { $0.contains(userId) }) else {
            return self
        }
        var updatedReactions = reactions
        updatedReactions[String(reaction), default: []].append(userId)
        return TaggrPost(
            id: id,
            parent: parent,
            user: user,
            body: body,
            effBody: effBody,
            realm: realm,
            timestamp: timestamp,
            reactions: updatedReactions,
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

    func updatingHiddenFor(_ hiddenFor: [Int]) -> TaggrPost {
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

    func replacingExtension(_ extensionKind: TaggrPostExtension) -> TaggrPost {
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
            extensionValue: extensionKind.jsonValue,
            treeSize: treeSize,
            treeUpdate: treeUpdate,
            encrypted: encrypted,
            hiddenFor: hiddenFor
        )
    }
}

struct TaggrPostImageAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let bucketId: String?
    let offset: UInt64?
    let length: Int?

    init(id: String, url: URL, bucketId: String? = nil, offset: UInt64? = nil, length: Int? = nil) {
        self.id = id
        self.url = url
        self.bucketId = bucketId
        self.offset = offset
        self.length = length
    }

    func shouldLoadThroughAPI(config: TaggrRuntimeConfig) -> Bool {
        config.shouldLoadBucketImagesThroughAPI && bucketId != nil && offset != nil && length != nil
    }
}

struct TaggrEditablePostImage: Identifiable, Equatable, Sendable {
    let attachment: TaggrPostImageAttachment
    var markdownReferences: [String]

    var id: String { attachment.id }

    var isRemovable: Bool {
        !markdownReferences.isEmpty
    }
}

enum TaggrPostExtension: Equatable {
    case poll(TaggrPoll)
    case repost(Int)
    case proposal(Int)
    case feature
    case none
    case unknown

    init(value: JSONValue?) {
        guard let value else {
            self = .none
            return
        }
        if case .string("Feature") = value {
            self = .feature
            return
        }
        guard case .object(let object) = value else {
            self = .unknown
            return
        }
        if let pollValue = object["Poll"], let poll = TaggrPoll(value: pollValue) {
            self = .poll(poll)
        } else if let postId = object["Repost"]?.intValue {
            self = .repost(postId)
        } else if let proposalId = object["Proposal"]?.intValue {
            self = .proposal(proposalId)
        } else {
            self = .unknown
        }
    }

    var jsonValue: JSONValue? {
        switch self {
        case .poll(let poll):
            return .object(["Poll": poll.jsonValue])
        case .repost(let id):
            return .object(["Repost": .number(Double(id))])
        case .proposal(let id):
            return .object(["Proposal": .number(Double(id))])
        case .feature:
            return .string("Feature")
        case .none:
            return nil
        case .unknown:
            return .null
        }
    }
}

struct TaggrPoll: Equatable {
    let options: [String]
    let votes: [Int: [Int]]
    let voters: [Int]
    let deadline: Int

    init?(value: JSONValue) {
        guard case .object(let object) = value else { return nil }
        options = object["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        votes = object["votes"]?.objectValue?.reduce(into: [Int: [Int]]()) { result, pair in
            guard let option = Int(pair.key) else { return }
            result[option] = pair.value.arrayValue?.compactMap(\.intValue) ?? []
        } ?? [:]
        voters = object["voters"]?.arrayValue?.compactMap(\.intValue) ?? []
        deadline = object["deadline"]?.intValue ?? 0
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
        return TaggrPoll(options: options, votes: nextVotes, voters: nextVoters, deadline: deadline)
    }

    var jsonValue: JSONValue {
        let voteObject = votes.reduce(into: [String: JSONValue]()) { result, pair in
            result[String(pair.key)] = .array(pair.value.map { .number(Double($0)) })
        }
        return .object([
            "options": .array(options.map { .string($0) }),
            "votes": .object(voteObject),
            "voters": .array(voters.map { .number(Double($0)) }),
            "deadline": .number(Double(deadline)),
        ])
    }

    private init(options: [String], votes: [Int: [Int]], voters: [Int], deadline: Int) {
        self.options = options
        self.votes = votes
        self.voters = voters
        self.deadline = deadline
    }
}

fileprivate struct TaggrPostImageReference: Equatable {
    let alt: String
    let destination: String
    let markdown: String

    var blobID: String? {
        let prefix = "/blob/"
        guard destination.hasPrefix(prefix) else { return nil }
        let id = String(destination.dropFirst(prefix.count))
        return TaggrPostImages.isValidBlobID(id) ? id : nil
    }

    var remoteURL: URL? {
        guard let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}

struct TaggrNotificationEntry: Codable, Equatable, Sendable {
    let notification: TaggrNotification
    let read: Bool

    init(notification: TaggrNotification, read: Bool) {
        self.notification = notification
        self.read = read
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        notification = try container.decode(TaggrNotification.self)
        read = try container.decode(Bool.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "TAGGR notification entry must contain exactly [notification, read]."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(notification)
        try container.encode(read)
    }
}

enum TaggrNotification: Codable, Equatable, Sendable {
    case generic(String)
    case watchedPostEntries(postId: Int, entries: [Int])
    case conditional(message: String, predicate: TaggrNotificationPredicate)
    case newPost(message: String, postId: Int)

    enum CodingKeys: String, CodingKey {
        case generic = "Generic"
        case watchedPostEntries = "WatchedPostEntries"
        case conditional = "Conditional"
        case newPost = "NewPost"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .generic) {
            self = .generic(value)
            return
        }
        if container.contains(.watchedPostEntries) {
            var values = try container.nestedUnkeyedContainer(forKey: .watchedPostEntries)
            let postId = try values.decode(Int.self)
            let entries = try values.decode([Int].self)
            self = .watchedPostEntries(postId: postId, entries: entries)
            return
        }
        if container.contains(.conditional) {
            var values = try container.nestedUnkeyedContainer(forKey: .conditional)
            let message = try values.decode(String.self)
            let predicate = try values.decode(TaggrNotificationPredicate.self)
            self = .conditional(message: message, predicate: predicate)
            return
        }
        if container.contains(.newPost) {
            var values = try container.nestedUnkeyedContainer(forKey: .newPost)
            let message = try values.decode(String.self)
            let postId = try values.decode(Int.self)
            self = .newPost(message: message, postId: postId)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .generic,
            in: container,
            debugDescription: "Unknown TAGGR notification variant."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .generic(let message):
            try container.encode(message, forKey: .generic)
        case .watchedPostEntries(let postId, let entries):
            var values = container.nestedUnkeyedContainer(forKey: .watchedPostEntries)
            try values.encode(postId)
            try values.encode(entries)
        case .conditional(let message, let predicate):
            var values = container.nestedUnkeyedContainer(forKey: .conditional)
            try values.encode(message)
            try values.encode(predicate)
        case .newPost(let message, let postId):
            var values = container.nestedUnkeyedContainer(forKey: .newPost)
            try values.encode(message)
            try values.encode(postId)
        }
    }

    var message: String {
        switch self {
        case .generic(let message), .newPost(let message, _), .conditional(let message, _):
            message
        case .watchedPostEntries(_, let entries):
            "\(entries.count) new thread update(s) on a watched post."
        }
    }

    var postId: Int? {
        switch self {
        case .newPost(_, let postId), .watchedPostEntries(let postId, _):
            postId
        case .conditional(_, let predicate):
            predicate.postId
        case .generic:
            nil
        }
    }

    var watchedEntryIds: [Int] {
        guard case .watchedPostEntries(_, let entries) = self else { return [] }
        return entries
    }
}

enum TaggrNotificationPredicate: Codable, Equatable, Sendable {
    case reportOpen(Int)
    case userReportOpen(Int)
    case proposal(Int)

    enum CodingKeys: String, CodingKey {
        case reportOpen = "ReportOpen"
        case userReportOpen = "UserReportOpen"
        case proposal = "Proposal"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(Int.self, forKey: .reportOpen) {
            self = .reportOpen(id)
            return
        }
        if let id = try container.decodeIfPresent(Int.self, forKey: .userReportOpen) {
            self = .userReportOpen(id)
            return
        }
        if let id = try container.decodeIfPresent(Int.self, forKey: .proposal) {
            self = .proposal(id)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .proposal,
            in: container,
            debugDescription: "Unknown TAGGR notification predicate."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reportOpen(let id):
            try container.encode(id, forKey: .reportOpen)
        case .userReportOpen(let id):
            try container.encode(id, forKey: .userReportOpen)
        case .proposal(let id):
            try container.encode(id, forKey: .proposal)
        }
    }

    var postId: Int? {
        switch self {
        case .reportOpen(let id), .proposal(let id):
            id
        case .userReportOpen:
            nil
        }
    }
}

enum TaggrPostImages {
    static func imageIDs(in text: String) -> [String] {
        imageReferences(in: text).compactMap(\.blobID)
    }

    static func textWithoutImageMarkdown(_ text: String) -> String {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return imageMarkdownExpression
            .stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func imageReferences(in text: String) -> [TaggrPostImageReference] {
        matches(in: text).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let markdownRange = Range(match.range, in: text),
                  let altRange = Range(match.range(at: 1), in: text),
                  let destinationRange = Range(match.range(at: 2), in: text) else {
                return nil
            }
            return TaggrPostImageReference(
                alt: String(text[altRange]),
                destination: String(text[destinationRange]),
                markdown: String(text[markdownRange])
            )
        }
    }

    static func removingImageMarkdown(_ references: [String], from text: String) -> String {
        references.reduce(text) { result, markdown in
            result
                .replacingOccurrences(of: markdown + "\n", with: "")
                .replacingOccurrences(of: "\n" + markdown, with: "")
                .replacingOccurrences(of: markdown, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidBlobID(_ id: String) -> Bool {
        blobIDExpression.firstMatch(
            in: id,
            range: NSRange(id.startIndex..<id.endIndex, in: id)
        ) != nil
    }

    static func imageURL(bucketId: String, offset: UInt64, length: Int, config: TaggrRuntimeConfig) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(bucketId).raw.icp0.io"
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
        pattern: #"!\[([^\]]*)\]\((\S+?)(?:\s+["'][^"']*["'])?\)"#
    )

    private static let blobIDExpression = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9_-]{1,32}$"#
    )
}

struct TaggrPostMeta: Codable, Equatable, Sendable {
    let authorName: String?
    let realmColor: String?
    let nsfw: Bool?
    let viewerBlocked: Bool?
    let maxDownvotesReached: Bool?

    enum CodingKeys: String, CodingKey {
        case authorName
        case realmColor
        case nsfw
        case viewerBlocked
        case maxDownvotesReached
    }

    init(
        authorName: String?,
        realmColor: String?,
        nsfw: Bool?,
        viewerBlocked: Bool?,
        maxDownvotesReached: Bool? = nil
    ) {
        self.authorName = authorName
        self.realmColor = realmColor
        self.nsfw = nsfw
        self.viewerBlocked = viewerBlocked
        self.maxDownvotesReached = maxDownvotesReached
    }
}

struct TaggrPostEnvelope: Decodable, Equatable, Sendable {
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

struct TaggrPostPayload: Decodable, Equatable, Sendable {
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
        case treeSize
        case treeUpdate
        case encrypted
        case hiddenFor
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

enum JSONValue: Decodable, Equatable, Sendable {
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

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(exactly: value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
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
    let bookmarks: [Int]
    let pinnedPosts: [Int]
    let settings: [String: String]
    let controlledRealms: [String]
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
        case bookmarks
        case pinnedPosts
        case settings
        case controlledRealms
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
        bookmarks: [Int] = [],
        pinnedPosts: [Int] = [],
        settings: [String: String] = [:],
        controlledRealms: [String] = [],
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
        self.bookmarks = bookmarks
        self.pinnedPosts = pinnedPosts
        self.settings = settings
        self.controlledRealms = controlledRealms
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
        bookmarks = try values.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        pinnedPosts = try values.decodeIfPresent([Int].self, forKey: .pinnedPosts) ?? []
        settings = try values.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        controlledRealms = try values.decodeIfPresent([String].self, forKey: .controlledRealms) ?? []
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
        TaggrUser(
            id: id,
            name: name,
            about: about,
            principal: principal,
            realms: realms,
            followees: followees,
            followers: followers,
            blacklist: blacklist,
            bookmarks: bookmarks,
            pinnedPosts: pinnedPosts,
            settings: settings,
            controlledRealms: controlledRealms,
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
    }

    func updatingSettings(_ settings: [String: String]) -> TaggrUser {
        TaggrUser(
            id: id,
            name: name,
            about: about,
            principal: principal,
            realms: realms,
            followees: followees,
            followers: followers,
            blacklist: blacklist,
            bookmarks: bookmarks,
            pinnedPosts: pinnedPosts,
            settings: settings,
            controlledRealms: controlledRealms,
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
    }

}

struct TaggrStats: Codable, Equatable, Sendable {
    let users: Int?
    let posts: Int?
    let comments: Int?
    let realms: Int?
    let canisterId: String?
    let e8sForOneXdr: UInt64?

    enum CodingKeys: String, CodingKey {
        case users
        case posts
        case comments
        case realms
        case canisterId
        case e8sForOneXdr
    }
}

struct TaggrStorageCanisterStatus: Equatable {
    let status: String
    let controllers: [String]
    let moduleHash: Data?
    let memorySize: UInt64
    let cycles: UInt64
    let idleCyclesBurnedPerDay: UInt64

    var daysToLive: UInt64? {
        guard idleCyclesBurnedPerDay > 0 else { return nil }
        return cycles / idleCyclesBurnedPerDay
    }
}

struct TaggrConfig: Codable, Equatable, Sendable {
    let name: String?
    let tokenSymbol: String?
    let tokenDecimals: Int?
    let maxPostLength: Int?
    let maxTagLength: Int?
    let maxBlobSizeBytes: Int?
    let maxReportLength: Int?
    let maxRealmCleanupPenalty: Int?
    let maxRealmLogoLen: Int?
    let reactions: [[Int]]?
    let feedPageSize: Int?
    let pollRevoteDeadlineHours: Int?
    let postCost: Int?
    let pollCost: Int?
    let postDeletionPenaltyFactor: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case tokenSymbol
        case tokenDecimals
        case maxPostLength
        case maxTagLength
        case maxBlobSizeBytes
        case maxReportLength
        case maxRealmCleanupPenalty
        case maxRealmLogoLen
        case reactions
        case feedPageSize
        case pollRevoteDeadlineHours
        case postCost
        case pollCost
        case postDeletionPenaltyFactor
    }
}

enum TaggrTokenAmount {
    static func format(_ rawAmount: Int, decimals: Int?) -> String {
        let decimals = max(decimals ?? 0, 0)
        guard decimals > 0 else { return rawAmount.formatted() }

        let magnitude = magnitude(of: rawAmount)
        let base = tokenBase(decimals: decimals)
        let whole = magnitude / base
        let fractional = magnitude % base
        let sign = rawAmount < 0 ? "-" : ""

        guard fractional > 0 else { return "\(sign)\(whole.formatted())" }

        var fraction = String(fractional)
        while fraction.count < decimals {
            fraction = "0\(fraction)"
        }
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return "\(sign)\(whole.formatted()).\(fraction)"
    }

    private static func magnitude(of value: Int) -> UInt64 {
        value < 0 ? UInt64(-(value + 1)) + 1 : UInt64(value)
    }

    private static func tokenBase(decimals: Int) -> UInt64 {
        (0..<decimals).reduce(UInt64(1)) { base, _ in
            base * 10
        }
    }
}

struct LosslessInt: Codable, Equatable, Comparable, Sendable {
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
