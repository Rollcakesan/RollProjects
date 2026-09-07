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
    nonisolated static let providerDefaultsKey = "RollCode_SelectedAIProvider"
    private(set) var selectedProvider: AgentProvider = .codex

    struct ProviderChannelState: Equatable, Sendable {
        let provider: AgentProvider
        var activeThread: AgentThread
        var threads: [AgentThread] = []
        var selectedModel: String
        var reasoningEffort: ReasoningEffort
        var promptDraft: String = ""

        mutating func archiveActiveThreadIfNeeded() {
            guard !activeThread.entries.isEmpty || activeThread.codexThreadID != nil else { return }
            activeThread.sanitize(for: provider)
            if let idx = threads.firstIndex(where: { $0.id == activeThread.id }) {
                threads[idx] = activeThread
            } else {
                threads.insert(activeThread, at: 0)
            }
        }

        mutating func mutateThread(id: UUID, _ block: (inout AgentThread) -> Void) -> Bool {
            if activeThread.id == id {
                block(&activeThread)
                activeThread.sanitize(for: provider)
                activeThread.updatedAt = Date()
                return true
            }
            if let idx = threads.firstIndex(where: { $0.id == id }) {
                block(&threads[idx])
                threads[idx].sanitize(for: provider)
                threads[idx].updatedAt = Date()
                return true
            }
            return false
        }
    }

    private var codexChannel: ProviderChannelState
    private var geminiChannel: ProviderChannelState

    private var currentChannel: ProviderChannelState {
        get {
            selectedProvider == .codex ? codexChannel : geminiChannel
        }
        set {
            if selectedProvider == .codex {
                codexChannel = newValue
            } else {
                geminiChannel = newValue
            }
        }
    }

    var threads: [AgentThread] {
        codexChannel.threads + geminiChannel.threads
    }

    var activeThread: AgentThread {
        get { currentChannel.activeThread }
        set {
            if selectedProvider == .codex {
                codexChannel.activeThread = newValue
            } else {
                geminiChannel.activeThread = newValue
            }
        }
    }

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

    var currentPromptDraft: String {
        get { currentChannel.promptDraft }
        set {
            if selectedProvider == .codex {
                codexChannel.promptDraft = newValue
            } else {
                geminiChannel.promptDraft = newValue
            }
        }
    }

    func mutateThread(id: UUID, _ block: (inout AgentThread) -> Void) {
        if codexChannel.mutateThread(id: id, block) { return }
        _ = geminiChannel.mutateThread(id: id, block)
    }

    let auth: CodexAuthService
    let geminiAuth: GeminiAuthService
    let modelCatalog: ModelCatalogService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let executableURL: URL?
    @ObservationIgnored let geminiExecutableURL: URL?
    var onRunCompleted: (@MainActor @Sendable () -> Void)?

    static let codexModelDefaultsKey = "RollCode_SelectedCodexModel"
    static let geminiModelDefaultsKey = "RollCode_SelectedGeminiModel"
    static let reasoningEffortDefaultsKey = "RollCode_SelectedReasoningEffort"

    var selectedCodexModel: String {
        get {
            let saved = defaults.string(forKey: Self.codexModelDefaultsKey)
            if let saved, !saved.isEmpty { return saved }
            return modelCatalog.defaultModelID(for: .codex)
        }
        set {
            defaults.set(newValue, forKey: Self.codexModelDefaultsKey)
            codexChannel.selectedModel = newValue
        }
    }

    var selectedGeminiModel: String {
        get {
            let saved = defaults.string(forKey: Self.geminiModelDefaultsKey)
            if let saved, !saved.isEmpty { return saved }
            return modelCatalog.defaultModelID(for: .gemini)
        }
        set {
            defaults.set(newValue, forKey: Self.geminiModelDefaultsKey)
            geminiChannel.selectedModel = newValue
        }
    }

    var selectedReasoningEffort: ReasoningEffort {
        get {
            if let raw = defaults.string(forKey: Self.reasoningEffortDefaultsKey),
               let effort = ReasoningEffort(rawValue: raw) {
                return effort
            }
            return .medium
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.reasoningEffortDefaultsKey)
            codexChannel.reasoningEffort = newValue
        }
    }

    var currentModel: String {
        get {
            if let m = currentChannel.activeThread.model, !m.isEmpty {
                return m
            }
            return currentChannel.selectedModel
        }
        set {
            setModel(newValue)
        }
    }

    func threads(for provider: AgentProvider) -> [AgentThread] {
        provider == .codex ? codexChannel.threads : geminiChannel.threads
    }

    var currentReasoningEffort: ReasoningEffort {
        get {
            if let r = currentChannel.activeThread.reasoningEffort, let effort = ReasoningEffort(rawValue: r) {
                return effort
            }
            return currentChannel.reasoningEffort
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
            codexChannel.activeThread.model = modelID
        } else {
            selectedGeminiModel = modelID
            geminiChannel.activeThread.model = modelID
        }
        saveCurrentThreads()
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        if selectedProvider == .codex {
            selectedReasoningEffort = effort
            codexChannel.activeThread.reasoningEffort = effort.rawValue
        } else {
            geminiChannel.reasoningEffort = effort
            geminiChannel.activeThread.reasoningEffort = effort.rawValue
        }
        saveCurrentThreads()
    }

    func refreshModelCatalog() async {
        let oauthToken = await geminiAuth.validOAuthAccessToken()
        await modelCatalog.refreshModels(
            geminiKey: geminiAuth.storedAPIKey,
            geminiOAuthToken: oauthToken
        )
    }

    @ObservationIgnored private var errorBuffer = ""
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored private var initialChangedPaths: Set<String> = []
    private(set) var turnStartTime: Date?
    private(set) var currentActivityTitle: String?
    private var activeTurnThreadID: UUID?

    var currentExecutionStatus: String {
        guard isRunning else { return "" }
        if let currentActivityTitle, !currentActivityTitle.isEmpty {
            return currentActivityTitle
        }
        return "Thinking…"
    }

    var liveTurnStartTime: Date? {
        turnStartTime
    }

    @ObservationIgnored let useAppServer: Bool

    init(
        executableURL: URL? = CodexExecutableLocator.locate(),
        geminiExecutableURL: URL? = GeminiExecutableLocator.locate(),
        auth: CodexAuthService = CodexAuthService(),
        geminiAuth: GeminiAuthService = GeminiAuthService(),
        modelCatalog: ModelCatalogService = ModelCatalogService(),
        defaults: UserDefaults = .standard,
        useAppServer: Bool = false,
        initialProvider: AgentProvider? = nil
    ) {
        self.executableURL = executableURL
        self.geminiExecutableURL = geminiExecutableURL
        self.auth = auth
        self.geminiAuth = geminiAuth
        self.modelCatalog = modelCatalog
        self.defaults = defaults
        self.useAppServer = useAppServer
        let restoredProvider = defaults.string(forKey: Self.providerDefaultsKey)
            .flatMap(AgentProvider.init(rawValue:))
        self.selectedProvider = initialProvider ?? restoredProvider ?? .codex

        let codexSaved = defaults.string(forKey: Self.codexModelDefaultsKey)
        let codexDefault = (codexSaved?.isEmpty == false) ? codexSaved! : modelCatalog.defaultModelID(for: .codex)

        let geminiSaved = defaults.string(forKey: Self.geminiModelDefaultsKey)
        let geminiDefault = (geminiSaved?.isEmpty == false) ? geminiSaved! : modelCatalog.defaultModelID(for: .gemini)

        let initialEffort: ReasoningEffort = defaults.string(forKey: Self.reasoningEffortDefaultsKey)
            .flatMap(ReasoningEffort.init(rawValue:)) ?? .medium

        self.codexChannel = ProviderChannelState(
            provider: .codex,
            activeThread: AgentThread(provider: .codex, model: codexDefault, reasoningEffort: initialEffort.rawValue),
            threads: [],
            selectedModel: codexDefault,
            reasoningEffort: initialEffort
        )
        self.geminiChannel = ProviderChannelState(
            provider: .gemini,
            activeThread: AgentThread(provider: .gemini, model: geminiDefault),
            threads: [],
            selectedModel: geminiDefault,
            reasoningEffort: .medium
        )

        sanitizeAllPersistedThreadFiles()

        Task { [weak self] in
            await self?.refreshModelCatalog()
        }
    }

    var isAvailable: Bool { currentExecutableURL != nil }
    var currentExecutableURL: URL? {
        selectedProvider == .codex ? executableURL : geminiExecutableURL
    }
    var isRunning: Bool { activeTurnThreadID != nil || runState.isRunning }

    func selectProvider(_ provider: AgentProvider) {
        guard selectedProvider != provider, !isRunning else { return }
        archiveCurrentThreadIfNeeded()
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: Self.providerDefaultsKey)
        errorBuffer = ""
        saveCurrentThreads()
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
        activeTurnThreadID = activeThread.id
        errorBuffer = ""
        self.turnStartTime = Date()
        self.currentActivityTitle = "Thinking…"
        self.activeThread.model = currentModel
        self.activeThread.reasoningEffort = currentReasoningEffort.rawValue
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.initialChangedPaths = Set((try? GitBridgeService.changedPaths(in: workspaceURL)) ?? [])
        saveCurrentThreads()

        let targetThreadID = activeThread.id
        activeTurnThreadID = targetThreadID
        turnStartTime = Date()
        currentActivityTitle = "Thinking…"

        let contextualPrompt = makeContextualPrompt(prompt, activeFileURL: activeFileURL)
        let provider = selectedProvider

        if provider == .codex && useAppServer {
            runCodexAppServerTurn(
                prompt: contextualPrompt,
                workspaceURL: workspaceURL,
                activeFileURL: activeFileURL,
                targetThreadID: targetThreadID
            )
            return
        }

        runProcessTurn(prompt: contextualPrompt, workspaceURL: workspaceURL, targetThreadID: targetThreadID, provider: provider)
    }

    private func runCodexAppServerTurn(
        prompt: String,
        workspaceURL: URL,
        activeFileURL: URL?,
        targetThreadID: UUID
    ) {
        let appServer = CodexAppServerClient.shared
        let model = currentModel.isEmpty ? nil : currentModel
        let effort = currentReasoningEffort.rawValue
        let cwd = workspaceURL.path

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var existingCodexThreadID: String?
                _ = self.codexChannel.mutateThread(id: targetThreadID) { existingCodexThreadID = $0.codexThreadID }
                let threadId: String
                if let existing = existingCodexThreadID, !existing.isEmpty {
                    threadId = existing
                } else {
                    threadId = try await appServer.startThread(cwd: cwd, model: model)
                    _ = self.codexChannel.mutateThread(id: targetThreadID) {
                        $0.codexThreadID = threadId
                    }
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
                        self.currentActivityTitle = "Responding…"
                        _ = self.codexChannel.mutateThread(id: targetThreadID) { thread in
                            if !messageAppended {
                                thread.entries.append(.message(AgentMessage(role: .assistant, text: delta, senderName: "CODEX")))
                                messageAppended = true
                            } else {
                                if let last = thread.entries.last, case .message(let msg) = last, msg.role == .assistant {
                                    let updated = AgentMessage(id: msg.id, role: .assistant, text: msg.text + delta, senderName: "CODEX")
                                    thread.entries[thread.entries.count - 1] = .message(updated)
                                } else {
                                    thread.entries.append(.message(AgentMessage(role: .assistant, text: delta, senderName: "CODEX")))
                                }
                            }
                        }
                    },
                    onUsage: { [weak self] usage in
                        guard let self else { return }
                        _ = self.codexChannel.mutateThread(id: targetThreadID) { thread in
                            thread.inputTokens += usage.inputTokens
                            thread.outputTokens += usage.outputTokens
                            thread.cachedTokens += usage.cachedTokens
                        }
                    },
                    onComplete: { [weak self] success, errorMessage in
                        guard let self else { return }
                        let stopped = if case .appServerStopping = self.runState { true } else { false }
                        let reset = if case .appServerStopping(_, _, let resetThread) = self.runState { resetThread } else { false }
                        Task { @MainActor [weak self] in
                            await self?.finalizeTurn(targetThreadID: targetThreadID, provider: .codex, stopped: stopped, success: success, errorMessage: errorMessage, resetThread: reset)
                        }
                    }
                )

                self.runState = .appServerRunning(threadId: threadId, turnId: turnId)
            } catch {
                self.logger.warning("Codex App Server failed (\(error.localizedDescription)), falling back to CLI execution")
                self.runProcessTurn(prompt: prompt, workspaceURL: workspaceURL, targetThreadID: targetThreadID, provider: .codex)
            }
        }
    }

    private func runProcessTurn(prompt: String, workspaceURL: URL, targetThreadID: UUID, provider: AgentProvider) {
        guard let executableURL = (provider == .codex ? executableURL : geminiExecutableURL) else { return }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL

        var environment = makeEnvironment(for: provider)

        if provider == .codex {
            process.arguments = argumentsForCurrentThread()
            environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "rollcode"
        } else {
            var geminiArgs = ["-p", prompt, "-y"]
            let model = geminiChannel.selectedModel
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
            logger.debug("Started \(provider.rawValue, privacy: .public) agent process")
            monitor(process, standardOutput: standardOutput, standardError: standardError, targetThreadID: targetThreadID, provider: provider)

            let inputHandle = standardInput.fileHandleForWriting
            if provider == .codex {
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
            activeTurnThreadID = nil
            logger.error("Could not start \(provider.rawValue, privacy: .public) agent: \(error.localizedDescription, privacy: .private)")
            mutateChannelThread(id: targetThreadID, provider: provider) {
                $0.entries.append(.message(AgentMessage(role: .system, text: "Could not start \(provider.rawValue): \(error.localizedDescription)")))
            }
        }
    }

    private func finalizeTurn(
        targetThreadID: UUID,
        provider: AgentProvider,
        stopped: Bool,
        success: Bool,
        errorMessage: String?,
        resetThread: Bool
    ) async {
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
            mutateChannelThread(id: targetThreadID, provider: provider) {
                $0.lastDurationSeconds = Date().timeIntervalSince(turnStartTime)
            }
        }
        turnStartTime = nil
        currentActivityTitle = nil
        runState = .idle
        activeTurnThreadID = nil

        mergeChangedFiles(changedPaths, targetThreadID: targetThreadID, provider: provider)

        if stopped {
            mutateChannelThread(id: targetThreadID, provider: provider) {
                $0.entries.append(.message(AgentMessage(role: .system, text: "Agent stopped.")))
            }
        } else if !success {
            let detail = (errorMessage ?? errorBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()
            let message: String
            if provider == .codex && (lower.contains("unauthorized") || lower.contains("login") || lower.contains("authentication")) {
                auth.refresh()
                message = "Codex authentication required. Please click 'Log In' or run 'codex login' in the terminal.\n(\(detail))"
            } else if provider == .gemini && (lower.contains("google_cloud_project") || lower.contains("license") || lower.contains("valid license") || lower.contains("login") || lower.contains("permission")) {
                message = "Gemini CLI authentication or project setup required:\n\(detail)\n\nTip: You can set GEMINI_API_KEY or configure a Google Cloud Project (GOOGLE_CLOUD_PROJECT)."
            } else {
                message = detail.isEmpty ? "\(provider.rawValue) turn finished with an error." : detail
            }
            mutateChannelThread(id: targetThreadID, provider: provider) {
                $0.entries.append(.message(AgentMessage(role: .system, text: message)))
            }
        }

        onRunCompleted?()
        saveCurrentThreads()
        if resetThread {
            if provider == .codex {
                codexChannel.activeThread = AgentThread(
                    provider: .codex,
                    model: codexChannel.selectedModel,
                    reasoningEffort: codexChannel.reasoningEffort.rawValue
                )
            } else {
                geminiChannel.activeThread = AgentThread(
                    provider: .gemini,
                    model: geminiChannel.selectedModel
                )
            }
            saveCurrentThreads()
        }
    }

    func stop() {
        stop(resetThread: false)
    }

    private func stop(resetThread: Bool) {
        currentActivityTitle = "Stopping…"
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
        case .idle:
            guard activeTurnThreadID != nil else { return }
            activeTurnThreadID = nil
            turnStartTime = nil
            currentActivityTitle = nil
            if resetThread {
                resetThreadState()
            }
        case .stopping, .appServerStopping:
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
        guard thread.id != activeThread.id, !isRunning else { return }
        archiveCurrentThreadIfNeeded()

        let isCodex = (thread.provider == .codex || thread.codexThreadID != nil || (thread.model?.hasPrefix("gpt") == true) || (thread.model?.hasPrefix("o") == true))
        let targetProvider: AgentProvider = isCodex ? .codex : .gemini
        selectedProvider = targetProvider
        defaults.set(targetProvider.rawValue, forKey: Self.providerDefaultsKey)

        var sanitized = thread
        sanitized.sanitize(for: targetProvider)

        if targetProvider == .codex {
            if let m = sanitized.model, !m.isEmpty, !m.contains("gemini") {
                selectedCodexModel = m
            } else {
                sanitized.model = selectedCodexModel
            }
            if let r = sanitized.reasoningEffort, let effort = ReasoningEffort(rawValue: r) {
                selectedReasoningEffort = effort
            }
            codexChannel.activeThread = sanitized
        } else {
            sanitized.codexThreadID = nil
            if let m = sanitized.model, !m.isEmpty, !m.hasPrefix("gpt") && !m.hasPrefix("o") {
                selectedGeminiModel = m
            } else {
                sanitized.model = selectedGeminiModel
            }
            geminiChannel.activeThread = sanitized
        }
        errorBuffer = ""
        saveCurrentThreads()
    }

    func deleteThread(id: UUID) {
        guard !isRunning || activeThread.id != id else { return }
        codexChannel.threads.removeAll { $0.id == id }
        geminiChannel.threads.removeAll { $0.id == id }

        if codexChannel.activeThread.id == id {
            codexChannel.activeThread = codexChannel.threads.first ?? AgentThread(
                provider: .codex,
                model: codexChannel.selectedModel,
                reasoningEffort: codexChannel.reasoningEffort.rawValue
            )
        }
        if geminiChannel.activeThread.id == id {
            geminiChannel.activeThread = geminiChannel.threads.first ?? AgentThread(
                provider: .gemini,
                model: geminiChannel.selectedModel
            )
        }
        errorBuffer = ""
        saveCurrentThreads()
    }

    func resumePastCodexSession(_ session: CodexSessionSummary) {
        guard !isRunning else { return }
        archiveCurrentThreadIfNeeded()
        selectedProvider = .codex
        defaults.set(AgentProvider.codex.rawValue, forKey: Self.providerDefaultsKey)
        codexChannel.activeThread = AgentThread(
            provider: .codex,
            codexThreadID: session.id,
            title: session.displayTitle,
            updatedAt: session.updatedAt ?? Date(),
            entries: [.message(AgentMessage(role: .system, text: "Resumed Codex session: \(session.displayTitle)"))],
            model: codexChannel.selectedModel,
            reasoningEffort: codexChannel.reasoningEffort.rawValue
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

        struct SessionIndexItem: Decodable {
            let id: String
            let threadName: String
            let updatedAt: String?

            enum CodingKeys: String, CodingKey {
                case id
                case threadName = "thread_name"
                case updatedAt = "updated_at"
            }
        }

        var sessions: [CodexSessionSummary] = []
        let lines = content.components(separatedBy: .newlines).reversed()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()

        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let item = try? decoder.decode(SessionIndexItem.self, from: data) else { continue }

            let date = item.updatedAt.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            sessions.append(CodexSessionSummary(id: item.id, threadName: item.threadName, updatedAt: date))
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

    func storageFileURL(for workspaceURL: URL) -> URL {
        let pathData = workspaceURL.standardizedFileURL.path.data(using: .utf8) ?? Data()
        let pathHash = pathData.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return storageDirectoryURL.appendingPathComponent("\(pathHash).json")
    }

    func sanitizeAllPersistedThreadFiles() {
        let dir = storageDirectoryURL
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let threads = try? decoder.decode([AgentThread].self, from: data) else { continue }

            var needsUpdate = false
            var cleanThreads: [AgentThread] = []

            for mutThread in threads {
                var thread = mutThread
                let isCodex = thread.provider == .codex
                    || thread.codexThreadID != nil
                    || (thread.model?.hasPrefix("gpt") == true)
                    || (thread.model?.hasPrefix("o") == true)
                    || thread.entries.contains(where: {
                        if case .message(let m) = $0, m.senderName == "CODEX" { return true }
                        if case .activity = $0 { return true }
                        return false
                    })

                if isCodex {
                    if thread.provider != .codex { needsUpdate = true }
                    thread.sanitize(for: .codex)
                    cleanThreads.append(thread)
                } else {
                    if thread.provider != .gemini || thread.codexThreadID != nil { needsUpdate = true }
                    thread.sanitize(for: .gemini)
                    if let m = thread.model, m.hasPrefix("gpt") || m.hasPrefix("o") {
                        thread.model = geminiChannel.selectedModel
                        needsUpdate = true
                    }
                    cleanThreads.append(thread)
                }
            }

            if needsUpdate, let encoded = try? encoder.encode(cleanThreads) {
                try? encoded.write(to: fileURL, options: .atomic)
                logger.info("Sanitized contaminated thread storage at \(fileURL.lastPathComponent)")
            }
        }
    }

    func loadThreads(for workspaceURL: URL) {
        guard !isRunning else { return }
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

        var codexThreads: [AgentThread] = []
        var geminiThreads: [AgentThread] = []

        for mutThread in loadedThreads {
            var thread = mutThread
            let isCodex = thread.provider == .codex
                || thread.codexThreadID != nil
                || (thread.model?.hasPrefix("gpt") == true)
                || (thread.model?.hasPrefix("o") == true)
                || thread.entries.contains(where: {
                    if case .message(let m) = $0, m.senderName == "CODEX" { return true }
                    if case .activity = $0 { return true }
                    return false
                })

            if isCodex {
                thread.sanitize(for: .codex)
                codexThreads.append(thread)
            } else {
                thread.sanitize(for: .gemini)
                if let m = thread.model, m.hasPrefix("gpt") || m.hasPrefix("o") {
                    thread.model = geminiChannel.selectedModel
                }
                geminiThreads.append(thread)
            }
        }

        codexChannel.threads = codexThreads
        geminiChannel.threads = geminiThreads

        if let firstCodex = codexThreads.first {
            codexChannel.activeThread = firstCodex
        } else {
            codexChannel.activeThread = AgentThread(
                provider: .codex,
                model: codexChannel.selectedModel,
                reasoningEffort: codexChannel.reasoningEffort.rawValue
            )
        }

        if let firstGemini = geminiThreads.first {
            geminiChannel.activeThread = firstGemini
        } else {
            geminiChannel.activeThread = AgentThread(
                provider: .gemini,
                model: geminiChannel.selectedModel
            )
        }

        errorBuffer = ""
        saveCurrentThreads()
    }

    func saveCurrentThreads() {
        guard let workspaceURL else { return }
        archiveCurrentThreadIfNeeded()
        let fileURL = storageFileURL(for: workspaceURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        let cleanCodexThreads = codexChannel.threads.map { t -> AgentThread in
            var thread = t
            thread.sanitize(for: .codex)
            return thread
        }
        let cleanGeminiThreads = geminiChannel.threads.map { t -> AgentThread in
            var thread = t
            thread.sanitize(for: .gemini)
            if let m = thread.model, m.hasPrefix("gpt") || m.hasPrefix("o") {
                thread.model = geminiChannel.selectedModel
            }
            return thread
        }

        let allThreads = cleanCodexThreads + cleanGeminiThreads
        guard let data = try? encoder.encode(allThreads) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func resetThreadState() {
        archiveCurrentThreadIfNeeded()
        if selectedProvider == .codex {
            codexChannel.activeThread = AgentThread(
                provider: .codex,
                model: codexChannel.selectedModel,
                reasoningEffort: codexChannel.reasoningEffort.rawValue
            )
        } else {
            geminiChannel.activeThread = AgentThread(
                provider: .gemini,
                model: geminiChannel.selectedModel
            )
        }
        errorBuffer = ""
        saveCurrentThreads()
    }

    private func archiveCurrentThreadIfNeeded() {
        codexChannel.archiveActiveThreadIfNeeded()
        geminiChannel.archiveActiveThreadIfNeeded()
    }

    func argumentsForCurrentThread() -> [String] {
        let model = currentModel
        let reasoningEffort = currentReasoningEffort.rawValue

        if let threadID, !threadID.isEmpty {
            var arguments = [
                "exec",
                "resume",
                threadID,
                "--json",
                "--skip-git-repo-check",
                "--config", "approval_policy=\"never\""
            ]
            if !model.isEmpty {
                arguments += ["-m", model]
            }
            arguments += ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""]
            arguments.append("-")
            return arguments
        } else {
            var arguments = [
                "exec",
                "--json",
                "--color", "never",
                "--sandbox", "workspace-write",
                "--skip-git-repo-check",
                "--config", "approval_policy=\"never\""
            ]
            if !model.isEmpty {
                arguments += ["-m", model]
            }
            arguments += ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""]
            arguments.append("-")
            return arguments
        }
    }

    func makeContextualPrompt(_ prompt: String, activeFileURL: URL?) -> String {
        var context = "You are running inside RollCode. Apply requested file changes directly. All workspace edits are pre-approved. Do not commit or push unless explicitly requested."
        if let activeFileURL {
            context += " The active editor file is \(activeFileURL.relativePath(from: workspaceURL))."
        }

        // For Gemini (stateless CLI calls), inject past conversation history strictly from the Gemini active thread
        if selectedProvider == .gemini {
            let pastMessages = geminiChannel.activeThread.entries.compactMap { entry -> (role: String, text: String)? in
                guard case .message(let msg) = entry, msg.role != .system, msg.senderName != "CODEX" else { return nil }
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

    private func makeEnvironment(for provider: AgentProvider) -> [String: String] {
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

        if provider == .gemini {
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

    private func monitor(_ process: Process, standardOutput: Pipe, standardError: Pipe, targetThreadID: UUID, provider: AgentProvider) {
        let outputTask = Task { [weak self] in
            do {
                for try await line in standardOutput.fileHandleForReading.bytes.lines where !line.isEmpty {
                    if provider == .gemini {
                        self?.appendGeminiOutput(line, targetThreadID: targetThreadID)
                    } else {
                        self?.consume(CodexEventParser.parse(line), targetThreadID: targetThreadID)
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
            await self?.finish(process, exitCode: process.terminationStatus, targetThreadID: targetThreadID, provider: provider)
        }
    }

    private func consume(_ event: CodexEvent?, targetThreadID: UUID) {
        guard let event else { return }
        switch event {
        case .threadStarted(let threadID):
            currentActivityTitle = "Starting session…"
            _ = codexChannel.mutateThread(id: targetThreadID) {
                $0.codexThreadID = threadID
            }
        case .message(let text):
            currentActivityTitle = "Responding…"
            _ = codexChannel.mutateThread(id: targetThreadID) {
                $0.entries.append(.message(AgentMessage(role: .assistant, text: text, senderName: "CODEX")))
            }
        case .activity(let activity, let changedFiles):
            currentActivityTitle = activity.title
            upsertCodex(.activity(activity), targetThreadID: targetThreadID)
            mergeChangedFiles(changedFiles, targetThreadID: targetThreadID, provider: .codex)
        case .usage(let description):
            upsertCodex(.usage(description), targetThreadID: targetThreadID)
            if let parsed = AgentTokenUsage.parse(from: description) {
                _ = codexChannel.mutateThread(id: targetThreadID) {
                    $0.inputTokens += parsed.inputTokens
                    $0.outputTokens += parsed.outputTokens
                    $0.cachedTokens += parsed.cachedTokens
                }
            }
        case .error(let message):
            currentActivityTitle = nil
            _ = codexChannel.mutateThread(id: targetThreadID) {
                $0.entries.append(.message(AgentMessage(role: .system, text: message)))
            }
        }
    }

    private func upsertCodex(_ entry: AgentEntry, targetThreadID: UUID) {
        _ = codexChannel.mutateThread(id: targetThreadID) { thread in
            if let index = thread.entries.firstIndex(where: { $0.id == entry.id }) {
                thread.entries[index] = entry
            } else {
                thread.entries.append(entry)
            }
        }
    }

    private func mutateChannelThread(id: UUID, provider: AgentProvider, _ block: (inout AgentThread) -> Void) {
        if provider == .codex {
            _ = codexChannel.mutateThread(id: id, block)
        } else {
            _ = geminiChannel.mutateThread(id: id, block)
        }
    }

    private func mergeChangedFiles(_ paths: [String], targetThreadID: UUID, provider: AgentProvider) {
        guard !paths.isEmpty else { return }
        var existing: [String] = []
        mutateChannelThread(id: targetThreadID, provider: provider) { thread in
            existing = thread.entries.compactMap { entry -> [String]? in
                guard case .changes(let paths) = entry else { return nil }
                return paths
            }.first ?? []
        }
        let merged = Set(existing).union(paths.map(relativePath)).sorted()
        mutateChannelThread(id: targetThreadID, provider: provider) { thread in
            let entry = AgentEntry.changes(merged)
            if let index = thread.entries.firstIndex(where: { $0.id == entry.id }) {
                thread.entries[index] = entry
            } else {
                thread.entries.append(entry)
            }
        }
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

    private func appendGeminiOutput(_ text: String, targetThreadID: UUID) {
        let cleanText = Self.stripANSIEscapes(from: text).trimmingCharacters(in: .newlines)
        guard !cleanText.isEmpty else { return }
        currentActivityTitle = "Responding…"

        _ = geminiChannel.mutateThread(id: targetThreadID) { thread in
            if let last = thread.entries.last, case .message(let message) = last, message.role == .assistant {
                let updated = message.text + "\n" + cleanText
                thread.entries[thread.entries.count - 1] = .message(AgentMessage(role: .assistant, text: updated, senderName: "GEMINI"))
            } else {
                thread.entries.append(.message(AgentMessage(role: .assistant, text: cleanText, senderName: "GEMINI")))
            }
        }
    }

    private func relativePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).relativePath(from: workspaceURL)
    }

    private func finish(_ process: Process, exitCode: Int32, targetThreadID: UUID, provider: AgentProvider) async {
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
        default:
            return
        }
        logger.debug("\(provider.rawValue, privacy: .public) agent finished with exit code \(exitCode, privacy: .public)")
        await finalizeTurn(
            targetThreadID: targetThreadID,
            provider: provider,
            stopped: stopped,
            success: exitCode == 0,
            errorMessage: exitCode != 0 ? errorBuffer : nil,
            resetThread: resetThread
        )
    }
}
