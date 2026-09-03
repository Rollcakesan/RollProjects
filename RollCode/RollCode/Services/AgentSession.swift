import Foundation
import Observation

@Observable
@MainActor
final class AgentSession {
    private enum RunState {
        case idle
        case running(Process)
        case stopping(Process, resetThread: Bool)

        var process: Process? {
            switch self {
            case .idle: nil
            case .running(let process), .stopping(let process, _): process
            }
        }
    }

    var isVisible = true
    var selectedProvider: AgentProvider = .codex {
        didSet {
            guard selectedProvider != oldValue else { return }
            handleProviderChanged(from: oldValue, to: selectedProvider)
        }
    }

    private(set) var threads: [AgentThread] = []
    private(set) var activeThread = AgentThread(provider: .codex)
    private var codexLatestThread = AgentThread(provider: .codex)
    private var geminiLatestThread = AgentThread(provider: .gemini)
    private(set) var pastCodexSessions: [CodexSessionSummary] = []
    private var runState = RunState.idle

    var entries: [AgentEntry] {
        get { activeThread.entries }
        set {
            activeThread.entries = newValue
            activeThread.updatedAt = Date()
        }
    }

    var threadID: String? {
        get { activeThread.codexThreadID }
        set {
            activeThread.codexThreadID = newValue
            activeThread.updatedAt = Date()
        }
    }

    var activeThreadTitle: String { activeThread.title }

    let auth: CodexAuthService
    @ObservationIgnored let executableURL: URL?
    @ObservationIgnored let geminiExecutableURL: URL?
    var onRunCompleted: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored private var errorBuffer = ""
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored private var initialChangedPaths: Set<String> = []

    init(
        executableURL: URL? = CodexExecutableLocator.locate(),
        geminiExecutableURL: URL? = GeminiExecutableLocator.locate(),
        auth: CodexAuthService = CodexAuthService()
    ) {
        self.executableURL = executableURL
        self.geminiExecutableURL = geminiExecutableURL
        self.auth = auth
    }

    var isAvailable: Bool { currentExecutableURL != nil }
    var currentExecutableURL: URL? {
        selectedProvider == .codex ? executableURL : geminiExecutableURL
    }
    var isRunning: Bool { runState.process != nil }

