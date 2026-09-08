import Foundation
import Testing
@testable import LSPClientKit

@Suite("LSPClientKit Tests")
struct LSPClientKitTests {
    // 受信バッファから JSON-RPC メッセージを正しく抽出・パースできるかを検証
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

    // LSP の補完レスポンスから候補アイテム（ラベル、補完テキスト、詳細情報）を正しくデコードできるかを検証
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

    // LSP のフォーマット編集差分を末尾からの逆順で正確に適用できるかを検証
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

    // エディタの UTF-16 位置情報をサーバー側で合意された LSP 文字エンコーディング（UTF-8, UTF-16, UTF-32）に正しく変換できるかを検証
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

    // 言語設定に応じて利用可能な言語サーバー定義を正しく解決できるかを検証
    @Test("LanguageServerConfig resolves language servers")
    func resolvesLanguageServers() {
        let swiftServer = LanguageServerConfig.resolve(for: .swift)
        #expect(swiftServer != nil)
        #expect(swiftServer?.identifier == "sourcekit-lsp")
        #expect(swiftServer?.languageId == "swift")
    }

    // LSP 3.16+ 相対デルタ整数ストリームからセマンティックトークンを正しくデコードできるかを検証
    @Test("LSPClient parses relative semantic tokens correctly")
    func parsesSemanticTokens() {
        // [deltaLine, deltaStartChar, length, tokenTypeIndex, tokenModifierBits]
        // Token 1: line 0, char 4, length 6, type 0 ("class"), modifier 1
        // Token 2: line 0 (delta 0), char 11 (delta 7), length 3, type 1 ("identifier"), modifier 0
        // Token 3: line 2 (delta 2), char 4 (delta 4), length 4, type 2 ("keyword"), modifier 0
        let rawJSON: [String: Any] = [
            "result": [
                "data": [
                    0, 4, 6, 0, 1,
                    0, 7, 3, 1, 0,
                    2, 4, 4, 2, 0
                ]
            ]
        ]
        let tokenTypes = ["class", "variable", "keyword"]
        let tokenModifiers = ["declaration"]

        let tokens = LSPClient.parseSemanticTokens(from: rawJSON, tokenTypes: tokenTypes, tokenModifiers: tokenModifiers)
        #expect(tokens.count == 3)

        #expect(tokens[0].line == 0)
        #expect(tokens[0].character == 4)
        #expect(tokens[0].length == 6)
        #expect(tokens[0].type == "class")
        #expect(tokens[0].modifiers == ["declaration"])

        #expect(tokens[1].line == 0)
        #expect(tokens[1].character == 11)
        #expect(tokens[1].length == 3)
        #expect(tokens[1].type == "variable")
        #expect(tokens[1].modifiers.isEmpty)

        #expect(tokens[2].line == 2)
        #expect(tokens[2].character == 4)
        #expect(tokens[2].length == 4)
        #expect(tokens[2].type == "keyword")
        #expect(tokens[2].modifiers.isEmpty)
    }
}
