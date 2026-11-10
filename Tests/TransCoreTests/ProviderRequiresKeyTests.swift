import XCTest
@testable import TransCore

final class ProviderRequiresKeyTests: XCTestCase {
    func testLoadKeepsRequiresKeyFlag() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"version":1,"active":"mock","providers":[{"id":"mock","name":"Mock","base_url":"http://127.0.0.1:1/v1","model":"m","requires_key":true}]}"#
        try Data(json.utf8).write(to: url)
        let store = ProviderStore(secrets: MemorySecretStore())
        try store.load(from: url)
        XCTAssertEqual(store.providers.first?.requiresKey, true)
    }
}