    func selectProvider(_ provider: AgentProvider) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
    }

    private func handleProviderChanged(from old: AgentProvider, to new: AgentProvider) {
        if isRunning {
            stop(resetThread: false)
        }
        if old == .codex {
            codexLatestThread = activeThread
        } else {
            geminiLatestThread = activeThread
        }
        activeThread = (new == .codex) ? codexLatestThread : geminiLatestThread
        errorBuffer = ""
    }

    func send(_ prompt: String, in workspaceURL: URL, activeFileURL: URL? = nil) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, let executableURL = currentExecutableURL else { return }

        if activeThread.title == "New Thread" || activeThread.entries.isEmpty {
            activeThread.title = String(prompt.prefix(40))
        }

        entries.removeAll { entry in
            if case .message = entry { return false }
            return true
        }
        entries.append(.message(AgentMessage(role: .user, text: prompt)))
        errorBuffer = ""
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.initialChangedPaths = Set((try? GitDiffService.changedPaths(in: workspaceURL)) ?? [])

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL

        let contextualPrompt = makeContextualPrompt(prompt, activeFileURL: activeFileURL)
        var environment = makeEnvironment()

        if selectedProvider == .codex {
            process.arguments = argumentsForCurrentThread()
            environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "rollcode"
        } else {
            process.arguments = ["-p", contextualPrompt, "-y"]
        }
        process.environment = environment

        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = standardInput

        do {
            try process.run()
            runState = .running(process)
            monitor(process, standardOutput: standardOutput, standardError: standardError)

            if selectedProvider == .codex {
                try standardInput.fileHandleForWriting.write(contentsOf: Data(contextualPrompt.utf8))
                try standardInput.fileHandleForWriting.close()
            }
        } catch {
            runState = .idle
            entries.append(.message(AgentMessage(role: .system, text: "Could not start \(selectedProvider.rawValue): \(error.localizedDescription)")))
        }
    }

    func stop() {
        stop(resetThread: false)
    }

    private func stop(resetThread: Bool) {
        guard let process = runState.process, process.isRunning else { return }
        runState = .stopping(process, resetThread: resetThread)
        process.interrupt()
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.runState.process === process, process?.isRunning == true else { return }
            process?.terminate()
        }
    }

    func newThread() {
        if isRunning {
            stop(resetThread: true)
            return
        }
        resetThreadState()
    }

    func switchToThread(_ thread: AgentThread) {
        guard thread.id != activeThread.id else { return }
        if isRunning {
            stop(resetThread: false)
        }
        archiveCurrentThreadIfNeeded()
        activeThread = thread
        errorBuffer = ""
    }

    func deleteThread(id: UUID) {
        threads.removeAll { $0.id == id }
        if activeThread.id == id {
            if let first = threads.first {
                activeThread = first
            } else {
                activeThread = AgentThread()
            }
            errorBuffer = ""
        }
    }

    func resumePastCodexSession(_ session: CodexSessionSummary) {
        if isRunning {
            stop(resetThread: false)
        }
        archiveCurrentThreadIfNeeded()
        activeThread = AgentThread(
            codexThreadID: session.id,
            title: session.displayTitle,
            updatedAt: session.updatedAt ?? Date(),
            entries: [.message(AgentMessage(role: .system, text: "Resumed Codex session: \(session.displayTitle)"))]
        )
        errorBuffer = ""
    }

    func loadPastCodexSessions() {
        let sessionIndexURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/session_index.jsonl")
        guard FileManager.default.fileExists(atPath: sessionIndexURL.path),
              let content = try? String(contentsOf: sessionIndexURL, encoding: .utf8) else {
            pastCodexSessions = []
            return
        }

        var sessions: [CodexSessionSummary] = []
        let lines = content.components(separatedBy: .newlines).reversed()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let threadName = json["thread_name"] as? String else { continue }

            let dateString = json["updated_at"] as? String
            let date = dateString.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            sessions.append(CodexSessionSummary(id: id, threadName: threadName, updatedAt: date))
            if sessions.count >= 20 { break }
        }
        pastCodexSessions = sessions
    }

    private func resetThreadState() {
        archiveCurrentThreadIfNeeded()
        activeThread = AgentThread()
        errorBuffer = ""
    }

    private func archiveCurrentThreadIfNeeded() {
        guard !activeThread.entries.isEmpty || activeThread.codexThreadID != nil else { return }
        if let index = threads.firstIndex(where: { $0.id == activeThread.id }) {
            threads[index] = activeThread
        } else {
            threads.insert(activeThread, at: 0)
        }
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
        if let activeFileURL {
            context += " The active editor file is \(activeFileURL.relativePath(from: workspaceURL))."
        }
        return "\(context)\n\nUser request:\n\(prompt)"
    }

    private func makeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let additions = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        for path in additions.reversed() {
            if !paths.contains(path) {
                paths.insert(path, at: 0)
            }
        }
        env["PATH"] = paths.joined(separator: ":")
        return env
    }

    private func monitor(_ process: Process, standardOutput: Pipe, standardError: Pipe) {
        let isGemini = selectedProvider == .gemini
        let outputTask = Task { [weak self] in
            do {
                for try await line in standardOutput.fileHandleForReading.bytes.lines where !line.isEmpty {
                    if isGemini {
                        self?.appendGeminiOutput(line)
                    } else {
                        self?.consume(CodexEventParser.parse(line))
                    }
                }
            } catch {}
        }
        let errorTask = Task { [weak self] in
            do {
                for try await line in standardError.fileHandleForReading.bytes.lines {
                    self?.appendStandardError(line + "\n")
                }
            } catch {}
        }

        Task.detached(priority: .utility) { [weak self] in
            process.waitUntilExit()
            await outputTask.value
            await errorTask.value
            await self?.finish(process, exitCode: process.terminationStatus)
        }
    }

    private func consume(_ event: CodexEvent?) {
        guard let event else { return }
        switch event {
        case .threadStarted(let threadID):
            self.threadID = threadID
        case .message(let text):
            entries.append(.message(AgentMessage(role: .assistant, text: text)))
        case .activity(let activity, let changedFiles):
            upsert(.activity(activity))
            mergeChangedFiles(changedFiles)
        case .usage(let description):
            upsert(.usage(description))
        case .error(let message):
            entries.append(.message(AgentMessage(role: .system, text: message)))
        }
    }

    private func upsert(_ entry: AgentEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func mergeChangedFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let existing = entries.compactMap { entry -> [String]? in
            guard case .changes(let paths) = entry else { return nil }
            return paths
        }.first ?? []
        let merged = Set(existing).union(paths.map(relativePath)).sorted()
        upsert(.changes(merged))
    }

    private func appendStandardError(_ text: String) {
        errorBuffer += text
        if errorBuffer.count > 20_000 {
            errorBuffer = String(errorBuffer.suffix(20_000))
        }
    }

    private func appendGeminiOutput(_ text: String) {
        if let last = entries.last, case .message(let message) = last, message.role == .assistant {
            let updated = message.text + "\n" + text
            entries[entries.count - 1] = .message(AgentMessage(role: .assistant, text: updated))
        } else {
            entries.append(.message(AgentMessage(role: .assistant, text: text)))
        }
    }

    private func relativePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).relativePath(from: workspaceURL)
    }

    private func finish(_ process: Process, exitCode: Int32) async {
        guard runState.process === process else { return }
        let changedPaths: [String]
        if let workspaceURL {
            let current = await Task.detached(priority: .utility) {
                (try? GitDiffService.changedPaths(in: workspaceURL)) ?? []
            }.value
            changedPaths = current.filter { !self.initialChangedPaths.contains($0) }
        } else {
            changedPaths = []
        }
        guard runState.process === process else { return }

        let stopped: Bool
        let resetThread: Bool
        switch runState {
        case .stopping(_, let shouldReset):
            stopped = true
            resetThread = shouldReset
        case .running:
            stopped = false
            resetThread = false
        case .idle:
            return
        }
        runState = .idle

        mergeChangedFiles(changedPaths)

        if stopped {
            entries.append(.message(AgentMessage(role: .system, text: "Agent stopped.")))
        } else if exitCode != 0 {
            let detail = errorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()
            let message: String
            if selectedProvider == .codex && (lower.contains("unauthorized") || lower.contains("login") || lower.contains("authentication")) {
                auth.refresh()
                message = "Codex authentication required. Please click 'Log In' or run 'codex login' in the terminal.\n(\(detail))"
            } else {
                message = detail.isEmpty ? "\(selectedProvider.rawValue) exited with code \(exitCode)." : detail
            }
            entries.append(.message(AgentMessage(role: .system, text: message)))
        }
        onRunCompleted?()
        if resetThread {
            resetThreadState()
        }
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
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

enum GeminiExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/gemini" }
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
