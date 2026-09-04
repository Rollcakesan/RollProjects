import Foundation
import os

private let lspLogger = Logger(subsystem: "com.rollprojects.LSPClientKit", category: "lsp")

@MainActor
public final class LSPClient {
    private enum State {
        case starting
        case ready
        case stopping
        case stopped
    }

    public let server: ResolvedLanguageServer
    public let rootURL: URL

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var state = State.starting
    private var requestIDCounter = 0
    private var initializeRequestID: Int?
    private var shutdownRequestID: Int?
    private var initContinuations: [CheckedContinuation<Bool, Never>] = []
    private var pendingCompletions: [Int: PendingCompletion] = [:]
    private var pendingFormatting: [Int: PendingFormatting] = [:]
    private var openDocumentVersions: [URL: Int] = [:]
    private var positionEncoding = "utf-16"
    private let readQueue = DispatchQueue(label: "com.rollcode.lsp.reader")

    private struct PendingCompletion {
        let text: String
        let continuation: CheckedContinuation<[LSPCompletionItem], Never>
    }

    private struct PendingFormatting {
        let text: String
        let continuation: CheckedContinuation<String?, Never>
    }

    public var isRunning: Bool {
        state != .stopped && process?.isRunning == true
    }

    public init?(server: ResolvedLanguageServer, rootURL: URL) {
        self.server = server
        self.rootURL = rootURL.standardizedFileURL
        guard startServer() else { return nil }
    }

