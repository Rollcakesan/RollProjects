import Foundation
import os

private let lspLogger = Logger(subsystem: "com.rollprojects.RollCode", category: "lsp")

@MainActor
final class LSPClient {
    private enum State {
        case starting
        case ready
        case stopping
        case stopped
    }

    let server: ResolvedLanguageServer
    let rootURL: URL

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
        let continuation: CheckedContinuation<[CodeCompletionSuggestion], Never>
    }

    private struct PendingFormatting {
        let text: String
        let continuation: CheckedContinuation<String?, Never>
    }

    var isRunning: Bool {
        state != .stopped && process?.isRunning == true
    }

    init?(server: ResolvedLanguageServer, rootURL: URL) {
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
            "clientInfo": ["name": "RollCode", "version": "0.1.0"],
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

    func ensureInitialized() async -> Bool {
        switch state {
        case .ready: return true
        case .stopping, .stopped: return false
        case .starting: break
        }

        let requestID = initializeRequestID
        return await withCheckedContinuation { continuation in
            initContinuations.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.state == .starting, self.initializeRequestID == requestID else { return }
                self.failInitialization()
            }
        }
    }

    func requestCompletions(
        url: URL,
        text: String,
        languageId: String,
        line: Int,
        character: Int
    ) async -> [CodeCompletionSuggestion] {
        guard isRunning else {
            lspLogger.debug("Ignoring completion request because the server is not running")
            return []
        }
        guard await ensureInitialized() else {
            lspLogger.error("Language server initialization failed before completion request")
            return []
        }
        syncDocument(url: url, text: text, languageId: languageId)

        let requestID = nextRequestID()
        let encodedCharacter = Self.characterOffset(
            in: text,
            line: max(0, line - 1),
            utf16Character: max(0, character),
            positionEncoding: positionEncoding
        )
        let params: [String: Any] = [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": [
                "line": max(0, line - 1),
                "character": encodedCharacter
            ]
        ]

        return await withCheckedContinuation { continuation in
            pendingCompletions[requestID] = PendingCompletion(text: text, continuation: continuation)
            send(method: "textDocument/completion", id: requestID, params: params)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                self?.cancelCompletion(requestID, notifyServer: true)
            }
        }
    }

    func requestFormatting(
        url: URL,
        text: String,
        languageId: String,
        tabWidth: Int
    ) async -> String? {
        guard isRunning, await ensureInitialized() else { return nil }
        syncDocument(url: url, text: text, languageId: languageId)

        let requestID = nextRequestID()
        let params: [String: Any] = [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "options": ["tabSize": tabWidth, "insertSpaces": true]
        ]
        return await withCheckedContinuation { continuation in
            pendingFormatting[requestID] = PendingFormatting(text: text, continuation: continuation)
            send(method: "textDocument/formatting", id: requestID, params: params)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                self?.cancelFormatting(requestID, notifyServer: true)
            }
        }
    }

    func closeDocument(_ url: URL) {
        let url = url.standardizedFileURL
        guard openDocumentVersions.removeValue(forKey: url) != nil else { return }
        sendNotification(
            method: "textDocument/didClose",
            params: ["textDocument": ["uri": url.absoluteString]]
        )
    }

    func stopServer() {
        guard state != .stopping, state != .stopped else { return }
        state = .stopping

        for url in openDocumentVersions.keys {
            sendNotification(
                method: "textDocument/didClose",
                params: ["textDocument": ["uri": url.absoluteString]]
            )
        }
        openDocumentVersions.removeAll()
        resumeInitialization(with: false)
        resumePendingCompletions()
        resumePendingFormatting()

        let requestID = nextRequestID()
        shutdownRequestID = requestID
        send(method: "shutdown", id: requestID)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, self.state == .stopping else { return }
            self.finishStopping()
        }
    }

    private func syncDocument(url: URL, text: String, languageId: String) {
        guard state == .ready else { return }
        let url = url.standardizedFileURL
        if let version = openDocumentVersions[url] {
            let nextVersion = version + 1
            openDocumentVersions[url] = nextVersion
            sendNotification(method: "textDocument/didChange", params: [
                "textDocument": ["uri": url.absoluteString, "version": nextVersion],
                "contentChanges": [["text": text]]
            ])
        } else {
            openDocumentVersions[url] = 1
            sendNotification(method: "textDocument/didOpen", params: [
                "textDocument": [
                    "uri": url.absoluteString,
                    "languageId": languageId,
                    "version": 1,
                    "text": text
                ]
            ])
        }
    }

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func send(method: String, id: Int, params: Any? = nil) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { payload["params"] = params }
        sendPayload(payload)
    }

    private func sendNotification(method: String, params: Any? = nil) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { payload["params"] = params }
        sendPayload(payload)
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

    nonisolated static func extractMessage(from buffer: inout Data) -> [String: Any]? {
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

    func handleIncomingMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            handleServerMessage(method: method, message: message)
            return
        }

        guard let id = Self.numericID(message["id"]) else { return }
        if id == initializeRequestID {
            handleInitializeResponse(message)
            return
        }
        if id == shutdownRequestID {
            finishStopping()
            return
        }
        if let pending = pendingCompletions.removeValue(forKey: id) {
            let suggestions = message["error"] == nil
                ? Self.completionSuggestions(from: message, text: pending.text, positionEncoding: positionEncoding)
                : []
            pending.continuation.resume(returning: suggestions)
            return
        }
        guard let pending = pendingFormatting.removeValue(forKey: id) else { return }
        let formattedText = message["error"] == nil
            ? Self.formattedText(from: message, text: pending.text, positionEncoding: positionEncoding)
            : nil
        pending.continuation.resume(returning: formattedText)
    }

    private func handleInitializeResponse(_ message: [String: Any]) {
        initializeRequestID = nil
        guard message["error"] == nil else {
            lspLogger.error("Language server returned an initialize error")
            failInitialization()
            return
        }
        if let result = message["result"] as? [String: Any],
           let capabilities = result["capabilities"] as? [String: Any],
           let encoding = capabilities["positionEncoding"] as? String {
            positionEncoding = encoding.lowercased()
        }
        state = .ready
        lspLogger.debug("Language server \(self.server.identifier, privacy: .public) is ready")
        sendNotification(method: "initialized", params: [:])
        resumeInitialization(with: true)
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

    private func failInitialization() {
        lspLogger.error("Language server initialization timed out or failed")
        initializeRequestID = nil
        state = .stopped
        resumeInitialization(with: false)
        resumePendingCompletions()
        resumePendingFormatting()
        terminateProcess()
    }

    private func resumeInitialization(with result: Bool) {
        let continuations = initContinuations
        initContinuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }

    private func cancelCompletion(_ id: Int, notifyServer: Bool) {
        guard let pending = pendingCompletions.removeValue(forKey: id) else { return }
        if notifyServer {
            sendNotification(method: "$/cancelRequest", params: ["id": id])
        }
        pending.continuation.resume(returning: [])
    }

    private func resumePendingCompletions() {
        let continuations = pendingCompletions.values.map(\.continuation)
        pendingCompletions.removeAll()
        continuations.forEach { $0.resume(returning: []) }
    }

    private func cancelFormatting(_ id: Int, notifyServer: Bool) {
        guard let pending = pendingFormatting.removeValue(forKey: id) else { return }
        if notifyServer {
            sendNotification(method: "$/cancelRequest", params: ["id": id])
        }
        pending.continuation.resume(returning: nil)
    }

    private func resumePendingFormatting() {
        let continuations = pendingFormatting.values.map(\.continuation)
        pendingFormatting.removeAll()
        continuations.forEach { $0.resume(returning: nil) }
    }

    private func finishStopping() {
        guard state == .stopping else { return }
        lspLogger.debug("Stopping language server \(self.server.identifier, privacy: .public)")
        shutdownRequestID = nil
        sendNotification(method: "exit")
        state = .stopped
        terminateProcess(after: .milliseconds(200))
    }

    private func serverDidExit() {
        guard state != .stopped else { return }
        lspLogger.debug("Language server \(self.server.identifier, privacy: .public) exited")
        state = .stopped
        resumeInitialization(with: false)
        resumePendingCompletions()
        resumePendingFormatting()
        clearProcessResources()
    }

    private func terminateProcess(after delay: Duration? = nil) {
        let process = process
        Task { @MainActor [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            if process?.isRunning == true { process?.terminate() }
            self?.clearProcessResources()
        }
    }

    private func clearProcessResources() {
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
    }

    nonisolated private static func numericID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
    }

    nonisolated static func completionSuggestions(
        from message: [String: Any],
        text: String,
        positionEncoding: String = "utf-16"
    ) -> [CodeCompletionSuggestion] {
        let result = message["result"]
        let items: [[String: Any]]
        if let list = result as? [[String: Any]] {
            items = list
        } else if let list = result as? [String: Any],
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
            return CodeCompletionSuggestion(
                label: label,
                insertText: insertText,
                filterText: item["filterText"] as? String,
                detail: item["detail"] as? String,
                replacementRange: replacementRange
            )
        }
    }

    nonisolated static func formattedText(
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

    nonisolated static func characterOffset(
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

    nonisolated private static func lineRange(in text: String, line targetLine: Int) -> NSRange? {
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
}

@MainActor
final class LSPManager {
    static let shared = LSPManager()

    private struct ClientKey: Hashable {
        let rootPath: String
        let serverProcessIdentifier: String
    }

    private var activeClients: [ClientKey: LSPClient] = [:]
    private var unavailableClients: Set<ClientKey> = []

    func requestCompletions(
        for language: CodeLanguage,
        url: URL,
        text: String,
        line: Int,
        character: Int,
        workspaceURL: URL? = nil
    ) async -> [CodeCompletionSuggestion] {
        let rootURL = (workspaceURL ?? url.deletingLastPathComponent()).standardizedFileURL
        guard let resolvedServer = LanguageServerConfig.resolve(for: language, documentURL: url),
              let client = client(for: resolvedServer, rootURL: rootURL) else { return [] }
        return await client.requestCompletions(
            url: url,
            text: text,
            languageId: resolvedServer.languageId,
            line: line,
            character: character
        )
    }

    func formatDocument(
        for language: CodeLanguage,
        url: URL,
        text: String,
        tabWidth: Int,
        workspaceURL: URL? = nil
    ) async -> String? {
        let rootURL = (workspaceURL ?? url.deletingLastPathComponent()).standardizedFileURL
        guard let resolvedServer = LanguageServerConfig.resolve(for: language, documentURL: url),
              let client = client(for: resolvedServer, rootURL: rootURL) else { return nil }
        return await client.requestFormatting(
            url: url,
            text: text,
            languageId: resolvedServer.languageId,
            tabWidth: tabWidth
        )
    }

    func activateWorkspace(_ workspaceURL: URL) {
        let rootPath = workspaceURL.standardizedFileURL.path
        let inactiveKeys = activeClients.keys.filter { $0.rootPath != rootPath }
        for key in inactiveKeys {
            activeClients.removeValue(forKey: key)?.stopServer()
        }
        unavailableClients = unavailableClients.filter { $0.rootPath == rootPath }
    }

    func closeDocument(_ url: URL) {
        for client in activeClients.values {
            client.closeDocument(url)
        }
    }

    func stopAllServers() {
        activeClients.values.forEach { $0.stopServer() }
        activeClients.removeAll()
        unavailableClients.removeAll()
    }

    private func client(for server: ResolvedLanguageServer, rootURL: URL) -> LSPClient? {
        let key = ClientKey(
            rootPath: rootURL.standardizedFileURL.path,
            serverProcessIdentifier: server.processIdentifier
        )
        if let existing = activeClients[key] {
            if existing.isRunning { return existing }
            activeClients.removeValue(forKey: key)
            unavailableClients.insert(key)
            return nil
        }
        guard !unavailableClients.contains(key),
              let client = LSPClient(server: server, rootURL: rootURL) else {
            unavailableClients.insert(key)
            return nil
        }
        activeClients[key] = client
        return client
    }
}
