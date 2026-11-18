import Foundation
import XCTest
@testable import MetricRaven

final class PaywallTests: XCTestCase {
    private func client(_ transport: MockTransport) throws -> MetricRavenClient {
        try MetricRavenClient(configuration: MetricRavenConfiguration(
            siteId: "ana_pub_test", appId: "com.example.app", platform: .ios,
            storage: MemoryStorage(), transport: transport
        ))
    }

    func testSendsTheFiveEventsWithProviderPaywallAndOffering() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        let paywall = MetricRavenPaywall(provider: "revenuecat", paywallId: "pw1", offeringId: "premium", client: c)
        paywall.impression(); paywall.close(); paywall.cancel(); paywall.exitOffer()
        paywall.interaction(["component_type": "package"])
        await c.flush()
        XCTAssertEqual(transport.sent.map { $0["name"] as? String }, MetricRavenPaywall.Event.allCases.map(\.rawValue))
        for body in transport.sent.prefix(4) {
            XCTAssertEqual(body["props"] as? [String: String], ["provider": "revenuecat", "paywall_id": "pw1", "offering_id": "premium"])
        }
    }

    func testNoPropsWhenNothingIsKnown() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        MetricRavenPaywall(client: c).impression()
        await c.flush()
        XCTAssertEqual(transport.sent.first?["name"] as? String, "paywall_impression")
        XCTAssertNil(transport.sent.first?["props"])
    }

    func testInteractionMapsRawPropertiesPreferringTheirPaywallAndOffering() {
        let raw: [String: Any] = [
            "paywall_id": "pw903", "paywall_name": "Subscription Paywall", "offering_id": "premium",
            "component_type": "package", "component_name": "AnnualPackage", "component_value": "yearly",
            "origin_product_id": "starter", "destination_product_id": "yearly",
            "session_id": "dropped", "dark_mode": false, "nested": ["x": 1],
        ]
        let paywall = MetricRavenPaywall(provider: "revenuecat", offeringId: "fallback", props: ["screen": "onboarding"])
        XCTAssertEqual(paywall.interactionProps(raw), [
            "provider": "revenuecat", "paywall_id": "pw903", "paywall_name": "Subscription Paywall", "offering_id": "premium",
            "component_type": "package", "component_name": "AnnualPackage", "component_value": "yearly",
            "origin_product_id": "starter", "destination_product_id": "yearly", "screen": "onboarding",
        ])
    }

    func testStringDictionariesAndPaywallFieldsWinOverExtraProps() {
        let raw: [String: String] = [
            "component_type": "tab", "component_name": "a", "component_value": "b",
            "origin_product_id": "e", "destination_product_id": "f",
        ]
        var extra: MetricRavenProps = [:]
        for i in 0..<12 { extra["k\(i)"] = .number(Double(i)) }
        let props = MetricRavenPaywall(provider: "revenuecat", paywallId: "p", paywallName: "n", offeringId: "o", placement: "x", props: extra)
            .interactionProps(raw)
        XCTAssertEqual(props.count, 10)
        XCTAssertNil(props["k0"])
        XCTAssertEqual(props["component_type"], "tab")
    }

    func testProductSelected() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        MetricRavenPaywall(provider: "adapty", placement: "onboarding", client: c).productSelected("annual")
        await c.flush()
        XCTAssertEqual(transport.sent.first?["name"] as? String, "paywall_component_interacted")
        XCTAssertEqual(transport.sent.first?["props"] as? [String: String],
                       ["provider": "adapty", "placement": "onboarding", "component_type": "package", "destination_product_id": "annual"])
    }

    func testSuperwallMapsOpenCloseAndAbandonInEitherNameStyle() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        let paywall = MetricRavenPaywall(placement: "campaign_trigger", client: c)
        paywall.superwall("paywall_open", params: ["paywall_identifier": "annual-v2", "paywall_name": "Annual", "other": 1] as [String: Any])
        paywall.superwall("paywallClose", params: ["paywall_id": "42"])
        paywall.superwall("transactionAbandon", params: ["abandoned_product_id": "annual"])
        paywall.superwall("paywallOpen", params: ["paywall_identifier": "x", "presented_by_event_name": "settings_upgrade"])
        paywall.superwall("paywall_decline")
        paywall.superwall("app_open")
        await c.flush()
        XCTAssertEqual(transport.sent.map { $0["name"] as? String }, ["paywall_impression", "paywall_close", "paywall_cancel", "paywall_impression"])
        XCTAssertEqual(transport.sent[2]["props"] as? [String: String],
                       ["provider": "superwall", "placement": "campaign_trigger", "destination_product_id": "annual"])
        XCTAssertEqual(transport.sent[3]["props"] as? [String: String],
                       ["provider": "superwall", "paywall_id": "x", "placement": "settings_upgrade"])
        XCTAssertEqual(transport.sent[0]["props"] as? [String: String],
                       ["provider": "superwall", "paywall_id": "annual-v2", "paywall_name": "Annual", "placement": "campaign_trigger"])
        XCTAssertEqual(transport.sent[1]["props"] as? [String: String],
                       ["provider": "superwall", "paywall_id": "42", "placement": "campaign_trigger"])
    }
}
