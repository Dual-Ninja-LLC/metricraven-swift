import Foundation
import XCTest
@testable import MetricRaven

/// Answers each request with the next scripted status (200 once the script runs out) and records bodies.
final class MockTransport: MetricRavenTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int?]
    private(set) var bodies: [[String: Any]] = []
    var visitorId: String?

    init(_ statuses: [Int?] = []) { self.statuses = statuses }

    func post(_ body: Data, to url: URL) async throws -> TransportResponse {
        lock.lock()
        let next = statuses.isEmpty ? 200 : statuses.removeFirst()
        lock.unlock()
        guard let status = next else { throw URLError(.notConnectedToInternet) }
        lock.lock()
        if (200..<300).contains(status) {
            bodies.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        }
        let id = visitorId
        lock.unlock()
        let answer = id.map { "{\"visitorId\":\"\($0)\"}" } ?? "{}"
        return TransportResponse(status: status, body: Data(answer.utf8))
    }

    var sent: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
}

final class ClientTests: XCTestCase {
    private let fixedId = "0123456789abcdef0123456789abcdef"

    private func client(
        _ transport: MockTransport,
        consent: Bool = false,
        storage: MetricRavenStorage = MemoryStorage()
    ) throws -> MetricRavenClient {
        try MetricRavenClient(configuration: MetricRavenConfiguration(
            siteId: "ana_pub_test",
            appId: "com.example.app",
            appVersion: "1.2.0",
            appBuild: "42",
            platform: .ios,
            osVersion: "26.1",
            deviceType: .mobile,
            consent: consent,
            storage: storage,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            randomId: { [fixedId] in fixedId }
        ))
    }

    func testScreenViewPayloadMatchesTheCollectSchema() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        c.screen("Settings", props: ["tab": "profile"])
        await c.flush()
        let body = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(body["siteId"] as? String, "ana_pub_test")
        XCTAssertEqual(body["type"] as? String, "pageview")
        XCTAssertEqual(body["screen"] as? String, "Settings")
        XCTAssertEqual(body["timestamp"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(body["props"] as? [String: String], ["tab": "profile"])
        XCTAssertNil(body["clientId"], "nothing is stored without consent")
        let app = try XCTUnwrap(body["app"] as? [String: String])
        XCTAssertEqual(app, ["id": "com.example.app", "version": "1.2.0", "build": "42", "platform": "ios", "osVersion": "26.1", "deviceType": "mobile"])
    }

    func testEventsCarryTheCurrentScreenAndBadNamesAreDropped() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        c.screen("Paywall")
        c.track("1bad name")
        c.track("purchase", props: ["plan": "pro", "seats": 3, "trial": false])
        await c.flush()
        XCTAssertEqual(transport.sent.count, 2)
        let event = transport.sent[1]
        XCTAssertEqual(event["name"] as? String, "purchase")
        XCTAssertEqual(event["screen"] as? String, "Paywall")
        let props = try XCTUnwrap(event["props"] as? [String: Any])
        XCTAssertEqual(props["seats"] as? Int, 3)
        XCTAssertEqual(props["trial"] as? Bool, false)
    }

