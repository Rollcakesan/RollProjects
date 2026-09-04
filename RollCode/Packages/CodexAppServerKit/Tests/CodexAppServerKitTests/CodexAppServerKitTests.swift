import XCTest
@testable import CodexAppServerKit

final class CodexAppServerKitTests: XCTestCase {
    func testTokenUsageFormatting() {
        let usageShort = CodexTokenUsage(inputTokens: 100, cachedTokens: 50, outputTokens: 200)
        XCTAssertEqual(usageShort.totalTokens, 300)
        XCTAssertEqual(usageShort.formattedTotal, "300 tok")

        let usageKilo = CodexTokenUsage(inputTokens: 2500, cachedTokens: 1000, outputTokens: 1500)
        XCTAssertEqual(usageKilo.totalTokens, 4000)
        XCTAssertEqual(usageKilo.formattedTotal, "4.0k tok")

        let usageMega = CodexTokenUsage(inputTokens: 800_000, cachedTokens: 200_000, outputTokens: 400_000)
        XCTAssertEqual(usageMega.totalTokens, 1_200_000)
        XCTAssertEqual(usageMega.formattedTotal, "1.2M tok")
    }

    func testAppServerModelProperties() {
        let model = CodexAppServerModel(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6-Sol",
            speedTier: .deep,
            supportsReasoningEffort: true
        )
        XCTAssertEqual(model.id, "gpt-5.6-sol")
        XCTAssertEqual(model.displayName, "GPT-5.6-Sol")
        XCTAssertEqual(model.speedTier, .deep)
        XCTAssertTrue(model.supportsReasoningEffort)
    }

    func testJSONDictionarySubscript() {
        let dict = CodexAppServerClient.JSONDictionary([
            "success": true,
            "count": 99,
            "meta": ["version": "1.0"]
        ])
        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["count"] as? Int, 99)
        let meta = dict["meta"] as? [String: Any]
        XCTAssertEqual(meta?["version"] as? String, "1.0")
    }

    func testServerStatusEquality() {
        XCTAssertEqual(CodexServerStatus.stopped, CodexServerStatus.stopped)
        XCTAssertEqual(CodexServerStatus.ready, CodexServerStatus.ready)
        XCTAssertEqual(CodexServerStatus.failed("error"), CodexServerStatus.failed("error"))
        XCTAssertNotEqual(CodexServerStatus.starting, CodexServerStatus.ready)
    }

    func testExecutableLocator() {
        // Should return a valid URL if codex is in /opt/homebrew/bin or PATH
        let url = CodexExecutableLocator.locate()
        if let url = url {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        }
    }
}
