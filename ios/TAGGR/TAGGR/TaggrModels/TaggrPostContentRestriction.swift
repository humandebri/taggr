enum TaggrPostContentRestriction: Equatable, Sendable {
    case encrypted
    case moderated
    case deleted([String])
    case hidden
    case nsfw

    var isRevealable: Bool {
        switch self {
        case .hidden, .nsfw:
            return true
        case .encrypted, .moderated, .deleted:
            return false
        }
    }
}
