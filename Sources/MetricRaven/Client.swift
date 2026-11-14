import Foundation

/// How the client talks to MetricRaven. Only `siteId` and `appId` are required.
public struct MetricRavenConfiguration: Sendable {
    /// Your site ID (ana_pub_…).
    public var siteId: String
    /// Bundle ID, e.g. com.example.app. Add it under Settings, General, Site, Mobile apps.
    public var appId: String
    public var appVersion: String?
    public var appBuild: String?
    public var platform: AppPlatform
    public var osVersion: String?
    public var deviceType: DeviceType?
    /// Device language, e.g. "en-US". Sent with screen views only. `MetricRaven.configure` reads it from the device.
    public var language: String?
    /// Screen size in points, "390x844". Sent with screen views only. `MetricRaven.configure` reads it from the device.
    public var screenSize: String?
    /// Default https://metricraven.com.
    public var apiHost: URL
    /// Full collect URL, overriding apiHost (e.g. your own proxy).
    public var endpoint: URL?
    /// Analytics storage consent already granted. Default false: nothing is stored on the device and
    /// the server derives a daily visitor ID. With consent a random ID is kept in `storage`.
    public var consent: Bool
    public var storage: MetricRavenStorage
    public var transport: MetricRavenTransport
    /// Events kept while offline; the oldest are dropped beyond this. Default 500.
    public var maxQueueSize: Int
    /// Queued events older than this are dropped. Default 7 days.
    public var maxEventAge: TimeInterval
    /// Turns tracking off entirely (e.g. in development).
    public var disabled: Bool
    public var debug: Bool
    /// For tests.
    public var now: @Sendable () -> Date
    public var randomId: @Sendable () -> String

    public init(
        siteId: String,
        appId: String,
        appVersion: String? = nil,
        appBuild: String? = nil,
        platform: AppPlatform = .other,
        osVersion: String? = nil,
        deviceType: DeviceType? = nil,
        language: String? = nil,
        screenSize: String? = nil,
        apiHost: URL = URL(string: "https://metricraven.com")!,
        endpoint: URL? = nil,
        consent: Bool = false,
        storage: MetricRavenStorage = UserDefaultsStorage(),
        transport: MetricRavenTransport = URLSessionTransport(),
        maxQueueSize: Int = 500,
        maxEventAge: TimeInterval = 7 * 86_400,
        disabled: Bool = false,
        debug: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        randomId: @escaping @Sendable () -> String = { MetricRavenClient.randomClientId() }
    ) {
        self.siteId = siteId
        self.appId = appId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.platform = platform
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.language = language
        self.screenSize = screenSize
        self.apiHost = apiHost
        self.endpoint = endpoint
        self.consent = consent
        self.storage = storage
        self.transport = transport
        self.maxQueueSize = maxQueueSize
        self.maxEventAge = maxEventAge
        self.disabled = disabled
        self.debug = debug
        self.now = now
        self.randomId = randomId
    }
}

public enum MetricRavenError: Error, Equatable {
    case missingSiteId
    case invalidAppId(String)
}

/**
 MetricRaven for native apps: screen views, events, identify, consent and an offline queue. Calls
 return at once and run in order; events are delivered in order, retried with backoff while offline
 or rate limited, and kept across launches.
 */
public final class MetricRavenClient: Sendable {
    private let engine: Engine
    private let ops: AsyncStream<Op>.Continuation

    public init(configuration: MetricRavenConfiguration) throws {
        guard !configuration.siteId.isEmpty else { throw MetricRavenError.missingSiteId }
        guard Validate.matches(configuration.appId, Validate.appId) else {
            throw MetricRavenError.invalidAppId(configuration.appId)
        }
        let engine = Engine(configuration)
        self.engine = engine
        let (stream, continuation) = AsyncStream<Op>.makeStream()
        ops = continuation
        Task { await engine.load(); for await op in stream { await engine.handle(op) } }
    }

