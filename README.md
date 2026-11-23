# MetricRaven for Swift

[![Latest tag](https://img.shields.io/github/v/tag/Dual-Ninja-LLC/metricraven-swift?label=version)](https://github.com/Dual-Ninja-LLC/metricraven-swift/tags)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDual-Ninja-LLC%2Fmetricraven-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Dual-Ninja-LLC/metricraven-swift)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDual-Ninja-LLC%2Fmetricraven-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Dual-Ninja-LLC/metricraven-swift)

The Swift package for [MetricRaven](https://metricraven.com), privacy-friendly analytics with revenue
attribution: see which traffic actually pays. It records screen views, events and signed-in users from
native iOS, iPadOS, macOS, tvOS, watchOS and visionOS apps, so app users sit next to your website
visitors, payments and subscriptions in one dashboard. No dependencies. iOS 15, macOS 12, tvOS 15,
watchOS 8, visionOS 1 and later.

## Install

In Xcode: **File → Add Package Dependencies…** and enter `https://github.com/Dual-Ninja-LLC/metricraven-swift`.
Or in `Package.swift`:

```swift
.package(url: "https://github.com/Dual-Ninja-LLC/metricraven-swift", from: "0.3.0")
// and in your target:
.product(name: "MetricRaven", package: "metricraven-swift")
```

## Usage

In your site's **Settings → General → Site**, add your bundle ID (for example `com.example.app`) under
**Mobile apps**. Events from app IDs that aren't listed are rejected.

```swift
import MetricRaven

@main
struct MyApp: App {
    init() {
        // The app ID defaults to your bundle ID; version, build and device are read automatically.
        MetricRaven.configure(siteId: "ana_pub_…")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

```swift
MetricRaven.screen("Home")
MetricRaven.track("signup", props: ["plan": "pro"])

// After sign-in: the same user ID your server events, server identify and payments use.
MetricRaven.identify("user_42", traits: ["name": "Ana", "email": "ana@example.com"])
// Or verified, with a token your server signs (signIdentity in @metricraven/node):
MetricRaven.identify(token: tokenFromYourServer)

// On sign-out.
MetricRaven.reset()
```

Open the app on a device or simulator: it shows on the realtime globe as a live visitor, under the
person you identified it as, and screens appear under Pages as paths like `/Home`.

## Features

- **Revenue per user and channel.** Identify with the same user ID you use for RevenueCat, Superwall,
  Adapty, Stripe or your server, and purchases and renewals are credited to where that user came from.
- **Paywall events.** Views, closes, cancels and taps from RevenueCat, Superwall, Adapty or your own
  paywall, with no dependency on their SDKs (see below).
- **Consent.** By default nothing is stored on the device and the server derives a daily visitor ID.
  `configure(…, consent: true)` or `setConsent(true)` keeps a random ID so a visitor lasts across days.
- **Offline queue.** Events queue in UserDefaults (up to 500, for 7 days) and are delivered in order, with
  backoff on network errors, rate limits and server errors. The queue flushes when the app returns to
  the foreground and when it goes to the background.
- **Language and screen size.** Each screen view carries the device's preferred language (for example
  `en-US`) and the screen size in points (for example `390x844`). Events never carry them.
- **Deep links.** `MetricRaven.openedFrom(url:)` attaches utm_* campaign parameters to the next screen.

### Paywall events

```swift
let paywall = MetricRavenPaywall(provider: "revenuecat", offeringId: offering.identifier)
PaywallView(offering: offering)
    .onAppear { paywall.impression() }
    .onPurchaseCancelled { paywall.cancel() }
    .onPaywallInteraction { event in paywall.interaction(event.rawProperties) }
```

Superwall: `paywall.superwall(eventInfo.event.description, params: eventInfo.params)`. Send paywall
events from the app or forward them from your backend, not both, or they are counted twice. See
[Paywall events](https://metricraven.com/docs/paywall-events).

## Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no tracking
domains. It doesn't use the advertising identifier, and without consent it stores nothing on the device.

## Links

- Docs: https://metricraven.com/docs/ios-sdk
- Paywall events: https://metricraven.com/docs/paywall-events
- Dashboard and sign-up: https://metricraven.com
- Android and Kotlin: https://github.com/Dual-Ninja-LLC/metricraven-kotlin
- Support: support@metricraven.com

## Development

```sh
swift test
xcodebuild -scheme MetricRaven -destination 'generic/platform=iOS Simulator' build
```

`Tests/MetricRavenTests/contract-payloads.json` is shared with the backend's collect schema test, so
the payloads can't drift from what the server accepts.

## License

MIT. See [LICENSE](LICENSE). Published by Dual Ninja LLC.