    private func startServer() -> Bool {
        lspLogger.debug("Starting language server \(self.server.identifier, privacy: .public)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.executablePath)
        process.arguments = server.arguments
        process.currentDirectoryURL = rootURL
        process.environment = LanguageServerConfig.processEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            lspLogger.error("Could not start language server \(self.server.identifier, privacy: .public): \(error.localizedDescription, privacy: .private)")
            state = .stopped
            return false
        }

        self.process = process
        stdinHandle = inputPipe.fileHandleForWriting
        let stdout = outputPipe.fileHandleForReading
        let stderr = errorPipe.fileHandleForReading
        stdoutHandle = stdout
        stderrHandle = stderr

        stderr.readabilityHandler = { handle in
            _ = handle.availableData
        }

        readQueue.async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = stdout.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let message = Self.extractMessage(from: &buffer) {
                    Task { @MainActor [weak self] in
                        self?.handleIncomingMessage(message)
                    }
                }
            }
            Task { @MainActor [weak self] in
                self?.serverDidExit()
            }
        }

        let requestID = nextRequestID()
        initializeRequestID = requestID
        let rootURI = rootURL.absoluteString
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "LSPClientKit", "version": "0.1.0"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": rootURL.lastPathComponent]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16", "utf-8", "utf-32"]],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": true],
                    "completion": [
                        "dynamicRegistration": false,
                        "completionItem": [
                            "snippetSupport": false,
                            "documentationFormat": ["plaintext", "markdown"]
                        ]
                    ],
                    "formatting": ["dynamicRegistration": false]
                ]
            ]
        ]
        send(method: "initialize", id: requestID, params: params)
        return true
    }

    public func ensureInitialized() async -> Bool {
        switch state {
        case .ready: return true
        case .stopping, .stopped: return false
        case .starting: break
        }

        let requestID = initializeRequestID
        return await withCheckedContinuation { continuation in
            initContinuations.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.state == .starting, self.initializeRequestID == requestID else { return }
                self.resolveInitContinuations(success: false)
                self.stopServer()
            }
        }
    }

    public func requestCompletions(
        url: URL,
        text: String,
        languageId: String,
        line: Int,
        character: Int
    ) async -> [LSPCompletionItem] {
        guard await ensureInitialized() else { return [] }
        syncDocument(url: url, text: text, languageId: languageId)

        let requestID = nextRequestID()
        let (encodedLine, encodedCharacter) = lspPosition(in: text, line: line, character: character)
        let params: [String: Any] = [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": encodedLine, "character": encodedCharacter]
        ]

        return await withCheckedContinuation { continuation in
            pendingCompletions[requestID] = PendingCompletion(text: text, continuation: continuation)
            send(method: "textDocument/completion", id: requestID, params: params)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let pending = self.pendingCompletions.removeValue(forKey: requestID) else { return }
                pending.continuation.resume(returning: [])
            }
        }
    }

    public func requestFormatting(
        url: URL,
        text: String,
        languageId: String,
        tabWidth: Int
    ) async -> String? {
        guard await ensureInitialized() else { return nil }
        syncDocument(url: url, text: text, languageId: languageId)

        let requestID = nextRequestID()
        let params: [String: Any] = [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "options": [
                "tabSize": max(1, tabWidth),
                "insertSpaces": true
            ]
        ]

        return await withCheckedContinuation { continuation in
            pendingFormatting[requestID] = PendingFormatting(text: text, continuation: continuation)
            send(method: "textDocument/formatting", id: requestID, params: params)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let pending = self.pendingFormatting.removeValue(forKey: requestID) else { return }
                pending.continuation.resume(returning: nil)
            }
        }
    }

    public func closeDocument(_ url: URL) {
        guard state == .ready else { return }
        let standardized = url.standardizedFileURL
        guard openDocumentVersions.removeValue(forKey: standardized) != nil else { return }
        send(
            method: "textDocument/didClose",
            params: ["textDocument": ["uri": standardized.absoluteString]]
        )
    }

    public func stopServer() {
        guard state != .stopping && state != .stopped else { return }
        state = .stopping
        resolveInitContinuations(success: false)
        for (_, pending) in pendingCompletions {
            pending.continuation.resume(returning: [])
        }
        pendingCompletions.removeAll()
        for (_, pending) in pendingFormatting {
            pending.continuation.resume(returning: nil)
        }
        pendingFormatting.removeAll()

        let requestID = nextRequestID()
        shutdownRequestID = requestID
        send(method: "shutdown", id: requestID, params: [:])

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.state == .stopping else { return }
            self.send(method: "exit", params: [:])
            self.terminateProcess()
        }
    }

    private func syncDocument(url: URL, text: String, languageId: String) {
        let standardized = url.standardizedFileURL
        if let version = openDocumentVersions[standardized] {
            let nextVersion = version + 1
            openDocumentVersions[standardized] = nextVersion
            send(
                method: "textDocument/didChange",
                params: [
                    "textDocument": [
                        "uri": standardized.absoluteString,
                        "version": nextVersion
                    ],
                    "contentChanges": [["text": text]]
                ]
            )
        } else {
            openDocumentVersions[standardized] = 1
            send(
                method: "textDocument/didOpen",
                params: [
                    "textDocument": [
                        "uri": standardized.absoluteString,
                        "languageId": languageId,
                        "version": 1,
                        "text": text
                    ]
                ]
            )
        }
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            handleServerMessage(method: method, message: message)
            return
        }

        guard let id = Self.numericID(message["id"]) else { return }
        if id == initializeRequestID {
            initializeRequestID = nil
            if let result = message["result"] as? [String: Any],
               let capabilities = result["capabilities"] as? [String: Any],
               let encoding = capabilities["positionEncoding"] as? String {
                positionEncoding = encoding.lowercased()
            }
            send(method: "initialized", params: [:])
            state = .ready
            resolveInitContinuations(success: true)
            return
        }

        if id == shutdownRequestID {
            shutdownRequestID = nil
            send(method: "exit", params: [:])
            terminateProcess()
            return
        }

        if let pending = pendingCompletions.removeValue(forKey: id) {
            let suggestions = message["error"] == nil
                ? Self.completionSuggestions(from: message, text: pending.text, positionEncoding: positionEncoding)
                : []
            pending.continuation.resume(returning: suggestions)
            return
        }

        if let pending = pendingFormatting.removeValue(forKey: id) {
            let formatted = message["error"] == nil
                ? Self.formattedText(from: message, text: pending.text, positionEncoding: positionEncoding)
                : nil
            pending.continuation.resume(returning: formatted)
            return
        }
    }

    private func handleServerMessage(method: String, message: [String: Any]) {
        guard let id = message["id"] else { return }
        switch method {
        case "workspace/configuration":
            let itemCount = ((message["params"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
            sendResponse(id: id, result: Array(repeating: NSNull(), count: itemCount))
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
            sendResponse(id: id, result: NSNull())
        default:
            sendMethodNotFound(id: id)
        }
    }

    private func sendResponse(id: Any, result: Any) {
        sendPayload(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendMethodNotFound(id: Any) {
        sendPayload([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32601, "message": "Method not supported by RollCode"]
        ])
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard state != .stopped,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let stdin = stdinHandle else { return }
        let header = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        do {
            try stdin.write(contentsOf: header + data)
        } catch {
            lspLogger.error("Language server write failed: \(error.localizedDescription, privacy: .private)")
            serverDidExit()
        }
    }

    private func resolveInitContinuations(success: Bool) {
        let continuations = initContinuations
        initContinuations.removeAll()
        continuations.forEach { $0.resume(returning: success) }
    }

    private func terminateProcess() {
        state = .stopped
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func serverDidExit() {
        guard state != .stopped else { return }
        terminateProcess()
        resolveInitContinuations(success: false)
    }

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func send(method: String, id: Int? = nil, params: [String: Any]) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        if let id {
            payload["id"] = id
        }
        sendPayload(payload)
    }

    // MARK: - Public Utility Parsers

    nonisolated public static func extractMessage(from buffer: inout Data) -> [String: Any]? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let contentLength = headerString
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
        guard let contentLength else { return nil }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else { return nil }

        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    nonisolated public static func completionSuggestions(
        from message: [String: Any],
        text: String,
        positionEncoding: String = "utf-16"
    ) -> [LSPCompletionItem] {
        let items: [[String: Any]]
        if let directItems = message["result"] as? [[String: Any]] {
            items = directItems
        } else if let list = message["result"] as? [String: Any],
                  let listItems = list["items"] as? [[String: Any]] {
            items = listItems
        } else {
            return []
        }

        var seen = Set<String>()
        return items.compactMap { item in
            guard let label = item["label"] as? String, !label.isEmpty else { return nil }
            let textEdit = item["textEdit"] as? [String: Any]
            let rawInsertText = (textEdit?["newText"] as? String)
                ?? (item["textEditText"] as? String)
                ?? (item["insertText"] as? String)
                ?? label
            let insertText = (item["insertTextFormat"] as? NSNumber)?.intValue == 2
                ? plainText(fromSnippet: rawInsertText)
                : rawInsertText
            let rangeJSON = (textEdit?["replace"] as? [String: Any])
                ?? (textEdit?["range"] as? [String: Any])
            let replacementRange = rangeJSON.flatMap {
                nsRange(from: $0, in: text, positionEncoding: positionEncoding)
            }
            let key = label + "\u{0}" + insertText
            guard seen.insert(key).inserted else { return nil }
            return LSPCompletionItem(
                label: label,
                insertText: insertText,
                filterText: item["filterText"] as? String,
                detail: item["detail"] as? String,
                replacementRange: replacementRange
            )
        }
    }

    nonisolated public static func formattedText(
        from message: [String: Any],
        text: String,
        positionEncoding: String = "utf-16"
    ) -> String? {
        guard let edits = message["result"] as? [[String: Any]] else { return nil }
        let replacements = edits.compactMap { edit -> (NSRange, String)? in
            guard let range = edit["range"] as? [String: Any],
                  let nsRange = nsRange(from: range, in: text, positionEncoding: positionEncoding),
                  let newText = edit["newText"] as? String else { return nil }
            return (nsRange, newText)
        }
        guard replacements.count == edits.count else { return nil }

        let mutableText = NSMutableString(string: text)
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            mutableText.replaceCharacters(in: range, with: replacement)
        }
        return mutableText as String
    }

    nonisolated public static func characterOffset(
        in text: String,
        line: Int,
        utf16Character: Int,
        positionEncoding: String
    ) -> Int {
        guard let lineText = lineText(in: text, line: line) else { return utf16Character }
        let utf16Limit = min(max(0, utf16Character), lineText.utf16.count)
        let prefix = String(decoding: Array(lineText.utf16.prefix(utf16Limit)), as: UTF16.self)
        switch positionEncoding.lowercased() {
        case "utf-8": return prefix.utf8.count
        case "utf-32": return prefix.unicodeScalars.count
        default: return utf16Limit
        }
    }

    nonisolated private static func nsRange(
        from json: [String: Any],
        in text: String,
        positionEncoding: String
    ) -> NSRange? {
        guard let start = json["start"] as? [String: Any],
              let end = json["end"] as? [String: Any],
              let startOffset = utf16Offset(from: start, in: text, positionEncoding: positionEncoding),
              let endOffset = utf16Offset(from: end, in: text, positionEncoding: positionEncoding),
              endOffset >= startOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    nonisolated private static func utf16Offset(
        from position: [String: Any],
        in text: String,
        positionEncoding: String
    ) -> Int? {
        guard let line = (position["line"] as? NSNumber)?.intValue,
              let character = (position["character"] as? NSNumber)?.intValue,
              let lineRange = lineRange(in: text, line: line),
              let lineText = lineText(in: text, line: line) else { return nil }

        let utf16Character: Int
        switch positionEncoding.lowercased() {
        case "utf-8":
            utf16Character = utf16Count(in: lineText, codeUnitLimit: character, encoding: .utf8)
        case "utf-32":
            utf16Character = utf16Count(in: lineText, codeUnitLimit: character, encoding: .utf32)
        default:
            utf16Character = min(max(0, character), lineText.utf16.count)
        }
        return lineRange.location + utf16Character
    }

    private func lspPosition(in text: String, line: Int, character: Int) -> (line: Int, character: Int) {
        let zeroLine = max(0, line - 1)
        guard let targetRange = Self.lineRange(in: text, line: zeroLine) else {
            return (zeroLine, max(0, character))
        }
        let nsText = text as NSString
        let clampedUTF16 = min(max(0, character), targetRange.length)
        let prefixText = nsText.substring(with: NSRange(location: targetRange.location, length: clampedUTF16))

        switch positionEncoding {
        case "utf-8":
            return (zeroLine, prefixText.utf8.count)
        case "utf-32":
            return (zeroLine, prefixText.unicodeScalars.count)
        default:
            return (zeroLine, clampedUTF16)
        }
    }

    private enum PositionUnitEncoding {
        case utf8
        case utf32
    }

    nonisolated private static func utf16Count(
        in text: String,
        codeUnitLimit: Int,
        encoding: PositionUnitEncoding
    ) -> Int {
        var consumed = 0
        var utf16Count = 0
        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let units = encoding == .utf8 ? scalarText.utf8.count : 1
            guard consumed + units <= max(0, codeUnitLimit) else { break }
            consumed += units
            utf16Count += scalarText.utf16.count
        }
        return utf16Count
    }

    nonisolated private static func lineText(in text: String, line: Int) -> String? {
        guard let range = lineRange(in: text, line: line) else { return nil }
        let nsText = text as NSString
        var length = range.length
        while length > 0 {
            let character = nsText.character(at: range.location + length - 1)
            guard character == 10 || character == 13 else { break }
            length -= 1
        }
        return nsText.substring(with: NSRange(location: range.location, length: length))
    }

    nonisolated public static func lineRange(in text: String, line targetLine: Int) -> NSRange? {
        guard targetLine >= 0 else { return nil }
        let nsText = text as NSString
        var line = 0
        var location = 0
        while line < targetLine, location < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            line += 1
        }
        guard line == targetLine, location <= nsText.length else { return nil }
        return nsText.lineRange(for: NSRange(location: location, length: 0))
    }

    nonisolated private static func plainText(fromSnippet snippet: String) -> String {
        var result = snippet
        if let placeholder = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            result = placeholder.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1"
            )
        }
        if let tabStops = try? NSRegularExpression(pattern: #"\$\{?\d+\}?"#) {
            result = tabStops.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        return result
    }

    nonisolated private static func numericID(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String, let intValue = Int(str) { return intValue }
        return nil
    }
}
