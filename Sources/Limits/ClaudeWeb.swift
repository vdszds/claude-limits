import Foundation
import WebKit

enum ClaudeWebError: Error {
    case signedOut
    case browserCheck
    case rateLimited
    case http(Int)
    case badResponse
    case noOrganization
}

struct Organization {
    var id: String
    var name: String
    var capabilities: [String]
    var rateLimitTier: String?

    init?(_ json: [String: Any]) {
        guard let id = json["uuid"] as? String else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        capabilities = json["capabilities"] as? [String] ?? []
        rateLimitTier = json["rate_limit_tier"] as? String
    }

    var plan: String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        // Max 20x was renamed Ultra; existing accounts may still carry the max_20x tier.
        if tier.contains("ultra") || tier.contains("max_20x") { return "Ultra" }
        if tier.contains("max_5x") { return "Max 5x" }
        if capabilities.contains("claude_max") || tier.contains("max") { return "Max" }
        if capabilities.contains("claude_pro") || tier.contains("pro") { return "Pro" }
        if capabilities.contains(where: { $0.contains("enterprise") }) { return "Enterprise" }
        if capabilities.contains(where: { $0.contains("team") }) { return "Team" }
        return nil
    }

    /// Personal organizations are named "<email>'s Organization".
    var email: String? {
        let suffix = "'s Organization"
        guard name.hasSuffix(suffix) else { return nil }
        let candidate = String(name.dropLast(suffix.count))
        return candidate.contains("@") ? candidate : nil
    }

    var displayName: String { email ?? name }
}

/// Talks to claude.ai with an account's own browser session, the same way the Settings → Usage page does.
@MainActor
enum ClaudeWeb {
    static let site = URL(string: "https://claude.ai")!
    static let loginPage = URL(string: "https://claude.ai/login")!
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!

    /// Cloudflare ties its clearance cookie to the user agent, so the web view and the API calls share one.
    static let userAgent: String = {
        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let full = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        let version = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func dataStore(_ id: UUID) -> WKWebsiteDataStore {
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
    }

    static func removeDataStore(_ id: UUID) async {
        stores[id] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    static func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies().filter { isClaude($0.domain) }
    }

    static func clearSession(in store: WKWebsiteDataStore) async {
        for cookie in await cookies(in: store) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    static func organizations(store: WKWebsiteDataStore) async throws -> [Organization] {
        guard let list = try await get("api/organizations", store: store) as? [[String: Any]] else {
            throw ClaudeWebError.badResponse
        }
        return list.compactMap(Organization.init)
    }

    /// Prefers the organization the account last used on claude.ai, as long as it carries a plan.
    static func primaryOrganization(store: WKWebsiteDataStore) async throws -> Organization {
        let organizations = try await organizations(store: store)
        let lastActive = await cookies(in: store).first { $0.name == "lastActiveOrg" }?.value
        let chat = organizations.filter { $0.capabilities.contains("chat") }
        let pool = chat.isEmpty ? organizations : chat
        let paid = pool.filter { $0.plan != nil }
        let pick = paid.first { $0.id == lastActive } ?? paid.first ?? pool.first { $0.id == lastActive } ?? pool.first
        guard let pick else { throw ClaudeWebError.noOrganization }
        return pick
    }

    static func usage(orgID: String, store: WKWebsiteDataStore) async throws -> [UsageLimit] {
        let limits = UsageParser.parse(try await get("api/organizations/\(orgID)/usage", store: store))
        guard !limits.isEmpty else { throw ClaudeWebError.badResponse }
        return limits
    }

    private static func get(_ path: String, store: WKWebsiteDataStore) async throws -> Any {
        let url = site.appending(path: path)
        let jar = await cookies(in: store)
        guard jar.contains(where: { $0.name == "sessionKey" }) else { throw ClaudeWebError.signedOut }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(usagePage.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(site.absoluteString, forHTTPHeaderField: "Origin")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeWebError.badResponse }
        await keepCookies(from: http, url: url, store: store)

        if isChallenge(http, data) { throw ClaudeWebError.browserCheck }
        switch http.statusCode {
        case 200..<300:
            guard let json = try? JSONSerialization.jsonObject(with: data) else { throw ClaudeWebError.badResponse }
            return json
        case 401, 403: throw ClaudeWebError.signedOut
        case 429: throw ClaudeWebError.rateLimited
        default: throw ClaudeWebError.http(http.statusCode)
        }
    }

    private static func isClaude(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    private static func isChallenge(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        guard response.statusCode == 403 || response.statusCode == 503 else { return false }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.contains("Just a moment") || head.contains("challenge-platform")
    }

    /// Writes refreshed cookies back so the account's session stays current between sign-ins.
    private static func keepCookies(from response: HTTPURLResponse, url: URL, store: WKWebsiteDataStore) async {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            await store.httpCookieStore.setCookie(cookie)
        }
    }
}

enum UsageParser {
    private static let iso = ISO8601DateFormatter()

    static func parse(_ json: Any) -> [UsageLimit] {
        guard let root = json as? [String: Any] else { return [] }
        var session = window(root["five_hour"], id: "session", title: "Session", kind: .session)
        var week = window(root["seven_day"], id: "week", title: "Week", kind: .week)
        var models: [UsageLimit] = []

        // Newer responses list per-model weekly limits in "limits" and may null the older seven_day_* fields.
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let percent = number(entry["percent"] ?? entry["utilization"]) else { continue }
            let kind = (entry["kind"] as? String ?? "").lowercased()
            let resetsAt = date(entry["resets_at"])
            if let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any] {
                let name = model["display_name"] as? String ?? model["id"] as? String ?? "Model"
                models.append(UsageLimit(id: "model-\(name)", title: "Week · \(name)", kind: .model, percent: percent, resetsAt: resetsAt))
            } else if session == nil, kind.contains("session") || kind.contains("five_hour") {
                session = UsageLimit(id: "session", title: "Session", kind: .session, percent: percent, resetsAt: resetsAt)
            } else if week == nil, kind.contains("week") || kind.contains("seven_day") {
                week = UsageLimit(id: "week", title: "Week", kind: .week, percent: percent, resetsAt: resetsAt)
            }
        }

        if models.isEmpty {
            for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet"), ("seven_day_fable", "Fable"), ("seven_day_omelette", "Design")] {
                if let limit = window(root[key], id: "model-\(name)", title: "Week · \(name)", kind: .model) {
                    models.append(limit)
                }
            }
        }

        // A per-model limit nobody has touched this week is noise.
        models.removeAll { $0.percent == 0 && $0.resetsAt == nil }
        return [session, week].compactMap { $0 } + models
    }

    private static func window(_ value: Any?, id: String, title: String, kind: UsageLimit.Kind) -> UsageLimit? {
        guard let object = value as? [String: Any], let percent = number(object["utilization"]) else { return nil }
        return UsageLimit(id: id, title: title, kind: kind, percent: percent, resetsAt: date(object["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let text = value as? String else { return nil }
        // The API sends microseconds, which ISO8601DateFormatter rejects, so drop the fraction.
        return iso.date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
}
