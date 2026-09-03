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
        case .python:
            return await checkPython(fileURL: url)
        case .javascript:
            return await checkJavaScript(fileURL: url)
        case .swift:
            return await checkSwift(fileURL: url)
        default:
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

    private static func checkPython(fileURL: URL) async -> [SyntaxDiagnostic] {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.fileExists(atPath: pythonPath) else { return [] }

        return await Task.detached(priority: .utility) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-m", "py_compile", fileURL.path]
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return [] }

                let errorOutput = String(decoding: data, as: UTF8.self)
                return parsePythonError(errorOutput)
            } catch {
                return []
            }
        }.value
    }

    private static func parsePythonError(_ output: String) -> [SyntaxDiagnostic] {
        // Look for: File "...", line 12
        // SyntaxError: ...
        var line = 1
        var message = "Syntax error"
        let lines = output.components(separatedBy: .newlines)
        for l in lines {
            if let match = l.range(of: #"line (\d+)"#, options: .regularExpression) {
                let numStr = l[match].replacingOccurrences(of: "line ", with: "")
                line = Int(numStr) ?? 1
            }
            if l.contains("SyntaxError:") || l.contains("IndentationError:") {
                message = l.trimmingCharacters(in: .whitespaces)
            }
        }
        return [SyntaxDiagnostic(line: line, message: message)]
    }

    private static func checkJavaScript(fileURL: URL) async -> [SyntaxDiagnostic] {
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let nodePath = nodeCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return [] }

        return await Task.detached(priority: .utility) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: nodePath)
            process.arguments = ["--check", fileURL.path]
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return [] }

                let errorOutput = String(decoding: data, as: UTF8.self)
                return parseNodeError(errorOutput)
            } catch {
                return []
            }
        }.value
    }

    private static func parseNodeError(_ output: String) -> [SyntaxDiagnostic] {
        var line = 1
        var message = "Syntax error"
        let lines = output.components(separatedBy: .newlines)
        for l in lines {
            if let match = l.range(of: #":(\d+)\n"#, options: .regularExpression) {
                let numStr = l[match].trimmingCharacters(in: CharacterSet(charactersIn: ":\n"))
                line = Int(numStr) ?? 1
            }
            if l.contains("SyntaxError:") {
                message = l.trimmingCharacters(in: .whitespaces)
            }
        }
        return [SyntaxDiagnostic(line: line, message: message)]
    }

    private static func checkSwift(fileURL: URL) async -> [SyntaxDiagnostic] {
        let swiftcPath = "/usr/bin/swiftc"
        guard FileManager.default.fileExists(atPath: swiftcPath) else { return [] }

        return await Task.detached(priority: .utility) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: swiftcPath)
            process.arguments = ["-parse", fileURL.path]
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return [] }

                let errorOutput = String(decoding: data, as: UTF8.self)
                return parseSwiftError(errorOutput)
            } catch {
                return []
            }
        }.value
    }

    private static func parseSwiftError(_ output: String) -> [SyntaxDiagnostic] {
        var diagnostics: [SyntaxDiagnostic] = []
        let lines = output.components(separatedBy: .newlines)
        // Format: /path/to/file.swift:10:5: error: expected ...
        for line in lines {
            if line.contains(": error:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 4, let lineNum = Int(parts[1]) {
                    let colNum = Int(parts[2]) ?? 1
                    let msg = parts.dropFirst(3).joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    diagnostics.append(SyntaxDiagnostic(line: lineNum, column: colNum, message: msg))
                }
            }
        }
        return diagnostics
    }
}
