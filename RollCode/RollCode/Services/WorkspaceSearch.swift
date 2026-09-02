import Foundation

struct WorkspaceSearchFile: Sendable {
    let url: URL
    let text: String
}

struct WorkspaceSearchMatch: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    let line: Int
    let preview: String
    let occurrences: Int

    var id: String { "\(url.path):\(line)" }
}

struct WorkspaceReplacement: Sendable {
    let url: URL
    let text: String
    let occurrences: Int
}

enum WorkspaceSearch {
    static func matches(
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
                    relativePath: file.url.relativePath(from: rootURL),
                    line: index + 1,
                    preview: line.trimmingCharacters(in: .whitespaces),
                    occurrences: occurrences
                ))
                if results.count == limit { return results }
            }
        }
        return results
    }

    static func replacements(
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

    private static func regex(for query: String) -> Regex<AnyRegexOutput>? {
        try? Regex(NSRegularExpression.escapedPattern(for: query)).ignoresCase()
    }
}
