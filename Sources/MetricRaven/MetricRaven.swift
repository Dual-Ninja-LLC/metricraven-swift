import Foundation
#if canImport(UIKit)
import UIKit
#endif

/**
 The shared client for an app, set up once at launch:

 ```swift
 MetricRaven.configure(siteId: "ana_pub_…", appId: "com.example.app")
 MetricRaven.screen("Home")
 MetricRaven.track("signup", props: ["plan": "pro"])
 MetricRaven.identify("user_42", traits: ["name": "Ana", "email": "ana@example.com"])
 ```

 Calls before `configure` (or after a failed one) do nothing.
 */
public enum MetricRaven {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var client: MetricRavenClient?
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    /// The configured client, for anything the shortcuts below don't cover.
    public static var shared: MetricRavenClient? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    /**
     Starts tracking. App version, build, OS version, platform and device type are read from the
     bundle and device. Returns false when the app ID isn't a bundle ID like com.example.app.
     */
    @discardableResult
    public static func configure(
        siteId: String,
        appId: String? = nil,
        consent: Bool = false,
        apiHost: URL = URL(string: "https://metricraven.com")!,
        endpoint: URL? = nil,
        disabled: Bool = false,
        debug: Bool = false
    ) -> Bool {
        let bundle = Bundle.main
        let configuration = MetricRavenConfiguration(
            siteId: siteId,
            appId: appId ?? bundle.bundleIdentifier ?? "",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            platform: DeviceInfo.platform,
            osVersion: DeviceInfo.osVersion,
            deviceType: DeviceInfo.deviceType,
            apiHost: apiHost,
            endpoint: endpoint,
            consent: consent,
            disabled: disabled,
            debug: debug
        )
        guard let created = try? MetricRavenClient(configuration: configuration) else {
            if debug { print("[metricraven] configure failed: \(configuration.appId) is not a bundle ID") }
            return false
        }
        lock.lock()
        client?.shutdown()
        client = created
        lock.unlock()
        observeForeground()
        return true
    }

    public static func screen(_ name: String, props: MetricRavenProps? = nil) { shared?.screen(name, props: props) }
    public static func track(_ name: String, props: MetricRavenProps? = nil) { shared?.track(name, props: props) }
    public static func identify(_ userId: String, traits: MetricRavenProps? = nil) { shared?.identify(userId, traits: traits) }
    public static func identify(token: String) { shared?.identify(token: token) }
    public static func reset() { shared?.reset() }
    public static func setConsent(_ granted: Bool) { shared?.setConsent(granted) }
    public static func openedFrom(url: URL?) { shared?.openedFrom(url: url) }
    public static func flush() async { await shared?.flush() }

    private static func observeForeground() {
        #if canImport(UIKit) && !os(watchOS)
        lock.lock(); defer { lock.unlock() }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Back in the foreground: deliver what queued while offline. Going to the background: send
        // what is pending before the app can be suspended.
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await MetricRaven.flush() }
            })
        }
        #endif
    }
}

enum DeviceInfo {
    static var platform: AppPlatform {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return .ios
        #elseif os(macOS)
        return .macos
        #else
        return .other
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var deviceType: DeviceType {
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac { return .desktop }
        // UIDevice is main-actor isolated; the idiom never changes, so reading it off the main thread
        // through the trait-free screen size is avoided: iPad screens are at least 744 points wide.
        let bounds = MainActor.assumeIsolatedIfMain { UIScreen.main.bounds }
        if let bounds, min(bounds.width, bounds.height) >= 744 { return .tablet }
        return .mobile
        #elseif os(macOS)
        return .desktop
        #else
        return .mobile
        #endif
    }
}

#if os(iOS)
extension MainActor {
    /// Runs `body` on the main actor when already on the main thread; nil otherwise.
    static func assumeIsolatedIfMain<T: Sendable>(_ body: @MainActor () -> T) -> T? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated(body)
    }
}
#endif
