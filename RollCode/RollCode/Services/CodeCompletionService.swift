import Foundation

public typealias CodeCompletionSuggestion = LSPCompletionItem

@MainActor
final class CodeCompletionService {
    static let shared = CodeCompletionService()

    func completions(
        for prefix: String,
        in text: String,
        language: CodeLanguage,
        fileURL: URL? = nil,
        workspaceURL: URL? = nil,
        line: Int = 1,
        character: Int = 0
    ) async -> [CodeCompletionSuggestion] {
        var lspItems: [CodeCompletionSuggestion] = []
        if let fileURL {
            lspItems = await LSPManager.shared.requestCompletions(
                for: language,
                url: fileURL,
                text: text,
                line: line,
                character: character,
                workspaceURL: workspaceURL
            )
        }

        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dot completion with empty prefix (immediately after typing '.')
        if trimmedPrefix.isEmpty {
            return Array(lspItems.prefix(25))
        }

        var filteredLSP = [CodeCompletionSuggestion]()
        if !lspItems.isEmpty {
            let pLower = trimmedPrefix.lowercased()
            filteredLSP = lspItems.filter {
                let candidate = ($0.filterText ?? $0.label).lowercased()
                return candidate.hasPrefix(pLower)
                    && $0.insertText.caseInsensitiveCompare(trimmedPrefix) != .orderedSame
            }
        }

        let localMatches = self.localCompletions(for: trimmedPrefix, in: text, language: language)
            .map { CodeCompletionSuggestion(label: $0) }

        if filteredLSP.isEmpty {
            return localMatches
        }

        // Blend LSP items (highest priority) with local fallback completions
        var merged = filteredLSP
        for item in localMatches {
            if !merged.contains(where: { $0.insertText == item.insertText }) {
                merged.append(item)
            }
        }
        return Array(merged.prefix(25))
    }

    func completions(for prefix: String, in text: String, language: CodeLanguage) -> [String] {
        localCompletions(for: prefix, in: text, language: language)
    }

    func localCompletions(for prefix: String, in text: String, language: CodeLanguage) -> [String] {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return [] }

        let prefixLower = trimmedPrefix.lowercased()
        let keywordList = Self.keywords(for: language)

        // 1. Language keywords starting with prefix (prioritized)
        let matchingKeywords = keywordList.filter {
            $0.lowercased().hasPrefix(prefixLower) && $0.caseInsensitiveCompare(trimmedPrefix) != .orderedSame
        }

        // 2. Local buffer identifiers starting with prefix
        let localWords = Self.extractLocalWords(in: text)
        let matchingLocalWords = localWords
            .filter {
                $0.lowercased().hasPrefix(prefixLower)
                && $0.caseInsensitiveCompare(trimmedPrefix) != .orderedSame
                && !matchingKeywords.contains($0)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return Array((matchingKeywords + matchingLocalWords).prefix(20))
    }

    private static func extractLocalWords(in text: String) -> Set<String> {
        var words = Set<String>()
        let lines = text.components(separatedBy: .newlines)
        for line in lines.prefix(200) {
            for word in line.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted) {
                if word.count >= 2 {
                    words.insert(word)
                }
            }
        }
        return words
    }

    static func keywords(for language: CodeLanguage) -> [String] {
        language.standardKeywords
    }
}
