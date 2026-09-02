import Foundation

struct AgentMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    let text: String
}

struct AgentActivity: Identifiable, Equatable {
    enum State {
        case running
        case completed
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

struct CodexEventUpdate: Equatable {
    var threadID: String?
    var message: String?
    var activity: AgentActivity?
    var changedFiles: [String] = []
    var usage: String?
    var error: String?
}

struct WorkspaceSnapshot: Equatable {
    struct Fingerprint: Equatable {
        let modificationDate: Date?
        let size: Int?
    }

    let files: [String: Fingerprint]

    static func capture(at rootURL: URL) -> WorkspaceSnapshot {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let excludedDirectories: Set<String> = [".git", ".build", "DerivedData", "node_modules"]
        guard let enumerator = FileManager.default.enumerator(atPath: rootURL.path) else {
            return WorkspaceSnapshot(files: [:])
        }

        var files: [String: Fingerprint] = [:]
        while let relativePath = enumerator.nextObject() as? String {
            let url = rootURL.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            files[relativePath] = Fingerprint(
                modificationDate: values.contentModificationDate,
                size: values.fileSize
            )
        }
        return WorkspaceSnapshot(files: files)
    }

    func changedFiles(comparedTo newer: WorkspaceSnapshot) -> [String] {
        Set(files.keys).union(newer.files.keys)
            .filter { files[$0] != newer.files[$0] }
            .sorted()
    }
}

enum CodexEventParser {
    static func parse(_ line: String) -> CodexEventUpdate? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any],
              let eventType = event["type"] as? String else { return nil }

        switch eventType {
        case "thread.started":
            return CodexEventUpdate(threadID: event["thread_id"] as? String)
        case "turn.completed":
            return CodexEventUpdate(usage: usageDescription(event["usage"] as? [String: Any]))
        case "turn.failed", "error":
            return CodexEventUpdate(error: errorDescription(event))
        case "item.started", "item.updated", "item.completed":
            guard let item = event["item"] as? [String: Any] else { return nil }
            return parseItem(item, eventType: eventType)
        default:
            return nil
        }
    }

    private static func parseItem(_ item: [String: Any], eventType: String) -> CodexEventUpdate? {
        let itemType = item["type"] as? String ?? "activity"
        let identifier = item["id"] as? String ?? UUID().uuidString
        let state = activityState(item["status"] as? String, eventType: eventType)

        switch itemType {
        case "agent_message":
            guard eventType == "item.completed", let text = item["text"] as? String, !text.isEmpty else { return nil }
            return CodexEventUpdate(message: text)
        case "reasoning":
            let text = truncated(item["text"] as? String ?? "Thinking")
            return CodexEventUpdate(activity: AgentActivity(
                id: identifier,
                title: "Reasoning",
                detail: text,
                state: state
            ))
        case "command_execution":
            let command = item["command"] as? String ?? "Running command"
            let output = truncated(item["aggregated_output"] as? String ?? "")
            return CodexEventUpdate(activity: AgentActivity(
                id: identifier,
                title: command,
                detail: output,
                state: state
            ))
        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let detail = changes.compactMap { change -> String? in
                guard let path = change["path"] as? String else { return nil }
                let kind = change["kind"] as? String ?? "update"
                return "\(kind) · \(path)"
            }.joined(separator: "\n")
            return CodexEventUpdate(
                activity: AgentActivity(
                    id: identifier,
                    title: paths.count == 1 ? "Changed 1 file" : "Changed \(paths.count) files",
                    detail: detail,
                    state: state
                ),
                changedFiles: paths
            )
        case "mcp_tool_call":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            return CodexEventUpdate(activity: AgentActivity(
                id: identifier,
                title: "\(server) · \(tool)",
                detail: truncated(stringValue(item["result"]) ?? ""),
                state: state
            ))
        case "web_search":
            return CodexEventUpdate(activity: AgentActivity(
                id: identifier,
                title: "Web search",
                detail: item["query"] as? String ?? "",
                state: state
            ))
        case "error":
            return CodexEventUpdate(error: item["message"] as? String ?? "Codex reported an error.")
        default:
            return nil
        }
    }

    private static func activityState(_ rawValue: String?, eventType: String) -> AgentActivity.State {
        if rawValue == "failed" { return .failed }
        if rawValue == "completed" || eventType == "item.completed" { return .completed }
        return .running
    }

    private static func usageDescription(_ usage: [String: Any]?) -> String? {
        guard let usage else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        return "\(input) input · \(cached) cached · \(output) output"
    }

