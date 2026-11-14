import Foundation

/// A property or trait value: strings, numbers and booleans, like the web and React Native SDKs.
public enum MetricRavenValue: Codable, Equatable, Sendable, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out as integers (5, not 5.0).
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}

public typealias MetricRavenProps = [String: MetricRavenValue]

public enum AppPlatform: String, Codable, Sendable {
    case ios, android, web, macos, windows, other
}

public enum DeviceType: String, Codable, Sendable {
    case mobile, tablet, desktop
}

/// Sent with every request instead of a page URL. The app ID must be listed in the site's settings
/// (Settings, General, Site, Mobile apps).
struct AppInfo: Codable, Equatable, Sendable {
    var id: String
    var version: String?
    var build: String?
    var platform: AppPlatform
    var osVersion: String?
    var deviceType: DeviceType?
}

struct UTM: Codable, Equatable, Sendable {
    var source: String?
    var medium: String?
    var campaign: String?
    var term: String?
    var content: String?
    var isEmpty: Bool { [source, medium, campaign, term, content].allSatisfy { $0 == nil } }
}

/// The collect payload POST /api/v1/collect accepts from a native app (backend lib/schemas.ts
/// collectSchema; the same shape as @metricraven/react-native).
struct CollectPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case pageview, event, link, identify }
    var siteId: String
    var type: Kind
    var timestamp: String
    var app: AppInfo
    var clientId: String?
    var link: Bool?
    var screen: String?
    var name: String?
    var props: MetricRavenProps?
    var userId: String?
    var traits: MetricRavenProps?
    var identityToken: String?
    var utm: UTM?
    /// Device language as a BCP 47 tag ("en-US"). Screen views only.
    var lang: String?
    /// Screen size in points, "390x844". Screen views only.
    var screenSize: String?
}

enum Validate {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static let eventName = "^[a-zA-Z][a-zA-Z0-9_:.-]{0,99}$"
    static let appId = "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$"
    static let clientId = "^[0-9a-f]{32}$"
    static let identityToken = "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$"
    static let traitKey = "^[a-z][a-z0-9_-]{0,63}$"
    static let email = "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$"
    static let imageURL = "^https://[A-Za-z0-9.-]+(?::\\d{1,5})?(?:[/?#][^\\s]*)?$"

    private static func trimmed(_ value: String?, max: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(max))
    }

    private static func withoutControls(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
    }

    /// Up to 10 props; keys up to 64 characters, strings up to 500. Invalid entries are dropped.
    static func props(_ props: MetricRavenProps?) -> MetricRavenProps? {
        guard let props else { return nil }
        var out: MetricRavenProps = [:]
        for key in props.keys.sorted() {
            guard out.count < 10, !key.isEmpty, key.count <= 64, let value = props[key] else { continue }
            switch value {
            case .string(let s): out[key] = .string(String(s.prefix(500)))
            case .number(let n): if n.isFinite { out[key] = value }
            case .bool: out[key] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    /// name, email, image (https profile picture) and up to 10 custom traits with lowercase keys.
    static func traits(_ traits: MetricRavenProps?) -> MetricRavenProps {
        guard let traits else { return [:] }
        var out: MetricRavenProps = [:]
        var custom = 0
        for key in traits.keys.sorted() {
            guard let value = traits[key] else { continue }
            switch key {
            case "name", "email":
                if case .string(let s) = value, let v = trimmed(s, max: key == "name" ? 200 : 320),
                   key == "name" || matches(v, email) { out[key] = .string(v) }
            case "image":
                if case .string(let s) = value, let url = imageURLValue(s) { out[key] = .string(url) }
            default:
                guard custom < 10, matches(key, traitKey) else { continue }
                switch value {
                case .string(let s): out[key] = .string(String(s.prefix(255)))
                case .number(let n): guard n.isFinite else { continue }; out[key] = value
                case .bool: out[key] = value
                }
                custom += 1
            }
        }
        return out
    }

    static func imageURLValue(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 500, matches(raw, imageURL), withoutControls(raw) == raw else { return nil }
        return raw
    }

    static func userId(_ value: String) -> String? {
        trimmed(value, max: 200).flatMap { $0.count <= 200 ? $0 : nil }
    }

    /// Screen names and routes as sent; the server turns "Settings" into the path "/Settings".
    static func screen(_ value: String) -> String? {
        let clean = withoutControls(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(300))
    }

    static func short(_ value: String?) -> String? { trimmed(value, max: 50) }

    static let languageTag = "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"
    static let screenSizePattern = "^\\d{2,5}x\\d{2,5}$"

    /// A language tag such as "en-US" (at most 35 characters); "en_US" becomes "en-US".
    static func language(_ value: String?) -> String? {
        guard let tag = trimmed(value, max: 100)?.replacingOccurrences(of: "_", with: "-"),
              tag.count <= 35, matches(tag, languageTag) else { return nil }
        return tag
    }

    /// "WxH", e.g. "390x844"; anything else is dropped.
    static func screenSize(_ value: String?) -> String? {
        guard let value = trimmed(value, max: 20), matches(value, screenSizePattern) else { return nil }
        return value
    }

    /// "WxH" from a size in points, rounded.
    static func screenSize(width: Double, height: Double) -> String? {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width < 100_000, height < 100_000 else { return nil }
        return screenSize("\(Int(width.rounded()))x\(Int(height.rounded()))")
    }

    /// Campaign parameters from a deep link (utm_source…); nothing else from the URL is kept.
    static func utm(from url: URL?) -> UTM? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var utm = UTM()
        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            let v = String(value.prefix(200))
            switch item.name {
            case "utm_source": utm.source = v
            case "utm_medium": utm.medium = v
            case "utm_campaign": utm.campaign = v
            case "utm_term": utm.term = v
            case "utm_content": utm.content = v
            default: break
            }
        }
        return utm.isEmpty ? nil : utm
    }
}
