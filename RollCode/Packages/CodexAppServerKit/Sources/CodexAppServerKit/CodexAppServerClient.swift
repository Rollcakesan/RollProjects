import Foundation
import os

/// High-performance, persistent JSON-RPC 2.0 client for communicating with `codex app-server --stdio`.
/// Supports full-duplex streaming, token metrics, thread lifecycles, and auto-approval of tool requests.
@MainActor
public final class CodexAppServerClient {
    public static let shared = CodexAppServerClient()

    private let logger = Logger(subsystem: "com.rollprojects.CodexAppServerKit", category: "client")

    public private(set) var status: CodexServerStatus = .stopped
    public var isReady: Bool { status == .ready }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    public struct JSONDictionary: @unchecked Sendable {
        public let raw: [String: Any]
        public init(_ raw: [String: Any] = [:]) { self.raw = raw }
        public subscript(key: String) -> Any? { raw[key] }
    }

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONDictionary, Error>] = [:]

    private var activeTurnDeltaHandlers: [String: (String) -> Void] = [:]
    private var activeTurnUsageHandlers: [String: (CodexTokenUsage) -> Void] = [:]
    private var activeTurnCompleteHandlers: [String: (Bool, String?) -> Void] = [:]
    private var fallbackTurnDeltaHandler: ((String) -> Void)?
    private var fallbackTurnUsageHandler: ((CodexTokenUsage) -> Void)?
    private var fallbackTurnCompleteHandler: ((Bool, String?) -> Void)?

    private var incomingBuffer = Data()

    public struct RPCError: LocalizedError {
        public let code: Int
        public let message: String
        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
        public var errorDescription: String? { "JSON-RPC Error (\(code)): \(message)" }
    }

    public init() {}

    deinit {
        if let process = process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Process Lifecycle

    /// Launches and initializes the `codex app-server` process over stdio if not already connected.
    public func startServerIfNeeded(executableURL: URL? = CodexExecutableLocator.locate()) async throws {
        if status == .ready, let process = process, process.isRunning {
            return
        }

        guard let exe = executableURL ?? CodexExecutableLocator.locate() else {
            status = .failed("Codex executable not found")
            throw RPCError(code: -32000, message: "Codex executable not found")
        }

        stopServer()
        status = .starting

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = exe
        proc.arguments = ["app-server", "--stdio"]

        var env = ProcessInfo.processInfo.environment
        env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "rollcode"
        proc.environment = env

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.handleProcessTerminated(exitCode: p.terminationStatus)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleIncomingData(data)
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdinPipe = stdin
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            logger.info("Launched codex app-server daemon (PID: \(proc.processIdentifier))")
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("Failed to launch codex app-server: \(error.localizedDescription)")
            throw error
        }

        // Perform JSON-RPC initialize handshake
        do {
            let initParams: [String: Any] = [
                "clientInfo": [
                    "name": "CodexAppServerKit",
                    "version": "1.0.0"
                ],
                "capabilities": [:]
            ]
            _ = try await sendRequest(method: "initialize", params: initParams)
            sendNotification(method: "initialized", params: nil)
            status = .ready
            logger.info("Codex app-server handshake completed successfully")
        } catch {
            stopServer()
            status = .failed("Initialize handshake failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Stops the server daemon and terminates active connections.
    public func stopServer() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        incomingBuffer.removeAll()

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RPCError(code: -32001, message: "Server stopped"))
        }
        pendingRequests.removeAll()
        activeTurnDeltaHandlers.removeAll()
        activeTurnUsageHandlers.removeAll()
        activeTurnCompleteHandlers.removeAll()
        fallbackTurnDeltaHandler = nil
        fallbackTurnUsageHandler = nil
        fallbackTurnCompleteHandler = nil
        status = .stopped
    }

    private func handleProcessTerminated(exitCode: Int32) {
        logger.warning("codex app-server process exited with code \(exitCode)")
        stopServer()
    }

    // MARK: - JSON-RPC Transport

    public func sendRequest(method: String, params: [String: Any]) async throws -> JSONDictionary {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw RPCError(code: -32002, message: "Server not running")
        }

        let reqId = nextRequestId
        nextRequestId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var lineData = data
        lineData.append(0x0A) // newline delimiter

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[reqId] = continuation
            do {
                try stdin.write(contentsOf: lineData)
            } catch {
                pendingRequests.removeValue(forKey: reqId)
                continuation.resume(throwing: error)
            }
        }
    }

    public func sendNotification(method: String, params: [String: Any]?) {
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params = params {
            payload["params"] = params
        }

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            var lineData = data
            lineData.append(0x0A)
            try? stdin.write(contentsOf: lineData)
        }
    }

    public func sendResponse(id: Any, result: [String: Any]) {
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            var lineData = data
            lineData.append(0x0A)
            try? stdin.write(contentsOf: lineData)
        }
    }

    // MARK: - Message Handling

    private func handleIncomingData(_ data: Data) {
        incomingBuffer.append(data)

        while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) {
            let lineData = incomingBuffer.subdata(in: incomingBuffer.startIndex..<newlineIndex)
            incomingBuffer.removeSubrange(incomingBuffer.startIndex...newlineIndex)

            guard !lineData.isEmpty else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any] else {
                continue
            }
            handleIncomingMessage(obj)
        }
    }

    private func handleIncomingMessage(_ json: [String: Any]) {
        let hasId = json["id"] != nil
        let hasMethod = json["method"] != nil

        if hasId && hasMethod {
            // Server-to-Client Request: handle tool approvals
            if let id = json["id"], let method = json["method"] as? String {
                logger.debug("Received server request: \(method, privacy: .public)")
                if method.contains("requestApproval") || method.contains("Approval") {
                    sendResponse(id: id, result: ["decision": "accept"])
                } else {
                    sendResponse(id: id, result: [:])
                }
            }
            return
        }

        if hasId {
            // Server-to-Client Response: fulfill pending request continuation
            if let idInt = json["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: idInt) {
                if let errObj = json["error"] as? [String: Any] {
                    let code = errObj["code"] as? Int ?? -1
                    let msg = errObj["message"] as? String ?? "Unknown error"
                    continuation.resume(throwing: RPCError(code: code, message: msg))
                } else {
                    let result = json["result"] as? [String: Any] ?? [:]
                    continuation.resume(returning: JSONDictionary(result))
                }
            }
            return
        }

        if let method = json["method"] as? String {
            // Server Notification
            let params = json["params"] as? [String: Any] ?? [:]
            handleServerNotification(method: method, params: params)
        }
    }

    private func handleServerNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                let turnId = params["turnId"] as? String
                if let turnId = turnId, let handler = activeTurnDeltaHandlers[turnId] {
                    handler(delta)
                } else {
                    fallbackTurnDeltaHandler?(delta)
                }
            }

        case "thread/tokenUsage/updated":
            if let usageDict = params["tokenUsage"] as? [String: Any] {
                let input = usageDict["inputTokens"] as? Int ?? 0
                let output = usageDict["outputTokens"] as? Int ?? 0
                let cached = usageDict["cachedInputTokens"] as? Int ?? 0
                let usage = CodexTokenUsage(inputTokens: input, cachedTokens: cached, outputTokens: output)

                let turnId = params["turnId"] as? String
                if let turnId = turnId, let handler = activeTurnUsageHandlers[turnId] {
                    handler(usage)
                } else {
                    fallbackTurnUsageHandler?(usage)
                }
            }

        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let turnId = turn?["id"] as? String ?? (params["turnId"] as? String)
            let statusStr = turn?["status"] as? String ?? "completed"
            let isSuccess = statusStr == "completed"

            var errorMsg: String?
            if let err = turn?["error"] as? [String: Any] {
                errorMsg = err["message"] as? String
            }

            if let turnId = turnId, let handler = activeTurnCompleteHandlers.removeValue(forKey: turnId) {
                activeTurnDeltaHandlers.removeValue(forKey: turnId)
                activeTurnUsageHandlers.removeValue(forKey: turnId)
                handler(isSuccess, errorMsg)
            } else {
                fallbackTurnCompleteHandler?(isSuccess, errorMsg)
            }

        default:
            break
        }
    }

    // MARK: - High-Level API

    /// Starts a new thread in the given working directory.
    public func startThread(cwd: String, model: String? = nil) async throws -> String {
        try await startServerIfNeeded()

        var params: [String: Any] = ["cwd": cwd]
        if let model = model, !model.isEmpty {
            params["model"] = model
        }

        let result = try await sendRequest(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any], let threadId = thread["id"] as? String else {
            throw RPCError(code: -32003, message: "No thread ID returned from thread/start")
        }
        return threadId
    }

    /// Resumes an existing thread.
    public func resumeThread(threadId: String, cwd: String) async throws {
        try await startServerIfNeeded()
        let params: [String: Any] = ["threadId": threadId, "cwd": cwd]
        _ = try await sendRequest(method: "thread/resume", params: params)
    }

    /// Starts an agent turn with real-time text streaming and token usage notifications.
    public func startTurn(
        threadId: String,
        prompt: String,
        model: String? = nil,
        effort: String? = nil,
        onDelta: @escaping (String) -> Void,
        onUsage: @escaping (CodexTokenUsage) -> Void,
        onComplete: @escaping (Bool, String?) -> Void
    ) async throws -> String {
        try await startServerIfNeeded()

        var params: [String: Any] = [
            "threadId": threadId,
            "input": [
                ["type": "text", "text": prompt]
            ],
            "approvalPolicy": "never"
        ]
        if let model = model, !model.isEmpty {
            params["model"] = model
        }
        if let effort = effort, !effort.isEmpty {
            params["effort"] = effort
        }

        self.fallbackTurnDeltaHandler = onDelta
        self.fallbackTurnUsageHandler = onUsage
        self.fallbackTurnCompleteHandler = onComplete

        let result = try await sendRequest(method: "turn/start", params: params)
        guard let turn = result["turn"] as? [String: Any], let turnId = turn["id"] as? String else {
            throw RPCError(code: -32004, message: "No turn ID returned from turn/start")
        }

        activeTurnDeltaHandlers[turnId] = onDelta
        activeTurnUsageHandlers[turnId] = onUsage
        activeTurnCompleteHandlers[turnId] = onComplete

        return turnId
    }

    /// Interrupts an ongoing turn on the server.
    public func interruptTurn(threadId: String, turnId: String) async throws {
        guard isReady else { return }
        let params: [String: Any] = ["threadId": threadId, "turnId": turnId]
        _ = try await sendRequest(method: "turn/interrupt", params: params)
    }

    /// Queries the app-server for its active list of models and reasoning support.
    public func listModels() async throws -> [CodexAppServerModel] {
        try await startServerIfNeeded()
        let result = try await sendRequest(method: "model/list", params: [:])
        guard let data = result["data"] as? [[String: Any]] else {
            return []
        }

        var models: [CodexAppServerModel] = []
        for item in data {
            guard let id = item["id"] as? String else { continue }
            let displayName = item["displayName"] as? String ?? id
            let reasoning = item["supportedReasoningEfforts"] as? [[String: Any]]
            let supportsReasoning = (reasoning != nil && !reasoning!.isEmpty)

            let speedTier: CodexModelSpeedTier
            let lower = id.lowercased()
            if lower.contains("mini") || lower.contains("flash") {
                speedTier = .fast
            } else if supportsReasoning || lower.contains("o3") || lower.contains("o1") || lower.contains("ultra") {
                speedTier = .deep
            } else {
                speedTier = .standard
            }

            models.append(CodexAppServerModel(
                id: id,
                displayName: displayName,
                speedTier: speedTier,
                supportsReasoningEffort: supportsReasoning
            ))
        }
        return models
    }
}
