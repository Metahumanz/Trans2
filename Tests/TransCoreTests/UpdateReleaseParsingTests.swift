import XCTest
@testable import TransCore

final class UpdateReleaseParsingTests: XCTestCase {
    private let releaseJSON = """
    {
      "tag_name": "v0.3.0",
      "html_url": "https://github.com/Metahumanz/Trans2/releases/tag/v0.3.0",
      "body": "### 新增\\n- 新版本",
      "assets": [
        {"name": "Trans2-0.3.0-arm64.zip", "browser_download_url": "https://example.com/Trans2.zip"},
        {"name": "Trans2-0.3.0-arm64.dmg", "browser_download_url": "https://example.com/Trans2.dmg"}
      ]
    }
    """

    func testParsesNewerReleaseAndPrefersDMG() throws {
        let info = try XCTUnwrap(UpdateChecker.releaseInfo(
            from: Data(releaseJSON.utf8),
            currentVersion: "0.2.0"
        ))
        XCTAssertEqual(info.version, "0.3.0")
        XCTAssertEqual(info.downloadURL.lastPathComponent, "Trans2.dmg")
        XCTAssertEqual(info.pageURL.absoluteString, "https://github.com/Metahumanz/Trans2/releases/tag/v0.3.0")
        XCTAssertTrue(info.notes.contains("新版本"))
    }

    func testSameVersionIsNotAnUpdate() throws {
        let info = try UpdateChecker.releaseInfo(
            from: Data(releaseJSON.utf8),
            currentVersion: "0.3.0"
        )
        XCTAssertNil(info)
    }

    func testFallsBackToZipWhenNoDMG() throws {
        let json = releaseJSON.replacingOccurrences(of: "Trans2-0.3.0-arm64.dmg", with: "Trans2-0.3.0-arm64.pkg")
        let info = try XCTUnwrap(UpdateChecker.releaseInfo(
            from: Data(json.utf8),
            currentVersion: "0.2.0"
        ))
        XCTAssertEqual(info.downloadURL.lastPathComponent, "Trans2.zip")
    }

    func testMissingVersionThrows() {
        let json = #"{"tag_name":"","assets":[],"html_url":"https://example.com"}"#
        XCTAssertThrowsError(try UpdateChecker.releaseInfo(
            from: Data(json.utf8),
            currentVersion: "0.2.0"
        ))
    }
}
