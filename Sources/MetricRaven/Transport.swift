import Foundation

/// The HTTP answer the client needs from one collect request.
public struct TransportResponse: Sendable {
    public var status: Int
    /// Seconds from a Retry-After header, when the server sent one.
    public var retryAfter: Double?
    public var body: Data
    public init(status: Int, retryAfter: Double? = nil, body: Data = Data()) {
        self.status = status
        self.retryAfter = retryAfter
        self.body = body
    }
}

/// Sends one JSON body to the collect endpoint. Throws when the network is unreachable.
public protocol MetricRavenTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws -> TransportResponse
}

/// URLSession, with a 15 second timeout.
public struct URLSessionTransport: MetricRavenTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(_ body: Data, to url: URL) async throws -> TransportResponse {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
        return TransportResponse(status: http?.statusCode ?? 0, retryAfter: retryAfter, body: data)
    }
}

/// Persists the offline queue and, with consent, the visitor ID.
public protocol MetricRavenStorage: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// UserDefaults (standard, or an app group suite). The queue is small: at most `maxQueueSize` events.
public final class UserDefaultsStorage: MetricRavenStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Keeps everything in memory: the queue is lost when the app is killed. Used by tests.
public final class MemoryStorage: MetricRavenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String?, forKey key: String) { lock.lock(); values[key] = value; lock.unlock() }
}
