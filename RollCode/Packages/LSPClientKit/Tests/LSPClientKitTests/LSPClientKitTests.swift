import Foundation
import Testing
@testable import LSPClientKit

@Suite("LSPClientKit Tests")
struct LSPClientKitTests {
    @Test("LSPClient extracts JSON-RPC messages correctly")
    func extractsJSONRPCMessages() {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        let payload = "Content-Length: \(json.utf8.count)\r\n\r\n\(json)"
        var buffer = Data(payload.utf8)

        let message = LSPClient.extractMessage(from: &buffer)
        #expect(message != nil)
        #expect(message?["id"] as? Int == 1)
        #expect(buffer.isEmpty)
    }

    @Test("LSPClient decodes completion suggestions from result object")
    func decodesCompletionSuggestions() {
        let rawJSON: [String: Any] = [
            "result": [
                "items": [
                    [
                        "label": "print",
                        "detail": "print(items...)",
                        "insertText": "print(${1:items})",
                        "insertTextFormat": 2
                    ]
                ]
            ]
        ]

        let items = LSPClient.completionSuggestions(from: rawJSON, text: "pri")
        #expect(items.count == 1)
        #expect(items[0].label == "print")
        #expect(items[0].insertText == "print(items)")
        #expect(items[0].detail == "print(items...)")
    }

    @Test("LSPClient applies document formatting edits in reverse order")
    func appliesFormattingEdits() {
        let text = "let   x=1\n"
        let editsJSON = """
        {
            "result": [
                {
                    "range": {
                        "start": { "line": 0, "character": 3 },
                        "end": { "line": 0, "character": 6 }
                    },
                    "newText": " "
                },
                {
                    "range": {
                        "start": { "line": 0, "character": 7 },
                        "end": { "line": 0, "character": 7 }
                    },
                    "newText": " "
                },
                {
                    "range": {
                        "start": { "line": 0, "character": 8 },
                        "end": { "line": 0, "character": 8 }
                    },
                    "newText": " "
                }
            ]
        }
        """
        let data = editsJSON.data(using: .utf8)!
        let edits = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let formatted = LSPClient.formattedText(from: edits, text: text)
        #expect(formatted == "let x = 1\n")
    }

    @Test("LSPClient converts UTF-16 editor positions to negotiated LSP encodings")
    func convertsPositionEncodings() {
        let text = "😀abc"
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-16"
        ) == 2)
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-8"
        ) == 4)
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-32"
        ) == 1)
    }

    @Test("LanguageServerConfig resolves language servers")
    func resolvesLanguageServers() {
        let swiftServer = LanguageServerConfig.resolve(for: .swift)
        #expect(swiftServer != nil)
        #expect(swiftServer?.identifier == "sourcekit-lsp")
        #expect(swiftServer?.languageId == "swift")
    }
}
