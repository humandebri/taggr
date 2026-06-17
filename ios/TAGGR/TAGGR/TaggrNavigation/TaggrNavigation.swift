import Foundation

enum TaggrRoute: Equatable {
    case feed(TaggrFeedMode)
    case post(Int)
    case profile(String)
    case realm(String)
    case settings
    case readOnlyNotice
}

enum TaggrNavigation {
    static var canonicalHost: String { TaggrRuntimeConfig.current.domain }
    private static var supportedHosts: Set<String> {
        Set([TaggrRuntimeConfig.productionDomain, canonicalHost])
    }

    static func route(from url: URL) -> TaggrRoute? {
        if url.scheme == "taggr" {
            var parts = pathParts(url)
            if let host = url.host {
                parts.insert(host, at: 0)
            }
            return route(fromParts: parts)
        }
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

    static func path(for route: TaggrRoute) -> String {
        switch route {
        case .feed(.hot):
            return "/"
        case .feed(.latest):
            return "/feed/latest"
        case .feed(.personal):
            return "/feed/personal"
        case .feed(.realm(let name)):
            return "/realm/\(name)"
        case .post(let id):
            return "/post/\(id)"
        case .profile(let handle):
            return "/user/\(handle)"
        case .realm(let name):
            return "/realm/\(name)"
        case .settings:
            return "/settings"
        case .readOnlyNotice:
            return "/tokens"
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
            return parts.dropFirst().first.map(TaggrRoute.profile)
        case "realm":
            return parts.dropFirst().first.map(TaggrRoute.realm)
        case "transaction", "transactions", "tokens", "wallet", "auction":
            return .readOnlyNotice
        case "settings":
            return .settings
        case "feed":
            if parts.dropFirst().first == "latest" { return .feed(.latest) }
            if parts.dropFirst().first == "personal" { return .feed(.personal) }
            return .feed(.hot)
        default:
            return nil
        }
    }
}
