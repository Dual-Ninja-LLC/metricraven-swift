import Foundation
import XCTest
@testable import MetricRaven

/// contract-payloads.json is also parsed by the backend's collectSchema
/// (packages/backend/src/lib/swift-sdk-contract.test.ts), so the Swift field names and the server
/// schema cannot drift apart.
final class ContractTests: XCTestCase {
    func testTheSharedPayloadsRoundTripThroughTheSwiftTypes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "contract-payloads", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for object in raw {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let payload = try JSONDecoder().decode(CollectPayload.self, from: data)
            let again = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! NSDictionary
            XCTAssertEqual(again, object as NSDictionary)
        }
    }

    func testScreenViewsCarryLanguageAndScreenSize() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "contract-payloads", withExtension: "json"))
        let payloads = try JSONDecoder().decode([CollectPayload].self, from: Data(contentsOf: url))
        let pageview = try XCTUnwrap(payloads.first { $0.type == .pageview })
        XCTAssertEqual(pageview.lang, "en-US")
        XCTAssertEqual(pageview.screenSize, "390x844")
        XCTAssertEqual(Validate.language("en_US"), "en-US")
        XCTAssertNil(Validate.language("not a tag!"))
        XCTAssertNil(Validate.screenSize("big"))
        XCTAssertEqual(Validate.screenSize(width: 390.4, height: 843.6), "390x844")
    }
}
