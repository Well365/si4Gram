import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.40.1: the pair the main app connects with, handed to its extensions through the app-group container.
final class ApiCredentialShareTests: XCTestCase {
    private let pairHash = "0123456789abcdef0123456789abcdef"

    private func tempGroup() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secutg-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    func testWriteThenReadIsThePairOwnerOnly() throws {
        let group = try tempGroup()
        XCTAssertNil(ApiCredentialShare.read(appGroupPath: group))
        ApiCredentialShare.write(apiId: 12345, apiHash: pairHash.uppercased(), appGroupPath: group)
        XCTAssertEqual(ApiCredentialShare.read(appGroupPath: group), ApiCredentialRules.Credentials(apiId: 12345, apiHash: pairHash))
        let attributes = try FileManager.default.attributesOfItem(atPath: ApiCredentialShare.url(appGroupPath: group).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnInvalidPairRemovesTheFileAndClearForgetsIt() throws {
        let group = try tempGroup()
        ApiCredentialShare.write(apiId: 7, apiHash: pairHash, appGroupPath: group)
        ApiCredentialShare.write(apiId: 0, apiHash: pairHash, appGroupPath: group)
        XCTAssertNil(ApiCredentialShare.read(appGroupPath: group))
        ApiCredentialShare.write(apiId: 7, apiHash: pairHash, appGroupPath: group)
        ApiCredentialShare.clear(appGroupPath: group)
        XCTAssertNil(ApiCredentialShare.read(appGroupPath: group))
    }

    func testAMalformedFileIsIgnored() {
        XCTAssertNil(ApiCredentialShare.parse(Data("{\"api_id\":true,\"api_hash\":\"\(pairHash)\"}".utf8)))
        XCTAssertNil(ApiCredentialShare.parse(Data("{\"api_id\":5,\"api_hash\":\"short\"}".utf8)))
        XCTAssertNil(ApiCredentialShare.parse(Data("[]".utf8)))
        XCTAssertEqual(ApiCredentialShare.parse(Data("{\"api_id\":5,\"api_hash\":\"\(pairHash)\"}".utf8))?.apiId, 5)
    }
}
