import Foundation
import Observation
#if canImport(AIAgentKit)
import AIAgentKit
#endif

@Observable
@MainActor
final class TerminalInstance: Identifiable {
    let id: UUID
    var title: String
    var output: String = ""
    private(set) var isRunning: Bool = false
    private(set) var workingDirectory: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var inputPipe: Pipe?
    @ObservationIgnored private var commandHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?

    init(id: UUID = UUID(), title: String = "zsh", workingDirectory: URL? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }

    func start(in directory: URL) {
        stop()
        workingDirectory = directory
        output = "RollCode Terminal (\(title)) — \(directory.path)\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.currentDirectoryURL = directory
        process.arguments = ["-l", "-i"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["PS1"] = "❯ "
        environment["CLICOLOR"] = "1"
        process.environment = environment

        self.process = process
        self.inputPipe = inputPipe

        let readHandler: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendOutput(TerminalOutputCleaner.clean(text))
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = readHandler
        errorPipe.fileHandleForReading.readabilityHandler = readHandler

        process.terminationHandler = { [weak self] _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.process = nil
                self?.inputPipe = nil
                self?.appendOutput("\n[Shell exited]\n")
            }
        }

        do {
            try process.run()
            isRunning = true
        } catch {
            appendOutput("Could not start zsh: \(error.localizedDescription)\n")
        }
    }

    func send(_ command: String) {
        let command = command.trimmingCharacters(in: .newlines)
        guard !command.isEmpty else { return }
        remember(command)

        appendOutput("\(command)\n")

        guard write(command + "\n") else {
            appendOutput("\n[Shell is not running]\n")
            return
        }
    }

    func interrupt() {
        guard isRunning, let process else {
            appendOutput("\n[Shell is not running]\n")
            return
        }
        process.interrupt()
    }

    func clear() {
        output = ""
    }

    func previousCommand() -> String {
        guard !commandHistory.isEmpty else { return "" }
        let nextIndex = max((historyIndex ?? commandHistory.count) - 1, 0)
        historyIndex = nextIndex
        return commandHistory[nextIndex]
    }

    func nextCommand() -> String {
        guard let historyIndex else { return "" }
        let nextIndex = historyIndex + 1
        guard nextIndex < commandHistory.count else {
            self.historyIndex = nil
            return ""
        }
        self.historyIndex = nextIndex
        return commandHistory[nextIndex]
    }

    func restart() {
        start(in: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func stop() {
        process?.terminate()
        process = nil
        inputPipe = nil
        isRunning = false
    }

    private func remember(_ command: String) {
        if commandHistory.last != command {
            commandHistory.append(command)
            if commandHistory.count > 200 {
                commandHistory.removeFirst(commandHistory.count - 200)
            }
        }
        historyIndex = nil
    }

    private func write(_ text: String) -> Bool {
        guard isRunning, let inputPipe, let data = text.data(using: .utf8) else { return false }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            appendOutput("\n[Terminal write failed: \(error.localizedDescription)]\n")
            return false
        }
    }

    private func appendOutput(_ text: String) {
        output += text
        if output.count > 1_000_000 {
            output = String(output.suffix(750_000))
        }
    }

    deinit {
        process?.terminate()
    }
}

@Observable
@MainActor
final class TerminalSession: TerminalCommandExecuting {
    var isVisible = true
    private(set) var tabs: [TerminalInstance] = []
    var activeTabID: UUID?

    var activeTab: TerminalInstance? {
        if let activeTabID, let found = tabs.first(where: { $0.id == activeTabID }) {
            return found
        }
        return tabs.first
    }

    var output: String {
        get { activeTab?.output ?? "" }
        set { activeTab?.output = newValue }
    }

    var isRunning: Bool {
        activeTab?.isRunning ?? false
    }

    var workingDirectory: URL? {
        activeTab?.workingDirectory
    }

    init() {
        let initial = TerminalInstance(title: "Terminal 1")
        tabs = [initial]
        activeTabID = initial.id
    }

    @discardableResult
    func createTab(in directory: URL? = nil, title: String? = nil) -> TerminalInstance {
        let dir = directory ?? workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let tabNumber = tabs.count + 1
        let newTab = TerminalInstance(title: title ?? "Terminal \(tabNumber)", workingDirectory: dir)
        tabs.append(newTab)
        activeTabID = newTab.id
        newTab.start(in: dir)
        return newTab
    }

    func closeTab(id: UUID) {
        guard tabs.count > 1 else {
            activeTab?.restart()
            return
        }
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let tab = tabs.remove(at: index)
            tab.stop()
            if activeTabID == id {
                let nextIndex = min(index, tabs.count - 1)
                activeTabID = tabs[nextIndex].id
            }
        }
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func start(in directory: URL) {
        if let active = activeTab {
            active.start(in: directory)
        } else {
            createTab(in: directory)
        }
    }

    func send(_ command: String) {
        activeTab?.send(command)
    }

    func interrupt() {
        activeTab?.interrupt()
    }

    func clear() {
        activeTab?.clear()
    }

    func restart() {
        activeTab?.restart()
    }

    func stop() {
        for tab in tabs {
            tab.stop()
        }
    }

    func previousCommand() -> String {
        activeTab?.previousCommand() ?? ""
    }

    func nextCommand() -> String {
        activeTab?.nextCommand() ?? ""
    }
}

@MainActor
private enum TerminalOutputCleaner {
    static func clean(_ text: String) -> String {
        ANSIEscapeCleaner.clean(text)
    }
}
