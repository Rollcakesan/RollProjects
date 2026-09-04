import Foundation

struct SyntaxDiagnostic: Identifiable, Equatable, Sendable {
    let id: UUID
    let line: Int
    let column: Int
    let message: String
    let severity: Severity

    enum Severity: Sendable {
        case error
        case warning
    }

    init(id: UUID = UUID(), line: Int, column: Int = 1, message: String, severity: Severity = .error) {
        self.id = id
        self.line = line
        self.column = column
        self.message = message
        self.severity = severity
    }
}

enum SyntaxCheckService {
    static func check(url: URL, text: String, language: CodeLanguage) async -> [SyntaxDiagnostic] {
        switch language {
        case .json:
            return checkJSON(text: text)
        default:
            // Full diagnostics for Swift, Python, JS/TS, etc., are provided asynchronously by LSPClientKit.
            return []
        }
    }

    private static func checkJSON(text: String) -> [SyntaxDiagnostic] {
        guard let data = text.data(using: .utf8) else { return [] }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return []
        } catch {
            let nsError = error as NSError
            let desc = nsError.userInfo["NSDebugDescription"] as? String ?? error.localizedDescription
            // Parse line number if available in error description
            var line = 1
            if let match = desc.range(of: #"line (\d+)"#, options: .regularExpression) {
                let numStr = desc[match].replacingOccurrences(of: "line ", with: "")
                line = Int(numStr) ?? 1
            }
            return [SyntaxDiagnostic(line: line, message: desc)]
        }
    }
}
