import Foundation

enum TaggrRoute: Hashable, Sendable {
    case feed(TaggrFeedMode)
    case post(Int)
    case profile(String)
    case userPhotos(String)
    case realm(String)
    case inbox
    case settings
}

enum TaggrNavigation {
    static var canonicalHost: String { TaggrRuntimeConfig.current.domain }
    private static var supportedHosts: Set<String> {
        Set([TaggrRuntimeConfig.productionDomain, canonicalHost])
    }

    static func route(from url: URL) -> TaggrRoute? {
        guard let scheme = url.scheme, let host = url.host, supports(scheme: scheme, host: host) else {
            return nil
        }
        if let fragment = url.fragment, fragment.hasPrefix("/") {
            return route(fromParts: fragment.split(separator: "/").map(String.init))
        }
        return route(fromParts: pathParts(url))
    }

    static func universalURL(for route: TaggrRoute) -> URL {
        let scheme = canonicalHost == TaggrRuntimeConfig.productionDomain ? "https" : "http"
        return URL(string: "\(scheme)://\(canonicalHost)\(path(for: route))")!
    }

    static func journalURL(userID: Int) -> URL {
        var components = URLComponents(url: universalURL(for: .profile(String(userID))), resolvingAgainstBaseURL: false)!
        components.path = "/journal/\(userID)"
        return components.url!
    }

    static func path(for route: TaggrRoute) -> String {
        switch route {
        case .feed(.hot):
            return "/"
        case .feed(.latest):
            return "/feed/latest"
        case .feed(.personal):
            return "/feed/personal"
        case .feed(.realm(let name)):
            return "/realm/\(pathComponent(name))"
        case .feed(.tags(let tokens)):
            return "/feed/\(tokens.map(pathComponent).joined(separator: "+"))"
        case .post(let id):
            return "/post/\(id)"
        case .profile(let handle):
            return "/user/\(handle)"
        case .userPhotos(let handle):
            return "/user/\(handle)/photos"
        case .realm(let name):
            return "/realm/\(name)"
        case .inbox:
            return "/inbox"
        case .settings:
            return "/settings"
        }
    }

    private static func pathParts(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    private static func supports(scheme: String, host: String) -> Bool {
        if scheme == "https" && supportedHosts.contains(host) {
            return true
        }
        return scheme == "http" && (supportedHosts.contains(host) || host == "localhost" || host.hasSuffix(".localhost"))
    }

    private static func route(fromParts parts: [String]) -> TaggrRoute? {
        guard let first = parts.first else {
            return .feed(.hot)
        }
        switch first {
        case "post", "thread":
            return parts.dropFirst().first.flatMap(Int.init).map(TaggrRoute.post)
        case "user", "journal":
            guard let handle = parts.dropFirst().first else { return nil }
            if parts.dropFirst(2).first == "photos" {
                return .userPhotos(handle)
            }
            return .profile(handle)
        case "realm":
            return parts.dropFirst().first.map(TaggrRoute.realm)
        case "transaction", "transactions", "tokens", "wallet", "auction":
            return .settings
        case "inbox":
            return .inbox
        case "settings":
            return .settings
        case "feed":
            guard let feed = parts.dropFirst().first else { return .feed(.hot) }
            if feed == "latest" { return .feed(.latest) }
            if feed == "personal" { return .feed(.personal) }
            let tokens = feed
                .split(separator: "+")
                .compactMap { String($0).removingPercentEncoding }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return nil }
            return .feed(.tags(tokens))
        default:
            return nil
        }
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
