import Foundation

@MainActor
final class TerminalSession: ObservableObject {
    @Published var output = ""
    @Published var isVisible = true
    @Published private(set) var isRunning = false

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private(set) var workingDirectory: URL?

    func start(in directory: URL) {
        stop()
        workingDirectory = directory
        output = "RollCode Terminal — \(directory.path)\n"

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f"]
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "1"
        environment["PWD"] = directory.path
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendOutput(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.appendOutput("\n[Shell exited]\n")
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            isRunning = true
        } catch {
            appendOutput("Could not start zsh: \(error.localizedDescription)\n")
        }
    }

    func send(_ command: String) {
        let command = command.trimmingCharacters(in: .newlines)
        guard !command.isEmpty else { return }
        guard isRunning, let inputPipe, let data = (command + "\n").data(using: .utf8) else {
            appendOutput("\n[Shell is not running]\n")
            return
        }
        appendOutput("\n❯ \(command)\n")
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            appendOutput("Could not send command: \(error.localizedDescription)\n")
        }
    }

    func clear() {
        output = ""
    }

    func restart() {
        if let workingDirectory { start(in: workingDirectory) }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        isRunning = false
    }

    private func appendOutput(_ text: String) {
        output += text
        if output.count > 1_000_000 {
            output = String(output.suffix(750_000))
        }
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }
}
