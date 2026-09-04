import Foundation
import os
import Observation
#if canImport(GitBridgeKit)
import GitBridgeKit
#endif

@Observable

@MainActor
final class AgentSession {
    private let logger = Logger(subsystem: "com.rollprojects.RollCode", category: "agent")
    private enum RunState {
        case idle
        case running(Process)
        case stopping(Process, resetThread: Bool)
        case appServerRunning(threadId: String, turnId: String)
        case appServerStopping(threadId: String, turnId: String, resetThread: Bool)

        var process: Process? {
            switch self {
            case .idle, .appServerRunning, .appServerStopping: nil
            case .running(let process), .stopping(let process, _): process
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle: false
            case .running, .stopping, .appServerRunning, .appServerStopping: true
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
    let geminiAuth: GeminiAuthService
    let modelCatalog: ModelCatalogService
    @ObservationIgnored let executableURL: URL?
    @ObservationIgnored let geminiExecutableURL: URL?
    var onRunCompleted: (@MainActor @Sendable () -> Void)?

    static let codexModelDefaultsKey = "RollCode_SelectedCodexModel"
    static let geminiModelDefaultsKey = "RollCode_SelectedGeminiModel"
    static let reasoningEffortDefaultsKey = "RollCode_SelectedReasoningEffort"

    var selectedCodexModel: String {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.codexModelDefaultsKey)
            if let saved, !saved.isEmpty { return saved }
            return modelCatalog.defaultModelID(for: .codex)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.codexModelDefaultsKey)
        }
    }

