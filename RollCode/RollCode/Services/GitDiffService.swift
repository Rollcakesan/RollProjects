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
        let statusOutput = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: rootURL
        )
        let entries = statusEntries(from: statusOutput)

        return try entries.map { entry in
            let diff: String
            if entry.status == "??" {
                diff = untrackedDiff(for: entry.path, in: rootURL)
            } else {
                diff = try runGit(
                    ["diff", "HEAD", "--no-ext-diff", "--color=never", "--", entry.path],
                    in: rootURL
                )
            }
            return GitChange(path: entry.path, status: entry.status, diff: diff)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

    private static func untrackedDiff(for path: String, in rootURL: URL) -> String {
        let url = rootURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              data.count <= 1_000_000,
              !data.prefix(8_192).contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return "Binary or large untracked file"
        }

        guard !text.isEmpty else { return "Empty untracked file" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let content = lines.map { "+" + $0 }.joined(separator: "\n")
        return """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1,\(lines.count) @@
        \(content)
        """
    }

    private static func runGit(_ arguments: [String], in rootURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path] + arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: outputData, as: UTF8.self).trimmed
            throw GitDiffError.commandFailed(message.isEmpty ? "Git command failed." : message)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