    private static func errorDescription(_ event: [String: Any]) -> String {
        if let message = event["message"] as? String { return message }
        if let error = event["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = event["error"] as? String { return error }
        return "Codex could not complete the request."
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func truncated(_ text: String, limit: Int = 8_000) -> String {
        guard text.count > limit else { return text }
        return "…\n" + text.suffix(limit)
    }
}

@MainActor
final class AgentSession: ObservableObject {
    @Published var isVisible = true
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var activities: [AgentActivity] = []
    @Published private(set) var changedFiles: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var usageDescription: String?
    @Published private(set) var threadID: String?

    let executableURL: URL?
    var onRunCompleted: (() -> Void)?

    private var process: Process?
    private var standardOutput: Pipe?
    private var standardError: Pipe?
    private var outputBuffer = ""
    private var errorBuffer = ""
    private var workspaceURL: URL?
    private var baselineSnapshot: WorkspaceSnapshot?
    private var wasStopped = false
    private var pendingThreadReset = false

    init(executableURL: URL? = CodexExecutableLocator.locate()) {
        self.executableURL = executableURL
    }

    var isAvailable: Bool { executableURL != nil }

    func send(_ prompt: String, in workspaceURL: URL, activeFileURL: URL? = nil) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, let executableURL else { return }

        messages.append(AgentMessage(role: .user, text: prompt))
        activities = []
        changedFiles = []
        usageDescription = nil
        outputBuffer = ""
        errorBuffer = ""
        self.workspaceURL = workspaceURL.standardizedFileURL
        baselineSnapshot = WorkspaceSnapshot.capture(at: workspaceURL)
        wasStopped = false

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL
        process.arguments = argumentsForCurrentThread()
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = standardInput
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "rollcode"
        process.environment = environment

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.consumeStandardOutput(text) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.appendStandardError(text) }
        }
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.finish(exitCode: finishedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.standardOutput = standardOutput
            self.standardError = standardError
            isRunning = true

            let contextualPrompt = makeContextualPrompt(prompt, activeFileURL: activeFileURL)
            try standardInput.fileHandleForWriting.write(contentsOf: Data(contextualPrompt.utf8))
            try standardInput.fileHandleForWriting.close()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            isRunning = false
            messages.append(AgentMessage(role: .system, text: "Could not start Codex: \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        wasStopped = true
        process.interrupt()
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.process === process, process?.isRunning == true else { return }
            process?.terminate()
        }
    }

    func newThread() {
        if isRunning {
            pendingThreadReset = true
            stop()
            return
        }
        resetThreadState()
    }

    private func resetThreadState() {
        threadID = nil
        messages = []
        activities = []
        changedFiles = []
        usageDescription = nil
    }

    private func argumentsForCurrentThread() -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--color", "never",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check",
            "--config", "approval_policy=\"never\""
        ]
        if let threadID {
            arguments += ["resume", threadID]
        }
        arguments.append("-")
        return arguments
    }

    private func makeContextualPrompt(_ prompt: String, activeFileURL: URL?) -> String {
        var context = "You are running inside RollCode. Apply requested file changes directly. All workspace edits are pre-approved. Do not commit or push unless explicitly requested."
        if let activeFileURL, let workspaceURL {
            let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
            let path = activeFileURL.path.hasPrefix(root)
                ? String(activeFileURL.path.dropFirst(root.count))
                : activeFileURL.path
            context += " The active editor file is \(path)."
        }
        return "\(context)\n\nUser request:\n\(prompt)"
    }

    private func consumeStandardOutput(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: "\n")
        outputBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty {
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: String) {
        guard let update = CodexEventParser.parse(line) else { return }
        if let threadID = update.threadID { self.threadID = threadID }
        if let message = update.message {
            messages.append(AgentMessage(role: .assistant, text: message))
        }
        if let activity = update.activity {
            if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index] = activity
            } else {
                activities.append(activity)
            }
        }
        for path in update.changedFiles {
            let normalized = relativePath(path)
            if !changedFiles.contains(normalized) { changedFiles.append(normalized) }
        }
        if let usage = update.usage { usageDescription = usage }
        if let error = update.error {
            messages.append(AgentMessage(role: .system, text: error))
        }
    }

    private func appendStandardError(_ text: String) {
        errorBuffer += text
        if errorBuffer.count > 20_000 {
            errorBuffer = String(errorBuffer.suffix(20_000))
        }
    }

    private func relativePath(_ path: String) -> String {
        guard let workspaceURL else { return path }
        let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func finish(exitCode: Int32) {
        guard process != nil else { return }
        if !outputBuffer.isEmpty {
            consumeLine(outputBuffer)
            outputBuffer = ""
        }
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        try? standardOutput?.fileHandleForReading.close()
        try? standardError?.fileHandleForReading.close()
        process = nil
        standardOutput = nil
        standardError = nil
        isRunning = false

        if let workspaceURL, let baselineSnapshot {
            let finalSnapshot = WorkspaceSnapshot.capture(at: workspaceURL)
            for path in baselineSnapshot.changedFiles(comparedTo: finalSnapshot) where !changedFiles.contains(path) {
                changedFiles.append(path)
            }
            changedFiles.sort()
        }
        self.baselineSnapshot = nil

        if wasStopped {
            messages.append(AgentMessage(role: .system, text: "Agent stopped."))
        } else if exitCode != 0 {
            let detail = errorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "Codex exited with code \(exitCode)." : detail
            messages.append(AgentMessage(role: .system, text: message))
        }
        onRunCompleted?()
        if pendingThreadReset {
            pendingThreadReset = false
            resetThreadState()
        }
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        for path in candidates {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }
}