    deinit { ops.finish() }

    /// A screen view (a pageview whose path is the screen name or route).
    public func screen(_ name: String, props: MetricRavenProps? = nil) { ops.yield(.screen(name, props)) }

    /// A custom event (goal). Names: letters, digits, _ : . - ; up to 100 characters.
    public func track(_ name: String, props: MetricRavenProps? = nil) { ops.yield(.track(name, props)) }

    /// Links this device's visitor to your user ID. Unsigned it is self-asserted, and a server
    /// identify (secret key) takes precedence. Use the same user ID as your server events.
    public func identify(_ userId: String, traits: MetricRavenProps? = nil) {
        ops.yield(.identify(userId: userId, traits: traits, token: nil))
    }

    /// Signed identify: a token your server made with a site secret key (signIdentity in
    /// @metricraven/node). Verified; the user ID and traits come from the token.
    public func identify(token: String, userId: String? = nil) {
        ops.yield(.identify(userId: userId, traits: nil, token: token))
    }

    /// On logout: forgets identify state and, with consent, starts a new visitor ID.
    public func reset() { ops.yield(.reset) }

    public func setConsent(_ granted: Bool) { ops.yield(.consent(granted)) }

    /// Campaign parameters (utm_*) from a deep link, attached to the next screen view.
    public func openedFrom(url: URL?) { ops.yield(.openedFrom(url)) }

    /// The visitor ID events are recorded under (the consented ID, or the server's daily ID).
    public var visitorId: String? { get async { await engine.currentId } }

    /// Events waiting to be delivered.
    public var pending: Int { get async { await engine.queueCount } }

    /// Sends everything queued now (e.g. when the app returns to the foreground).
    public func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in ops.yield(.flush(done)) }
    }

    /// Stops delivery; queued events stay in storage for the next launch.
    public func shutdown() { ops.yield(.shutdown) }

    public static func randomClientId() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// Retry later on network errors, timeouts, rate limits and server errors; drop other rejections.
    static func shouldRetry(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status == 408 || status == 429 || status >= 500
    }

    static func backoff(attempts: Int, retryAfter: Double?) -> TimeInterval {
        let cap: TimeInterval = 300
        if let retryAfter, retryAfter > 0 { return min(cap, retryAfter) }
        return min(cap, pow(2, Double(max(0, attempts - 1))))
    }
}

enum Op: Sendable {
    case screen(String, MetricRavenProps?)
    case track(String, MetricRavenProps?)
    case identify(userId: String?, traits: MetricRavenProps?, token: String?)
    case reset
    case consent(Bool)
    case openedFrom(URL?)
    case flush(CheckedContinuation<Void, Never>)
    case shutdown
}

struct Queued: Codable, Sendable {
    var payload: CollectPayload
    var attempts: Int
    var queuedAt: Date
}

