import Foundation

public struct WorkspaceSearchFile: Sendable {
    public let url: URL
    public let text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

public struct WorkspaceSearchMatch: Identifiable, Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let line: Int
    public let preview: String
    public let occurrences: Int

    public var id: String { "\(url.path):\(line)" }

    public init(url: URL, relativePath: String, line: Int, preview: String, occurrences: Int) {
        self.url = url
        self.relativePath = relativePath
        self.line = line
        self.preview = preview
        self.occurrences = occurrences
    }
}

public struct WorkspaceReplacement: Sendable, Equatable {
    public let url: URL
    public let text: String
    public let occurrences: Int

    public init(url: URL, text: String, occurrences: Int) {
        self.url = url
        self.text = text
        self.occurrences = occurrences
    }
}

public enum WorkspaceSearch {
    public static func matches(
        for query: String,
        in files: [WorkspaceSearchFile],
        relativeTo rootURL: URL,
        limit: Int = 2_000
    ) -> [WorkspaceSearchMatch] {
        guard !query.isEmpty, limit > 0, let regex = regex(for: query) else { return [] }

        var results: [WorkspaceSearchMatch] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                let occurrences = line.matches(of: regex).count
                guard occurrences > 0 else { continue }
                results.append(WorkspaceSearchMatch(
                    url: file.url,
                    relativePath: relativePath(of: file.url, relativeTo: rootURL),
                    line: index + 1,
                    preview: line.trimmingCharacters(in: .whitespaces),
                    occurrences: occurrences
                ))
                if results.count == limit { return results }
            }
        }
        return results
    }

    public static func replacements(
        of query: String,
        with replacement: String,
        in files: [WorkspaceSearchFile]
    ) -> [WorkspaceReplacement] {
        guard !query.isEmpty, let regex = regex(for: query) else { return [] }
        return files.compactMap { file in
            let count = file.text.matches(of: regex).count
            guard count > 0 else { return nil }
            let replaced = file.text.replacing(regex, with: replacement)
            return WorkspaceReplacement(url: file.url, text: replaced, occurrences: count)
        }
    }

    public static func relativePath(of fileURL: URL, relativeTo baseURL: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        let basePath = baseURL.standardizedFileURL.path
        if filePath.hasPrefix(basePath) {
            let relative = filePath.dropFirst(basePath.count)
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : String(relative)
        }
        return fileURL.lastPathComponent
    }

    private static func regex(for query: String) -> Regex<AnyRegexOutput>? {
        try? Regex(NSRegularExpression.escapedPattern(for: query)).ignoresCase()
    }
}
