# MetricRaven for Swift

MetricRaven analytics for native iOS, iPadOS, macOS, tvOS, watchOS and visionOS apps: screen views,
events, identify, consent and an offline queue. No dependencies.

Add `https://github.com/Dual-Ninja-LLC/metricraven-swift` with Swift Package Manager (Xcode: File →
Add Package Dependencies…).

```swift
import MetricRaven

// At launch. The app ID (your bundle ID) must be listed under Settings → General → Site → Mobile apps.
MetricRaven.configure(siteId: "ana_pub_…")

MetricRaven.screen("Home")
MetricRaven.track("signup", props: ["plan": "pro"])

// After sign-in: the same user ID your server events and server identify use.
MetricRaven.identify("user_42", traits: ["name": "Ana", "email": "ana@example.com"])
// Or verified, with a token your server signs (signIdentity in @metricraven/node):
MetricRaven.identify(token: tokenFromYourServer)

// On sign-out.
MetricRaven.reset()
```

The device shows on the realtime globe as a live visitor, under the person it was identified as.

- **Consent.** By default nothing is stored on the device and the server derives a daily visitor ID.
  `configure(…, consent: true)` or `setConsent(true)` keeps a random ID so a visitor lasts across days.
- **Offline.** Events queue in UserDefaults (up to 500, for 7 days) and are delivered in order, with
  backoff on network errors, rate limits and server errors. The queue flushes when the app returns to
  the foreground and when it goes to the background.
- **Language and screen size.** Each screen view carries the device's preferred language (for example
  `en-US`) and the screen size in points (for example `390x844`). Events never carry them.
- **Deep links.** `MetricRaven.openedFrom(url:)` attaches utm_* campaign parameters to the next screen.

Docs: https://metricraven.com/docs/ios-sdk

## Paywall events

Paywall views, closes, cancels and taps from RevenueCat, Superwall, Adapty or your own paywall, with no dependency on their SDKs:

```swift
let paywall = MetricRavenPaywall(provider: "revenuecat", offeringId: offering.identifier)
PaywallView(offering: offering)
    .onAppear { paywall.impression() }
    .onPurchaseCancelled { paywall.cancel() }
    .onPaywallInteraction { event in paywall.interaction(event.rawProperties) }
```

Superwall: `paywall.superwall(eventInfo.event.description, params: eventInfo.params)`. Send paywall events from the app or forward them from your backend, not both, or they are counted twice. See https://metricraven.com/docs/paywall-events.

## Development

```sh
swift test
xcodebuild -scheme MetricRaven -destination 'generic/platform=iOS Simulator' build
```

`Tests/MetricRavenTests/contract-payloads.json` is shared with the backend's collect schema test, so
the payloads can't drift from what the server accepts.