actor Engine {
    private let config: MetricRavenConfiguration
    private let app: AppInfo
    private let language: String?
    private let screenSize: String?
    private let endpoint: URL
    private let queueKey: String
    private let idKey: String
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private var queue: [Queued] = []
    private var clientId: String?
    private var serverVisitorId: String?
    private var consentVersion = 0
    private var currentScreen: String?
    private var pendingUtm: UTM?
    private var lastIdentify: String?
    private var pendingLink = false
    private var flushing: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var notBefore = Date.distantPast
    private var stopped: Bool

    init(_ config: MetricRavenConfiguration) {
        self.config = config
        app = AppInfo(
            id: config.appId,
            version: Validate.short(config.appVersion),
            build: Validate.short(config.appBuild),
            platform: config.platform,
            osVersion: Validate.short(config.osVersion),
            deviceType: config.deviceType
        )
        language = Validate.language(config.language)
        screenSize = Validate.screenSize(config.screenSize)
        endpoint = config.endpoint ?? config.apiHost.appendingPathComponent("api/v1/collect")
        queueKey = "metricraven:queue:\(config.siteId)"
        idKey = "metricraven:client-id:\(config.siteId)"
        stopped = config.disabled
    }

    var currentId: String? { clientId ?? serverVisitorId }
    var queueCount: Int { queue.count }

    private func log(_ message: @autoclosure () -> String) {
        if config.debug { print("[metricraven] \(message())") }
    }

    func load() {
        guard !stopped else { return }
        if let raw = config.storage.string(forKey: queueKey), let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([Queued].self, from: data) {
            queue = stored + queue
        }
        if config.consent {
            if let stored = config.storage.string(forKey: idKey), Validate.matches(stored, Validate.clientId) {
                clientId = stored
            }
            grant(silent: true)
        } else {
            stripConsentedIds()
        }
        if !queue.isEmpty { startFlush() }
    }

    func handle(_ op: Op) async {
        switch op {
        case .screen(let name, let props):
            guard !stopped, let screen = Validate.screen(name) else { return }
            currentScreen = screen
            let utm = pendingUtm
            pendingUtm = nil
            enqueue(.pageview, screen: screen, props: Validate.props(props), utm: utm)
        case .track(let name, let props):
            guard !stopped else { return }
            guard Validate.matches(name, Validate.eventName) else { return log("ignored event name \"\(name)\"") }
            enqueue(.event, screen: currentScreen, name: name, props: Validate.props(props))
        case .identify(let rawUserId, let traits, let rawToken):
            guard !stopped else { return }
            let token = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawToken != nil {
                guard let token, !token.isEmpty, token.count <= 4096, Validate.matches(token, Validate.identityToken) else {
                    return log("identify: ignoring a malformed identity token")
                }
            }
            let userId = rawUserId.flatMap(Validate.userId)
            guard userId != nil || token != nil else { return }
            // With a token the server reads the profile from it only, so unsigned traits aren't sent.
            let cleanTraits = token == nil ? Validate.traits(traits) : nil
            let key = "\(currentId ?? "")\n\(userId ?? "")\n\(token ?? "")\n\(fingerprint(cleanTraits))"
            guard key != lastIdentify else { return }
            lastIdentify = key
            enqueue(.identify, userId: userId, traits: cleanTraits, identityToken: token)
        case .reset:
            lastIdentify = nil
            guard clientId != nil else { return } // nothing is stored without consent
            consentVersion += 1
            clientId = config.randomId()
            serverVisitorId = nil
            config.storage.set(clientId, forKey: idKey)
        case .consent(let granted):
            guard !stopped else { return }
            if granted { return grant(silent: false) }
            consentVersion += 1
            clientId = nil
            serverVisitorId = nil
            pendingLink = false
            // Withdrawn consent: queued events no longer carry the stored ID.
            stripConsentedIds()
            config.storage.set(nil, forKey: idKey)
        case .openedFrom(let url):
            if let utm = Validate.utm(from: url) { pendingUtm = utm }
        case .flush(let done):
            await forceFlush()
            done.resume()
        case .shutdown:
            stopped = true
            retry?.cancel()
            retry = nil
        }
    }

    private func fingerprint(_ traits: MetricRavenProps?) -> String {
        guard let traits, let data = try? encoder.encode(traits) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func grant(silent: Bool) {
        if clientId != nil && !silent { return }
        consentVersion += 1
        if clientId == nil { clientId = config.randomId() }
        config.storage.set(clientId, forKey: idKey)
        // Relabel today's daily-ID events from this device to the consented ID: right away, or with the
        // next event when consent was already granted at launch.
        pendingLink = true
        if !silent { enqueue(.link) }
    }

    /// Without consent, nothing queued may carry the stored ID.
    private func stripConsentedIds() {
        let before = queue.count
        var changed = false
        for index in queue.indices where queue[index].payload.clientId != nil || queue[index].payload.link != nil {
            queue[index].payload.clientId = nil
            queue[index].payload.link = nil
            changed = true
        }
        queue.removeAll { $0.payload.type == .link }
        if changed || queue.count != before { persist() }
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: config.now())
    }

    private func enqueue(
        _ type: CollectPayload.Kind,
        screen: String? = nil,
        name: String? = nil,
        props: MetricRavenProps? = nil,
        utm: UTM? = nil,
        userId: String? = nil,
        traits: MetricRavenProps? = nil,
        identityToken: String? = nil
    ) {
        var payload = CollectPayload(
            siteId: config.siteId, type: type, timestamp: timestamp(), app: app,
            screen: screen, name: name, props: props, userId: userId, traits: traits,
            identityToken: identityToken, utm: utm
        )
        if type == .pageview {
            payload.lang = language
            payload.screenSize = screenSize
        }
        if let clientId {
            payload.clientId = clientId
            if pendingLink {
                payload.link = true
                pendingLink = false
            }
        }
        queue.append(Queued(payload: payload, attempts: 0, queuedAt: config.now()))
        let limit = max(1, config.maxQueueSize)
        if queue.count > limit { queue.removeFirst(queue.count - limit) }
        persist()
        startFlush()
    }

    private func persist() {
        if queue.isEmpty { return config.storage.set(nil, forKey: queueKey) }
        if let data = try? encoder.encode(queue) { config.storage.set(String(decoding: data, as: UTF8.self), forKey: queueKey) }
    }

    /// Delivers in the background. New events wait for a pending backoff.
    private func startFlush() {
        guard flushing == nil, retry == nil, !stopped, !queue.isEmpty else { return }
        flushing = Task { await self.drain() }
    }

    /// The public flush (e.g. on returning to the foreground): waits for a delivery in progress, skips
    /// a pending backoff but never a server's Retry-After, then sends what is left.
    private func forceFlush() async {
        if let running = flushing { await running.value }
        if retry != nil {
            guard config.now() >= notBefore else { return }
            retry?.cancel()
            retry = nil
        }
        guard !stopped, !queue.isEmpty, flushing == nil else { return }
        let task = Task { await self.drain() }
        flushing = task
        await task.value
    }

    /// Sends the queue in order until it is empty, or schedules a retry and stops.
    private func drain() async {
        defer { flushing = nil }
        while !stopped, let item = queue.first {
            if config.now().timeIntervalSince(item.queuedAt) > config.maxEventAge {
                queue.removeFirst()
                persist()
                continue
            }
            switch await deliver(item) {
            case .done:
                // The head may have been trimmed while the request was in flight.
                if let head = queue.first, head.queuedAt == item.queuedAt, head.payload == item.payload { queue.removeFirst() }
                persist()
            case .retry(let delay):
                if let head = queue.first, head.payload == item.payload { queue[0].attempts += 1 }
                persist()
                retry = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.retryFired()
                }
                return
            }
        }
    }

    private func retryFired() {
        retry = nil
        startFlush()
    }

    private enum Delivery { case done, retry(TimeInterval) }

    private func deliver(_ item: Queued) async -> Delivery {
        guard let body = try? encoder.encode(item.payload) else { return .done }
        let version = consentVersion
        var status: Int?
        var retryAfter: Double?
        do {
            let response = try await config.transport.post(body, to: endpoint)
            status = response.status
            if (200..<300).contains(response.status) {
                if version == consentVersion,
                   let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                   let id = object["visitorId"] as? String {
                    serverVisitorId = id
                }
                return .done
            }
            retryAfter = response.retryAfter
            if let retryAfter { notBefore = config.now().addingTimeInterval(retryAfter) }
        } catch {
            log("offline or unreachable, will retry: \(error)")
        }
        guard MetricRavenClient.shouldRetry(status) else {
            log("dropped a \(item.payload.type.rawValue) (HTTP \(status ?? 0))")
            return .done
        }
        return .retry(MetricRavenClient.backoff(attempts: item.attempts + 1, retryAfter: retryAfter))
    }
}