    func testIdentifyCleansTraitsAndIsNotRepeated() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        c.identify("user_42", traits: ["name": "Ana", "email": "not-an-email", "Plan": "pro", "country": "ES"])
        c.identify("user_42", traits: ["name": "Ana", "email": "not-an-email", "Plan": "pro", "country": "ES"])
        await c.flush()
        XCTAssertEqual(transport.sent.count, 1)
        let body = transport.sent[0]
        XCTAssertEqual(body["type"] as? String, "identify")
        XCTAssertEqual(body["userId"] as? String, "user_42")
        XCTAssertEqual(body["traits"] as? [String: String], ["name": "Ana", "country": "ES"])
    }

    func testSignedIdentifySendsOnlyTheToken() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        c.identify(token: "not a token")
        c.identify(token: "aaa.bbb.ccc")
        await c.flush()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0]["identityToken"] as? String, "aaa.bbb.ccc")
        XCTAssertNil(transport.sent[0]["traits"])
    }

    func testConsentKeepsAnIdAndLinksTheFirstEvent() async throws {
        let transport = MockTransport()
        let storage = MemoryStorage()
        let c = try client(transport, consent: true, storage: storage)
        c.screen("Home")
        c.screen("Feed")
        await c.flush()
        XCTAssertEqual(transport.sent[0]["clientId"] as? String, fixedId)
        XCTAssertEqual(transport.sent[0]["link"] as? Bool, true)
        XCTAssertNil(transport.sent[1]["link"])
        XCTAssertEqual(storage.string(forKey: "metricraven:client-id:ana_pub_test"), fixedId)
        let id = await c.visitorId
        XCTAssertEqual(id, fixedId)

        c.setConsent(false)
        c.screen("Settings")
        await c.flush()
        XCTAssertNil(transport.sent[2]["clientId"])
        XCTAssertNil(storage.string(forKey: "metricraven:client-id:ana_pub_test"))
    }

    func testRetriesServerErrorsInOrderAndDropsRejections() async throws {
        let transport = MockTransport([503, nil, 400])
        let c = try client(transport)
        c.screen("A") // 503: kept
        await c.flush() // offline: kept
        await c.flush() // 400: A dropped
        c.screen("B")
        await c.flush()
        XCTAssertEqual(transport.sent.map { $0["screen"] as? String }, ["B"])
        let pending = await c.pending
        XCTAssertEqual(pending, 0)
    }

    func testOfflineEventsAreDeliveredInOrderLater() async throws {
        let transport = MockTransport([nil])
        let c = try client(transport)
        c.screen("A")
        c.screen("B")
        await c.flush() // A fails offline, backs off
        await c.flush()
        XCTAssertEqual(transport.sent.map { $0["screen"] as? String }, ["A", "B"])
    }

    func testTheQueueSurvivesARelaunch() async throws {
        let storage = MemoryStorage()
        let offline = MockTransport([nil, nil, nil])
        let first = try client(offline, storage: storage)
        first.screen("Saved")
        await first.flush()
        first.shutdown()
        XCTAssertNotNil(storage.string(forKey: "metricraven:queue:ana_pub_test"))

        let online = MockTransport()
        let second = try client(online, storage: storage)
        await second.flush()
        XCTAssertEqual(online.sent.map { $0["screen"] as? String }, ["Saved"])
        XCTAssertNil(storage.string(forKey: "metricraven:queue:ana_pub_test"))
    }

    func testTheServerVisitorIdIsReported() async throws {
        let transport = MockTransport()
        transport.visitorId = "ffffffffffffffffffffffffffffffff"
        let c = try client(transport)
        c.screen("Home")
        await c.flush()
        let id = await c.visitorId
        XCTAssertEqual(id, "ffffffffffffffffffffffffffffffff")
    }

    func testDeepLinkCampaignGoesOnTheNextScreen() async throws {
        let transport = MockTransport()
        let c = try client(transport)
        c.openedFrom(url: URL(string: "myapp://open?utm_source=tiktok&utm_campaign=launch&other=1"))
        c.screen("Home")
        c.screen("Feed")
        await c.flush()
        XCTAssertEqual(transport.sent[0]["utm"] as? [String: String], ["source": "tiktok", "campaign": "launch"])
        XCTAssertNil(transport.sent[1]["utm"])
    }

    func testRejectsAnAppIdThatIsNotABundleId() {
        XCTAssertThrowsError(try MetricRavenClient(configuration: MetricRavenConfiguration(siteId: "s", appId: "not a bundle id"))) { error in
            XCTAssertEqual(error as? MetricRavenError, .invalidAppId("not a bundle id"))
        }
    }
}
