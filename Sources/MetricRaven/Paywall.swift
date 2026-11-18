import Foundation

/**
 Paywall events from the app (RevenueCat, Superwall, Adapty or your own paywall): impression, close,
 cancel, exit offer and component interactions, as MetricRaven goals. No dependency on any paywall
 SDK: call these from its callbacks. Names and properties match RevenueCat's paywall webhook events
 forwarded from a backend (metricraven.com/docs/paywall-events), so either route gives the same goals.
 Use one route, not both: events sent both ways are counted twice.

 ```swift
 let paywall = MetricRavenPaywall(provider: "revenuecat", offeringId: offering.identifier)
 PaywallView(offering: offering)
     .onAppear { paywall.impression() }
     .onPurchaseCancelled { paywall.cancel() }
     .onPaywallInteraction { event in paywall.interaction(event.rawProperties) }
 ```
 */
public struct MetricRavenPaywall: Sendable {
    public enum Event: String, CaseIterable, Sendable {
        case impression = "paywall_impression"
        case close = "paywall_close"
        case cancel = "paywall_cancel"
        case exitOffer = "paywall_exit_offer"
        case interaction = "paywall_component_interacted"
    }

    /// The component interaction properties kept (RevenueCat's snake_case keys).
    public static let interactionKeys = [
        "component_type", "component_name", "component_value", "origin_product_id", "destination_product_id",
    ]

    private static let superwallEvents: [String: Event] = [
        "paywall_open": .impression, "paywall_close": .close, "transaction_abandon": .cancel,
    ]

    public let provider: String?
    public let paywallId: String?
    public let paywallName: String?
    public let offeringId: String?
    public let placement: String?
    public let props: MetricRavenProps?
    private let client: MetricRavenClient?

    /**
     - Parameters:
       - provider: which paywall tool shows it ("revenuecat", "superwall", "adapty"); sent as `provider`.
       - paywallId: the paywall's ID, when known.
       - offeringId: RevenueCat's offering shown (offering.identifier). Its close, cancel and exit offer callbacks don't say.
       - placement: where the paywall was shown (Superwall or Adapty placement, or your own name).
       - props: extra properties on every event; at most 10 properties per event in total.
       - client: a client of your own; the shared one by default.
     */
    public init(
        provider: String? = nil, paywallId: String? = nil, paywallName: String? = nil, offeringId: String? = nil,
        placement: String? = nil, props: MetricRavenProps? = nil, client: MetricRavenClient? = nil
    ) {
        self.provider = provider
        self.paywallId = paywallId
        self.paywallName = paywallName
        self.offeringId = offeringId
        self.placement = placement
        self.props = props
        self.client = client
    }

    /// Call when the paywall is shown (RevenueCat has no callback for it; Adapty: didAppear).
    public func impression() { send(.impression, finish(base())) }
    /// RevenueCat `onDismiss` / `paywallViewControllerWasDismissed(_:)`; Adapty didDisappear.
    public func close() { send(.close, finish(base())) }
    /// RevenueCat `.onPurchaseCancelled` / `paywallViewControllerDidCancelPurchase(_:)`; Adapty a cancelled purchase.
    public func cancel() { send(.cancel, finish(base())) }
    /// RevenueCat `paywallViewController(_:willPresentExitOfferController:)` (UIKit).
    public func exitOffer() { send(.exitOffer, finish(base())) }

    /// RevenueCat `.onPaywallInteraction` / `paywallViewController(_:didTrackInteraction:)`: pass `event.rawProperties`.
    public func interaction<Value>(_ rawProperties: [String: Value]) {
        send(.interaction, interactionProps(rawProperties))
    }

    /// A product was picked on the paywall (Adapty didSelectProduct, or your own paywall).
    public func productSelected(_ productId: String) {
        var out = base()
        out["component_type"] = "package"
        if let id = Self.text(productId) { out["destination_product_id"] = .string(id) }
        send(.interaction, finish(out))
    }

    /**
     Superwall's `handleSuperwallEvent(withInfo:)`: pass `eventInfo.event.description` and `eventInfo.params`.
     paywall_open, paywall_close and transaction_abandon are sent; other events are ignored.
     */
    public func superwall<Value>(_ name: String, params: [String: Value] = [String: String]()) {
        guard let event = Self.superwallEvents[Self.snake(name)] else { return }
        // SuperwallKit's PaywallInfo params; abandoned_product_id comes with transaction_abandon.
        let me = MetricRavenPaywall(
            provider: provider ?? "superwall",
            paywallId: Self.text(params["paywall_identifier"]) ?? Self.text(params["paywall_id"]) ?? paywallId,
            paywallName: Self.text(params["paywall_name"]) ?? paywallName,
            offeringId: offeringId,
            placement: Self.text(params["presented_by_event_name"]) ?? placement,
            props: props, client: client
        )
        var out = me.base()
        if event == .cancel, let product = Self.text(params["abandoned_product_id"]) {
            out["destination_product_id"] = .string(product)
        }
        me.send(event, me.finish(out))
    }

    /// The properties of one RevenueCat component interaction: paywall, offering and the component fields.
    public func interactionProps<Value>(_ raw: [String: Value]) -> MetricRavenProps {
        let me = MetricRavenPaywall(
            provider: provider,
            paywallId: Self.text(raw["paywall_id"]) ?? paywallId,
            paywallName: Self.text(raw["paywall_name"]) ?? paywallName,
            offeringId: Self.text(raw["offering_id"]) ?? offeringId,
            placement: placement, props: props, client: client
        )
        var out = me.base()
        for key in Self.interactionKeys {
            if let value = raw[key].flatMap({ Self.value($0 as Any) }) { out[key] = value }
        }
        return me.finish(out)
    }

    private func base() -> MetricRavenProps {
        var out: MetricRavenProps = [:]
        let fields = [("provider", provider), ("paywall_id", paywallId), ("paywall_name", paywallName),
                      ("offering_id", offeringId), ("placement", placement)]
        for (key, value) in fields { if let v = Self.text(value) { out[key] = .string(v) } }
        return out
    }

    /// Extra props fill up to 10 without replacing the paywall fields.
    private func finish(_ out: MetricRavenProps) -> MetricRavenProps {
        var out = out
        for key in (props ?? [:]).keys.sorted() where out[key] == nil && out.count < 10 { out[key] = props?[key] }
        return out
    }

    private func send(_ event: Event, _ props: MetricRavenProps) {
        (client ?? MetricRaven.shared)?.track(event.rawValue, props: props.isEmpty ? nil : props)
    }

    /// paywallOpen or paywall_open → paywall_open.
    private static func snake(_ name: String) -> String {
        var out = ""
        var previous: Character?
        for c in name.trimmingCharacters(in: .whitespaces) {
            if c.isUppercase, let p = previous, p.isLowercase || p.isNumber { out.append("_") }
            out.append(contentsOf: c.lowercased())
            previous = c
        }
        return out
    }

    private static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func value(_ raw: Any) -> MetricRavenValue? {
        switch raw {
        case let v as MetricRavenValue: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as Float: return .number(Double(v))
        case let v as NSNumber: return .number(v.doubleValue)
        case let v as any RawRepresentable: return (v.rawValue as? String).map { .string($0) }
        default: return nil
        }
    }
}
