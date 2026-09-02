import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class TerminalSession {
    var output = ""
    var isVisible = true
    private(set) var isRunning = false

    @ObservationIgnored private var childPID: pid_t?
    @ObservationIgnored private var masterHandle: FileHandle?
    @ObservationIgnored private var outputContinuation: AsyncStream<String>.Continuation?
    private(set) var workingDirectory: URL?
    @ObservationIgnored private var commandHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?

    func start(in directory: URL) {
        stop()
        workingDirectory = directory
        output = "RollCode Terminal — \(directory.path)\n"

        do {
            let process = try PTYProcess.launch(in: directory)
            childPID = process.pid
            masterHandle = process.handle
            isRunning = true

            let handle = process.handle
            let outputStream = AsyncStream<String> { continuation in
                outputContinuation = continuation
                handle.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    guard !data.isEmpty else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(String(decoding: data, as: UTF8.self))
                }
                continuation.onTermination = { @Sendable _ in
                    handle.readabilityHandler = nil
                }
            }

            Task { @MainActor [weak self] in
                for await chunk in outputStream {
                    self?.appendOutput(TerminalOutputCleaner.clean(chunk))
                }
            }

            let pid = process.pid
            Task.detached(priority: .utility) { [weak self] in
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
                await MainActor.run { [weak self] in
                    guard self?.childPID == pid else { return }
                    self?.finishOutputStream()
                    self?.masterHandle = nil
                    self?.childPID = nil
                    self?.isRunning = false
                    self?.appendOutput("\n[Shell exited]\n")
                }
            }
        } catch {
            appendOutput("Could not start zsh: \(error.localizedDescription)\n")
        }
    }

    func send(_ command: String) {
        let command = command.trimmingCharacters(in: .newlines)
        guard !command.isEmpty else { return }
        remember(command)
        guard write(command + "\n") else {
            appendOutput("\n[Shell is not running]\n")
            return
        }
    }

    func interrupt() {
        guard write(Data([3])) else {
            appendOutput("\n[Shell is not running]\n")
            return
        }
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
        finishOutputStream()
        if let childPID {
            _ = kill(-childPID, SIGHUP)
            _ = kill(childPID, SIGHUP)
        }
        try? masterHandle?.close()
        masterHandle = nil
        childPID = nil
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
        guard let data = text.data(using: .utf8) else { return false }
        return write(data)
    }

    private func write(_ data: Data) -> Bool {
        guard isRunning, let masterHandle else { return false }
        do {
            try masterHandle.write(contentsOf: data)
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
        outputContinuation?.finish()
        masterHandle?.readabilityHandler = nil
        if let childPID {
            _ = kill(-childPID, SIGHUP)
            _ = kill(childPID, SIGHUP)
        }
        try? masterHandle?.close()
    }

    private func finishOutputStream() {
        outputContinuation?.finish()
        outputContinuation = nil
        masterHandle?.readabilityHandler = nil
    }
}

private enum PTYProcess {
    struct Result: Sendable {
        let pid: pid_t
        let handle: FileHandle
    }

    static func launch(in directory: URL) throws -> Result {
        guard let executable = strdup("/bin/zsh"),
              let argumentZero = strdup("zsh"),
              let noStartupFiles = strdup("-f"),
              let interactive = strdup("-i"),
              let directoryPath = strdup(directory.path) else {
            throw PTYError.couldNotPrepareArguments
        }

        let arguments = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 4)
        arguments[0] = argumentZero
        arguments[1] = noStartupFiles
        arguments[2] = interactive
        arguments[3] = nil

        var masterFD: Int32 = -1
        var windowSize = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&masterFD, nil, nil, &windowSize)

        if pid == 0 {
            _ = chdir(directoryPath)
            _ = setenv("TERM", "xterm-256color", 1)
            _ = setenv("CLICOLOR", "1", 1)
            _ = setenv("PS1", "❯ ", 1)
            _ = setenv("HISTFILE", "/dev/null", 1)
            execv(executable, arguments)
            _exit(127)
        }

        free(executable)
        free(argumentZero)
        free(noStartupFiles)
        free(interactive)
        free(directoryPath)
        arguments.deallocate()

        guard pid > 0, masterFD >= 0 else {
            throw PTYError.couldNotLaunch(errno)
        }
        return Result(pid: pid, handle: FileHandle(fileDescriptor: masterFD, closeOnDealloc: true))
    }
}

private enum PTYError: LocalizedError {
    case couldNotPrepareArguments
    case couldNotLaunch(Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotPrepareArguments:
            return "Could not prepare the shell process."
        case let .couldNotLaunch(code):
            return String(cString: strerror(code))
        }
    }
}

@MainActor
private enum TerminalOutputCleaner {
    private static let controlSequence = #/\u{001B}(?:\[[0-?]*[ -/]*[@-~]|\][^\u{0007}]*(?:\u{0007}|\u{001B}\\))/#

    static func clean(_ text: String) -> String {
        text.replacing(controlSequence, with: "")
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "")
    }
}
