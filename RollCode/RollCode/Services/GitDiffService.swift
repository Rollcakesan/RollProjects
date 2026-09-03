import Foundation

struct GitChange: Identifiable, Sendable {
    let path: String
    let status: String
    let diff: String

    var id: String { path }
}

enum GitDiffError: LocalizedError, Sendable {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

enum GitDiffService {
    static func changes(in rootURL: URL) throws -> [GitChange] {
        let repository = try repositoryContext(for: rootURL)
        let statusOutput = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", repository.pathspec],
            in: repository.rootURL
        )
        let entries = statusEntries(from: statusOutput)
        let hasHead = (try? runGit(["rev-parse", "--verify", "HEAD"], in: repository.rootURL)) != nil

        return try entries.map { entry in
            let diff: String
            if entry.status == "??" {
                diff = try runGit(
                    ["diff", "--no-index", "--no-ext-diff", "--color=never", "--", "/dev/null", entry.path],
                    in: repository.rootURL,
                    allowedExitCodes: [0, 1]
                )
            } else {
                let comparison = hasHead ? ["HEAD"] : ["--cached"]
                diff = try runGit(
                    ["diff"] + comparison + ["--no-ext-diff", "--color=never", "--", entry.path],
                    in: repository.rootURL
                )
            }
            return GitChange(
                path: repository.workspacePath(for: entry.path),
                status: entry.status,
                diff: diff
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func diffLineNumbers(for diff: String) -> (added: Set<Int>, modified: Set<Int>) {
        var added = Set<Int>()
        var modified = Set<Int>()
        let lines = diff.components(separatedBy: .newlines)
        var currentNewLine = 0

        for line in lines {
            if line.hasPrefix("@@") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3, let plusPart = parts.first(where: { $0.hasPrefix("+") }) {
                    let numStr = plusPart.dropFirst().components(separatedBy: ",")[0]
                    if let start = Int(numStr) {
                        currentNewLine = start
                    }
                }
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added.insert(currentNewLine)
                currentNewLine += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                // deletion marker
            } else if line.hasPrefix(" ") {
                currentNewLine += 1
            }
        }
        return (added, modified)
    }

    static func changedPaths(in rootURL: URL) throws -> [String] {
        let repository = try repositoryContext(for: rootURL)
        let statusOutput = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", repository.pathspec],
            in: repository.rootURL
        )
        return statusEntries(from: statusOutput)
            .map { repository.workspacePath(for: $0.path) }
            .sorted()
    }

    static func commit(in rootURL: URL, message: String) throws {
        let trimmed = message.trimmed
        guard !trimmed.isEmpty else {
            throw GitDiffError.commandFailed("Commit message cannot be empty.")
        }
        let repository = try repositoryContext(for: rootURL)
        let indexSnapshot = try GitIndexSnapshot.capture(in: repository.rootURL)
        do {
            _ = try runGit(["add", "-A", "--", repository.pathspec], in: repository.rootURL)
            _ = try runGit(
                ["commit", "-m", trimmed, "--", repository.pathspec],
                in: repository.rootURL
            )
        } catch {
            try indexSnapshot.restore()
            throw error
        }
    }

    private struct RepositoryContext {
        let rootURL: URL
        let workspacePrefix: String

        var pathspec: String { workspacePrefix.isEmpty ? "." : workspacePrefix }

        func workspacePath(for repositoryPath: String) -> String {
            guard !workspacePrefix.isEmpty else { return repositoryPath }
            let prefix = workspacePrefix + "/"
            guard repositoryPath.hasPrefix(prefix) else { return repositoryPath }
            return String(repositoryPath.dropFirst(prefix.count))
        }
    }

    private struct GitIndexSnapshot {
        let url: URL
        let data: Data?

        static func capture(in repositoryURL: URL) throws -> GitIndexSnapshot {
            let path = try runGit(["rev-parse", "--git-path", "index"], in: repositoryURL).trimmed
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : repositoryURL.appending(path: path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            return GitIndexSnapshot(url: url, data: exists ? try Data(contentsOf: url) : nil)
        }

        func restore() throws {
            if let data {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func repositoryContext(for workspaceURL: URL) throws -> RepositoryContext {
        let repositoryPath = try runGit(["rev-parse", "--show-toplevel"], in: workspaceURL).trimmed
        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL
        let workspaceURL = workspaceURL.standardizedFileURL
        let rootPrefix = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        guard workspaceURL == repositoryURL || workspaceURL.path.hasPrefix(rootPrefix) else {
            throw GitDiffError.commandFailed("The workspace is outside the Git repository.")
        }
        let prefix = workspaceURL == repositoryURL
            ? ""
            : String(workspaceURL.path.dropFirst(rootPrefix.count))
        return RepositoryContext(rootURL: repositoryURL, workspacePrefix: prefix)
    }

    private static func statusEntries(from output: String) -> [(status: String, path: String)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [(String, String)] = []
        var index = 0

        while index < fields.count {
            let field = fields[index]
            guard field.count >= 4 else {
                index += 1
                continue
            }
            let status = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            entries.append((status, path))
            index += status.contains("R") || status.contains("C") ? 2 : 1
        }
        return entries
    }

    private static func runGit(
        _ arguments: [String],
        in rootURL: URL,
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path] + arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let message = String(decoding: outputData, as: UTF8.self).trimmed
            throw GitDiffError.commandFailed(message.isEmpty ? "Git command failed." : message)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
