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
    private(set) var entries: [AgentEntry] = []
    private(set) var threadID: String?
    private var runState = RunState.idle

    let auth: CodexAuthService
    @ObservationIgnored let executableURL: URL?
    var onRunCompleted: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored private var errorBuffer = ""
    @ObservationIgnored private var workspaceURL: URL?

    init(
        executableURL: URL? = CodexExecutableLocator.locate(),
        auth: CodexAuthService = CodexAuthService()
    ) {
        self.executableURL = executableURL
        self.auth = auth
    }

    var isAvailable: Bool { executableURL != nil }
    var isRunning: Bool { runState.process != nil }

    func send(_ prompt: String, in workspaceURL: URL, activeFileURL: URL? = nil) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, let executableURL else { return }

        entries.removeAll { entry in
            if case .message = entry { return false }
            return true
        }
        entries.append(.message(AgentMessage(role: .user, text: prompt)))
        errorBuffer = ""
        self.workspaceURL = workspaceURL.standardizedFileURL

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

        do {
            try process.run()
            runState = .running(process)
            monitor(process, standardOutput: standardOutput, standardError: standardError)

            let contextualPrompt = makeContextualPrompt(prompt, activeFileURL: activeFileURL)
            try standardInput.fileHandleForWriting.write(contentsOf: Data(contextualPrompt.utf8))
            try standardInput.fileHandleForWriting.close()
        } catch {
            runState = .idle
            entries.append(.message(AgentMessage(role: .system, text: "Could not start Codex: \(error.localizedDescription)")))
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

    private func resetThreadState() {
        threadID = nil
        entries = []
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

    private func monitor(_ process: Process, standardOutput: Pipe, standardError: Pipe) {
        let outputTask = Task { [weak self] in
            do {
                for try await line in standardOutput.fileHandleForReading.bytes.lines where !line.isEmpty {
                    self?.consume(CodexEventParser.parse(line))
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

    private func relativePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).relativePath(from: workspaceURL)
    }

    private func finish(_ process: Process, exitCode: Int32) async {
        guard runState.process === process else { return }
        let changedPaths: [String]
        if let workspaceURL {
            changedPaths = await Task.detached(priority: .utility) {
                (try? GitDiffService.changedPaths(in: workspaceURL)) ?? []
            }.value
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
            if lower.contains("unauthorized") || lower.contains("login") || lower.contains("authentication") {
                auth.refresh()
                message = "Codex authentication required. Please click 'Log In' or run 'codex login' in the terminal.\n(\(detail))"
            } else {
                message = detail.isEmpty ? "Codex exited with code \(exitCode)." : detail
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