    var selectedGeminiModel: String {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.geminiModelDefaultsKey)
            if let saved, !saved.isEmpty { return saved }
            return modelCatalog.defaultModelID(for: .gemini)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.geminiModelDefaultsKey)
        }
    }

    var selectedReasoningEffort: ReasoningEffort {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.reasoningEffortDefaultsKey),
               let effort = ReasoningEffort(rawValue: raw) {
                return effort
            }
            return .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.reasoningEffortDefaultsKey)
        }
    }

    var currentModel: String {
        get {
            if let threadModel = activeThread.model, !threadModel.isEmpty {
                return threadModel
            }
            return selectedProvider == .codex ? selectedCodexModel : selectedGeminiModel
        }
        set {
            setModel(newValue)
        }
    }

    var currentReasoningEffort: ReasoningEffort {
        get {
            if let r = activeThread.reasoningEffort, let effort = ReasoningEffort(rawValue: r) {
                return effort
            }
            return selectedReasoningEffort
        }
        set {
            setReasoningEffort(newValue)
        }
    }

    var lastTurnDuration: Double? {
        activeThread.lastDurationSeconds
    }

    var totalTokens: Int {
        activeThread.inputTokens + activeThread.outputTokens
    }

    func setModel(_ modelID: String) {
        if selectedProvider == .codex {
            selectedCodexModel = modelID
        } else {
            selectedGeminiModel = modelID
        }
        activeThread.model = modelID
        saveCurrentThreads()
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        selectedReasoningEffort = effort
        activeThread.reasoningEffort = effort.rawValue
        saveCurrentThreads()
    }

    func refreshModelCatalog() async {
        await modelCatalog.refreshModels(geminiKey: geminiAuth.storedAPIKey)
    }

    @ObservationIgnored private var errorBuffer = ""
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored private var initialChangedPaths: Set<String> = []
    @ObservationIgnored private var turnStartTime: Date?

    @ObservationIgnored let useAppServer: Bool

    init(
        executableURL: URL? = CodexExecutableLocator.locate(),
        geminiExecutableURL: URL? = GeminiExecutableLocator.locate(),
        auth: CodexAuthService = CodexAuthService(),
        geminiAuth: GeminiAuthService = GeminiAuthService(),
        modelCatalog: ModelCatalogService = ModelCatalogService(),
        useAppServer: Bool? = nil
    ) {
        self.executableURL = executableURL
        self.geminiExecutableURL = geminiExecutableURL
        self.auth = auth
        self.geminiAuth = geminiAuth
        self.modelCatalog = modelCatalog
        if let useAppServer {
            self.useAppServer = useAppServer
        } else {
            self.useAppServer = (executableURL == nil || executableURL == CodexExecutableLocator.locate())
        }
    }

    var isAvailable: Bool { currentExecutableURL != nil }
    var currentExecutableURL: URL? {
        selectedProvider == .codex ? executableURL : geminiExecutableURL
    }
    var isRunning: Bool { runState.isRunning }

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
        if activeThread.model == nil {
            activeThread.model = (new == .codex) ? selectedCodexModel : selectedGeminiModel
        }
        if activeThread.reasoningEffort == nil {
            activeThread.reasoningEffort = selectedReasoningEffort.rawValue
        }
        errorBuffer = ""
    }

    func send(_ prompt: String, in workspaceURL: URL, activeFileURL: URL? = nil) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, currentExecutableURL != nil else {
            logger.debug("Ignoring agent request because it is empty, already running, or unavailable")
            return
        }

        if activeThread.title == "New Thread" || activeThread.entries.isEmpty {
            activeThread.title = String(prompt.prefix(40))
        }

        entries.removeAll { entry in
            if case .message = entry { return false }
            return true
        }
        entries.append(.message(AgentMessage(role: .user, text: prompt)))
        errorBuffer = ""
        self.turnStartTime = Date()
        self.activeThread.model = currentModel
        self.activeThread.reasoningEffort = currentReasoningEffort.rawValue
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.initialChangedPaths = Set((try? GitBridgeService.changedPaths(in: workspaceURL)) ?? [])
        saveCurrentThreads()

        let contextualPrompt = makeContextualPrompt(prompt, activeFileURL: activeFileURL)

        if selectedProvider == .codex && useAppServer {
            runCodexAppServerTurn(
                prompt: contextualPrompt,
                workspaceURL: workspaceURL,
                activeFileURL: activeFileURL
            )
            return
        }

        runProcessTurn(prompt: contextualPrompt, workspaceURL: workspaceURL)
    }

    private func runCodexAppServerTurn(
        prompt: String,
        workspaceURL: URL,
        activeFileURL: URL?
    ) {
        let appServer = CodexAppServerClient.shared
        let model = currentModel.isEmpty ? nil : currentModel
        let effort = currentReasoningEffort.rawValue
        let cwd = workspaceURL.path

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let threadId: String
                if let existing = self.activeThread.codexThreadID, !existing.isEmpty {
                    threadId = existing
                } else {
                    threadId = try await appServer.startThread(cwd: cwd, model: model)
                    self.activeThread.codexThreadID = threadId
                    self.activeThread.updatedAt = Date()
                    self.saveCurrentThreads()
                }

                var messageAppended = false

                let turnId = try await appServer.startTurn(
                    threadId: threadId,
                    prompt: prompt,
                    model: model,
                    effort: effort,
                    onDelta: { [weak self] delta in
                        guard let self else { return }
                        if !messageAppended {
                            self.entries.append(.message(AgentMessage(role: .assistant, text: delta)))
                            messageAppended = true
                        } else {
                            if let last = self.entries.last, case .message(let msg) = last, msg.role == .assistant {
                                let updated = AgentMessage(id: msg.id, role: .assistant, text: msg.text + delta)
                                self.entries[self.entries.count - 1] = .message(updated)
                            } else {
                                self.entries.append(.message(AgentMessage(role: .assistant, text: delta)))
                            }
                        }
                    },
                    onUsage: { [weak self] usage in
                        guard let self else { return }
                        self.activeThread.inputTokens += usage.inputTokens
                        self.activeThread.outputTokens += usage.outputTokens
                        self.activeThread.cachedTokens += usage.cachedTokens
                    },
                    onComplete: { [weak self] success, errorMessage in
                        guard let self else { return }
                        let reset = if case .appServerStopping(_, _, let resetThread) = self.runState { resetThread } else { false }
                        self.completeAppServerTurn(success: success, errorMessage: errorMessage, resetThread: reset)
                    }
                )

                self.runState = .appServerRunning(threadId: threadId, turnId: turnId)
            } catch {
                self.logger.warning("Codex App Server failed (\(error.localizedDescription)), falling back to CLI execution")
                self.runProcessTurn(prompt: prompt, workspaceURL: workspaceURL)
            }
        }
    }

    private func runProcessTurn(prompt: String, workspaceURL: URL) {
        guard let executableURL = currentExecutableURL else { return }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL

        var environment = makeEnvironment()

        if selectedProvider == .codex {
            process.arguments = argumentsForCurrentThread()
            environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "rollcode"
        } else {
            var geminiArgs = ["-p", prompt, "-y"]
            let model = currentModel
            if !model.isEmpty {
                geminiArgs = ["-m", model] + geminiArgs
            }
            process.arguments = geminiArgs
        }
        process.environment = environment

        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = standardInput

        do {
            try process.run()
            runState = .running(process)
            logger.debug("Started \(self.selectedProvider.rawValue, privacy: .public) agent process")
            monitor(process, standardOutput: standardOutput, standardError: standardError)

            let inputHandle = standardInput.fileHandleForWriting
            if selectedProvider == .codex {
                let promptData = Data(prompt.utf8)
                Task.detached(priority: .userInitiated) {
                    do {
                        try inputHandle.write(contentsOf: promptData)
                        try inputHandle.close()
                    } catch {
                        try? inputHandle.close()
                    }
                }
            } else {
                try? inputHandle.close()
            }
        } catch {
            runState = .idle
            logger.error("Could not start \(self.selectedProvider.rawValue, privacy: .public) agent: \(error.localizedDescription, privacy: .private)")
            entries.append(.message(AgentMessage(role: .system, text: "Could not start \(selectedProvider.rawValue): \(error.localizedDescription)")))
        }
    }

    private func completeAppServerTurn(success: Bool, errorMessage: String?, resetThread: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let changedPaths: [String]
            if let workspaceURL {
                let current = await Task.detached(priority: .utility) {
                    (try? GitBridgeService.changedPaths(in: workspaceURL)) ?? []
                }.value
                changedPaths = current.filter { !self.initialChangedPaths.contains($0) }
            } else {
                changedPaths = []
            }

            if let turnStartTime {
                activeThread.lastDurationSeconds = Date().timeIntervalSince(turnStartTime)
            }
            turnStartTime = nil

            let stopped = if case .appServerStopping = runState { true } else { false }
            runState = .idle

            mergeChangedFiles(changedPaths)

            if stopped {
                entries.append(.message(AgentMessage(role: .system, text: "Agent stopped.")))
            } else if !success {
                let detail = (errorMessage ?? errorBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = detail.lowercased()
                let message: String
                if lower.contains("unauthorized") || lower.contains("login") || lower.contains("authentication") {
                    auth.refresh()
                    message = "Codex authentication required. Please click 'Log In' or run 'codex login' in the terminal.\n(\(detail))"
                } else {
                    message = detail.isEmpty ? "Codex turn finished with an error." : detail
                }
                entries.append(.message(AgentMessage(role: .system, text: message)))
            }

            onRunCompleted?()
            saveCurrentThreads()
            if resetThread {
                resetThreadState()
            }
        }
    }

    func stop() {
        stop(resetThread: false)
    }

    private func stop(resetThread: Bool) {
        switch runState {
        case .appServerRunning(let threadId, let turnId):
            runState = .appServerStopping(threadId: threadId, turnId: turnId, resetThread: resetThread)
            Task { @MainActor in
                try? await CodexAppServerClient.shared.interruptTurn(threadId: threadId, turnId: turnId)
            }
        case .running(let process):
            guard process.isRunning else { return }
            runState = .stopping(process, resetThread: resetThread)
            process.interrupt()
            Task { @MainActor [weak self, weak process] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.runState.process === process, process?.isRunning == true else { return }
                process?.terminate()
            }
        case .idle, .stopping, .appServerStopping:
            break
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
        selectedProvider = thread.provider
        if let m = thread.model, !m.isEmpty {
            if thread.provider == .codex {
                selectedCodexModel = m
            } else {
                selectedGeminiModel = m
            }
        }
        if let r = thread.reasoningEffort, let effort = ReasoningEffort(rawValue: r) {
            selectedReasoningEffort = effort
        }
        errorBuffer = ""
        saveCurrentThreads()
    }

    func deleteThread(id: UUID) {
        threads.removeAll { $0.id == id }
        if activeThread.id == id {
            if let first = threads.first {
                activeThread = first
                selectedProvider = first.provider
            } else {
                activeThread = AgentThread(provider: selectedProvider)
            }
            errorBuffer = ""
        }
        saveCurrentThreads()
    }

    func resumePastCodexSession(_ session: CodexSessionSummary) {
        if isRunning {
            stop(resetThread: false)
        }
        archiveCurrentThreadIfNeeded()
        selectedProvider = .codex
        activeThread = AgentThread(
            codexThreadID: session.id,
            title: session.displayTitle,
            updatedAt: session.updatedAt ?? Date(),
            entries: [.message(AgentMessage(role: .system, text: "Resumed Codex session: \(session.displayTitle)"))]
        )
        errorBuffer = ""
        saveCurrentThreads()
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

    private var storageDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rollCodeDir = appSupport.appendingPathComponent("RollCode/threads", isDirectory: true)
        try? FileManager.default.createDirectory(at: rollCodeDir, withIntermediateDirectories: true)
        return rollCodeDir
    }

    private func storageFileURL(for workspaceURL: URL) -> URL {
        let pathData = workspaceURL.standardizedFileURL.path.data(using: .utf8) ?? Data()
        let pathHash = pathData.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return storageDirectoryURL.appendingPathComponent("\(pathHash).json")
    }

    func loadThreads(for workspaceURL: URL) {
        if self.workspaceURL != nil && self.workspaceURL != workspaceURL.standardizedFileURL {
            saveCurrentThreads()
        }

        self.workspaceURL = workspaceURL.standardizedFileURL
        let fileURL = storageFileURL(for: workspaceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let loadedThreads = try? decoder.decode([AgentThread].self, from: data),
              !loadedThreads.isEmpty else {
            resetThreadState()
            return
        }

        self.threads = loadedThreads
        if let first = loadedThreads.first {
            self.activeThread = first
            self.selectedProvider = first.provider
            if first.provider == .codex {
                self.codexLatestThread = first
            } else {
                self.geminiLatestThread = first
            }
        }
        errorBuffer = ""
    }

    func saveCurrentThreads() {
        guard let workspaceURL else { return }
        archiveCurrentThreadIfNeeded()
        let fileURL = storageFileURL(for: workspaceURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(threads) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func resetThreadState() {
        archiveCurrentThreadIfNeeded()
        activeThread = AgentThread(
            provider: selectedProvider,
            model: selectedProvider == .codex ? selectedCodexModel : selectedGeminiModel,
            reasoningEffort: selectedReasoningEffort.rawValue
        )
        errorBuffer = ""
        saveCurrentThreads()
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
        let model = currentModel
        if !model.isEmpty {
            arguments += ["-m", model]
        }
        let info = modelCatalog.findModel(id: model, provider: .codex)
        if info?.supportsReasoningEffort == true || model.hasPrefix("o") || model.hasPrefix("gpt-5") {
            arguments += ["-c", "model_reasoning_effort=\"\(currentReasoningEffort.rawValue)\""]
        }
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

        // For Gemini (stateless CLI calls), inject past conversation history from the active thread
        if selectedProvider == .gemini {
            let pastMessages = activeThread.entries.compactMap { entry -> (role: String, text: String)? in
                guard case .message(let msg) = entry, msg.role != .system else { return nil }
                return (msg.role == .user ? "User" : "Assistant", msg.text)
            }
            let historySlice = pastMessages.suffix(6)
            if !historySlice.isEmpty {
                context += "\n\nConversation history so far:"
                for item in historySlice {
                    let truncatedText = item.text.count > 1000 ? String(item.text.prefix(1000)) + "…" : item.text
                    context += "\n[\(item.role)]: \(truncatedText)"
                }
            }
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

        if selectedProvider == .gemini {
            let key = geminiAuth.storedAPIKey
            if !key.isEmpty {
                env["GEMINI_API_KEY"] = key
            }
            if let project = geminiAuth.effectiveProjectID(for: workspaceURL), !project.isEmpty {
                env["GOOGLE_CLOUD_PROJECT"] = project
            }
        }
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
            await outputTask.value
            await errorTask.value
            process.waitUntilExit()
            await self?.finish(process, exitCode: process.terminationStatus)
        }
    }

    private func consume(_ event: CodexEvent?) {
        guard let event else { return }
        switch event {
        case .threadStarted(let threadID):
            self.threadID = threadID
        case .message(let text):
            entries.append(.message(AgentMessage(role: .assistant, text: text, senderName: "CODEX")))
        case .activity(let activity, let changedFiles):
            upsert(.activity(activity))
            mergeChangedFiles(changedFiles)
        case .usage(let description):
            upsert(.usage(description))
            if let parsed = AgentTokenUsage.parse(from: description) {
                activeThread.inputTokens += parsed.inputTokens
                activeThread.outputTokens += parsed.outputTokens
                activeThread.cachedTokens += parsed.cachedTokens
            }
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

    nonisolated static func stripANSIEscapes(from text: String) -> String {
        ANSIEscapeCleaner.stripEscapes(from: text)
    }

    private func appendGeminiOutput(_ text: String) {
        let cleanText = Self.stripANSIEscapes(from: text).trimmingCharacters(in: .newlines)
        guard !cleanText.isEmpty else { return }

        if let last = entries.last, case .message(let message) = last, message.role == .assistant {
            let updated = message.text + "\n" + cleanText
            entries[entries.count - 1] = .message(AgentMessage(role: .assistant, text: updated, senderName: "GEMINI"))
        } else {
            entries.append(.message(AgentMessage(role: .assistant, text: cleanText, senderName: "GEMINI")))
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
                (try? GitBridgeService.changedPaths(in: workspaceURL)) ?? []
            }.value
            changedPaths = current.filter { !self.initialChangedPaths.contains($0) }
        } else {
            changedPaths = []
        }
        guard runState.process === process else { return }

        if let turnStartTime {
            activeThread.lastDurationSeconds = Date().timeIntervalSince(turnStartTime)
        }
        turnStartTime = nil

        let stopped: Bool
        let resetThread: Bool
        switch runState {
        case .stopping(_, let shouldReset):
            stopped = true
            resetThread = shouldReset
        case .running:
            stopped = false
            resetThread = false
        case .idle, .appServerRunning, .appServerStopping:
            return
        }
        runState = .idle

        logger.debug("\(self.selectedProvider.rawValue, privacy: .public) agent finished with exit code \(exitCode, privacy: .public)")

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
            } else if selectedProvider == .gemini && (lower.contains("google_cloud_project") || lower.contains("license") || lower.contains("valid license") || lower.contains("login")) {
                message = "Gemini CLI authentication or project setup required:\n\(detail)\n\nTip: You can set GEMINI_API_KEY or configure a Google Cloud Project (GOOGLE_CLOUD_PROJECT)."
            } else {
                message = detail.isEmpty ? "\(selectedProvider.rawValue) exited with code \(exitCode)." : detail
            }
            entries.append(.message(AgentMessage(role: .system, text: message)))
        }
        onRunCompleted?()
        saveCurrentThreads()
        if resetThread {
            resetThreadState()
        }
    }
}
