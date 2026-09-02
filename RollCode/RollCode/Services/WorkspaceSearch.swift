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
        guard !query.isEmpty, limit > 0 else { return [] }

        var results: [WorkspaceSearchMatch] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                let occurrences = occurrenceCount(of: query, in: line)
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
        guard !query.isEmpty else { return [] }
        return files.compactMap { file in
            let (text, count) = replacing(query, with: replacement, in: file.text)
            guard count > 0 else { return nil }
            return WorkspaceReplacement(url: file.url, text: text, occurrences: count)
        }
    }

    private static func occurrenceCount(of query: String, in text: String) -> Int {
        let expression = regularExpression(for: query)
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func replacing(_ query: String, with replacement: String, in text: String) -> (String, Int) {
        let expression = regularExpression(for: query)
        let range = NSRange(text.startIndex..., in: text)
        let count = expression.numberOfMatches(in: text, range: range)
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        return (expression.stringByReplacingMatches(in: text, range: range, withTemplate: escapedReplacement), count)
    }

    private static func regularExpression(for query: String) -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: query),
            options: [.caseInsensitive]
        )
    }
}
