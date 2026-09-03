import Foundation

@MainActor
final class SourceKitLSPService {
    static let shared = SourceKitLSPService()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var isInitialized = false
    private var requestIDCounter = 0
    private var initContinuations: [CheckedContinuation<Void, Never>] = []
    private var pendingContinuations: [Int: CheckedContinuation<[String], Never>] = [:]
    private var openDocumentVersions: [URL: Int] = [:]
    private let readQueue = DispatchQueue(label: "com.rollcode.sourcekit-lsp.reader")

    init() {
        startServer()
    }

    deinit {
        stopServer()
    }

    func startServer(rootURL: URL? = nil) {
        stopServer()

        let executablePath = "/usr/bin/sourcekit-lsp"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return
        }

        self.process = process
        self.stdinHandle = inPipe.fileHandleForWriting
        let stdout = outPipe.fileHandleForReading
        self.stdoutHandle = stdout

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
        }

        // Send initialize with lightweight rootUri to avoid scanning entire home dir
        let root = rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let initID = nextRequestID()
        let initParams: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "capabilities": [:]
        ]

        send(method: "initialize", id: initID, params: initParams)
    }

    nonisolated func stopServer() {
        Task { @MainActor in
            self.stdoutHandle?.readabilityHandler = nil
            self.stdoutHandle = nil

            for cont in self.initContinuations {
                cont.resume()
            }
            self.initContinuations.removeAll()

            for (_, continuation) in self.pendingContinuations {
                continuation.resume(returning: [])
            }
            self.pendingContinuations.removeAll()

            if let process = self.process, process.isRunning {
                process.terminate()
            }
            self.process = nil
            self.stdinHandle = nil
            self.isInitialized = false
            self.openDocumentVersions.removeAll()
        }
    }

    func ensureInitialized() async {
        guard !isInitialized else { return }
        await withCheckedContinuation { cont in
            initContinuations.append(cont)
        }
    }

    func syncDocument(url: URL, text: String) {
        guard process != nil else { return }

        if let version = openDocumentVersions[url] {
            let nextVersion = version + 1
            openDocumentVersions[url] = nextVersion
            let params: [String: Any] = [
                "textDocument": [
                    "uri": url.absoluteString,
                    "version": nextVersion
                ],
                "contentChanges": [
                    ["text": text]
                ]
            ]
            sendNotification(method: "textDocument/didChange", params: params)
        } else {
            openDocumentVersions[url] = 1
            let params: [String: Any] = [
                "textDocument": [
                    "uri": url.absoluteString,
                    "languageId": "swift",
                    "version": 1,
                    "text": text
                ]
            ]
            sendNotification(method: "textDocument/didOpen", params: params)
        }
    }

    func requestCompletions(url: URL, text: String, line: Int, character: Int) async -> [String] {
        guard process != nil else { return [] }
        await ensureInitialized()
        syncDocument(url: url, text: text)

        let reqID = nextRequestID()
        let params: [String: Any] = [
            "textDocument": [
                "uri": url.absoluteString
            ],
            "position": [
                "line": max(0, line - 1),
                "character": max(0, character)
            ]
        ]

        return await withCheckedContinuation { continuation in
            pendingContinuations[reqID] = continuation
            send(method: "textDocument/completion", id: reqID, params: params)

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2500))
                self.handleTimeout(for: reqID)
            }
        }
    }

    private func handleTimeout(for id: Int) {
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(returning: [])
        }
    }

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func send(method: String, id: Int, params: [String: Any]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        sendPayload(payload)
    }

    private func sendNotification(method: String, params: [String: Any]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        sendPayload(payload)
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let stdin = stdinHandle else { return }

        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }

        var messageData = Data()
        messageData.append(headerData)
        messageData.append(data)

        try? stdin.write(contentsOf: messageData)
    }

    nonisolated static func extractMessage(from buffer: inout Data) -> [String: Any]? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength: Int?
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    contentLength = len
                }
            }
        }

        guard let length = contentLength else { return nil }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + length

        guard buffer.count >= bodyEnd else { return nil }

        let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)

        guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return nil
        }
        return json
    }

    func handleIncomingMessage(_ message: [String: Any]) {
        let idVal = (message["id"] as? NSNumber)?.intValue ?? (message["id"] as? Int)

        if !isInitialized {
            isInitialized = true
            sendNotification(method: "initialized", params: [:])
            for cont in initContinuations {
                cont.resume()
            }
            initContinuations.removeAll()
        }

        if let id = idVal, let cont = pendingContinuations.removeValue(forKey: id) {
            var labels = [String]()
            if let result = message["result"] as? [String: Any],
               let items = result["items"] as? [[String: Any]] {
                for item in items {
                    if let label = item["label"] as? String {
                        let cleanLabel = label.components(separatedBy: "(").first ?? label
                        if !cleanLabel.isEmpty {
                            labels.append(cleanLabel)
                        }
                    }
                }
            }
            cont.resume(returning: Array(NSOrderedSet(array: labels).compactMap { $0 as? String }))
        }
    }
}
