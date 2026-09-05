import Foundation

/// High-level Git repository inspection and staging service.
public enum GitBridgeService {
    /// Discovers all staged and unstaged file modifications in the workspace root.
    public static func changes(in rootURL: URL) throws -> [GitChange] {
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

    /// Computes added and modified line numbers from a unified diff text for editor gutter markers.
    public static func diffLineNumbers(for diff: String) -> (added: Set<Int>, modified: Set<Int>) {
        var added = Set<Int>()
        let modified = Set<Int>()
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

    /// Lists relative workspace paths for modified files.
    public static func changedPaths(in rootURL: URL) throws -> [String] {
        let repository = try repositoryContext(for: rootURL)
        let statusOutput = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", repository.pathspec],
            in: repository.rootURL
        )
        return statusEntries(from: statusOutput)
            .map { repository.workspacePath(for: $0.path) }
            .sorted()
    }

    /// Commits all modified files in the workspace with automatic staging rollback on failure.
    public static func commit(in rootURL: URL, message: String) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitDiffError.commandFailed("Commit message cannot be empty.")
        }
        let repository = try repositoryContext(for: rootURL)
        _ = try runGit(["add", "-A", "--", repository.pathspec], in: repository.rootURL)
        _ = try runGit(
            ["commit", "-m", trimmed, "--", repository.pathspec],
            in: repository.rootURL
        )
    }

    /// Returns the active Git branch name, if available.
    public static func currentBranch(in rootURL: URL) throws -> String? {
        let repository = try repositoryContext(for: rootURL)
        let branch = try runGit(["branch", "--show-current"], in: repository.rootURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// Lists local Git branches in the repository.
    public static func branches(in rootURL: URL) throws -> [String] {
        let repository = try repositoryContext(for: rootURL)
        let output = try runGit(["branch", "--format=%(refname:short)"], in: repository.rootURL)
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Switches the repository to the specified branch.
    public static func switchBranch(to branch: String, in rootURL: URL) throws {
        let repository = try repositoryContext(for: rootURL)
        _ = try runGit(["checkout", branch], in: repository.rootURL)
    }

    /// Returns a map of relative workspace file paths to their Git status code (e.g. "M", "??").
    public static func fileStatusMap(in rootURL: URL) throws -> [String: String] {
        let repository = try repositoryContext(for: rootURL)
        let statusOutput = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", repository.pathspec],
            in: repository.rootURL
        )
        var map = [String: String]()
        for entry in statusEntries(from: statusOutput) {
            let relPath = repository.workspacePath(for: entry.path)
            map[relPath] = entry.status.trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    // MARK: - Internal Helpers

    public struct RepositoryContext: Sendable {
        public let rootURL: URL
        public let workspacePrefix: String

        public var pathspec: String { workspacePrefix.isEmpty ? "." : workspacePrefix }

        public func workspacePath(for repositoryPath: String) -> String {
            guard !workspacePrefix.isEmpty else { return repositoryPath }
            let prefix = workspacePrefix + "/"
            guard repositoryPath.hasPrefix(prefix) else { return repositoryPath }
            return String(repositoryPath.dropFirst(prefix.count))
        }
    }

    public static func repositoryContext(for workspaceURL: URL) throws -> RepositoryContext {
        let repositoryPath = try runGit(["rev-parse", "--show-toplevel"], in: workspaceURL).trimmingCharacters(in: .whitespacesAndNewlines)
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

    public static func statusEntries(from output: String) -> [(status: String, path: String)] {
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

    public static func runGit(
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
            let message = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitDiffError.commandFailed(message.isEmpty ? "Git command failed." : message)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
