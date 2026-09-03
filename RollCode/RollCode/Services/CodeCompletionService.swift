import Foundation

@MainActor
final class CodeCompletionService {
    static let shared = CodeCompletionService()

    private var cachedFrequencies: [String: Int] = [:]
    private var lastScannedHash: Int = 0
    private var isScanning = false

    func updateCacheAsync(for text: String) {
        let hash = text.hashValue
        guard hash != lastScannedHash, !isScanning else { return }
        isScanning = true

        Task.detached(priority: .utility) {
            let frequencies = Self.extractWordFrequencies(from: text)
            await MainActor.run {
                self.cachedFrequencies = frequencies
                self.lastScannedHash = hash
                self.isScanning = false
            }
        }
    }

    func completions(
        for prefix: String,
        in text: String,
        language: CodeLanguage,
        fileURL: URL? = nil,
        line: Int = 1,
        character: Int = 0
    ) async -> [String] {
        var lspItems: [String] = []
        if language == .swift, let fileURL {
            lspItems = await SourceKitLSPService.shared.requestCompletions(
                url: fileURL,
                text: text,
                line: line,
                character: character
            )
        }

        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dot completion with empty prefix (immediately after typing '.')
        if trimmedPrefix.isEmpty {
            return Array(lspItems.prefix(25))
        }

        var filteredLSP = [String]()
        if !lspItems.isEmpty {
            let pLower = trimmedPrefix.lowercased()
            filteredLSP = lspItems.filter {
                $0.lowercased().hasPrefix(pLower) && $0.caseInsensitiveCompare(trimmedPrefix) != .orderedSame
            }
        }

        let localMatches = self.localCompletions(for: trimmedPrefix, in: text, language: language)

        if filteredLSP.isEmpty {
            return localMatches
        }

        // Blend LSP items (highest priority) with local fallback completions
        var merged = filteredLSP
        for item in localMatches {
            if !merged.contains(item) {
                merged.append(item)
            }
        }
        return Array(merged.prefix(25))
    }

    func completions(for prefix: String, in text: String, language: CodeLanguage) -> [String] {
        localCompletions(for: prefix, in: text, language: language)
    }

    func localCompletions(for prefix: String, in text: String, language: CodeLanguage) -> [String] {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return [] }

        // Trigger background scan if needed
        updateCacheAsync(for: text)

        let keywordList = Self.keywords(for: language)
        let keywordSet = Set(keywordList)
        let localWords = Self.extractLocalWords(around: prefix, in: text)

        var candidateWords = Set<String>()

        // 1. Language Keywords
        for kw in keywordList {
            if kw.localizedCaseInsensitiveContains(prefix) && kw.caseInsensitiveCompare(prefix) != .orderedSame {
                candidateWords.insert(kw)
            }
        }

        // 2. Cached identifiers (with frequencies)
        for (w, _) in cachedFrequencies {
            if w.localizedCaseInsensitiveContains(prefix) && w.caseInsensitiveCompare(prefix) != .orderedSame {
                candidateWords.insert(w)
            }
        }

        // 3. Local words around current cursor
        for w in localWords {
            if w.localizedCaseInsensitiveContains(prefix) && w.caseInsensitiveCompare(prefix) != .orderedSame {
                candidateWords.insert(w)
            }
        }

        let prefixLower = prefix.lowercased()

        // Score candidates based on user priority:
        // Priority 1: Prefix match over infix match
        // Priority 2: Language keyword / standard keyword
        // Priority 3: Local word (near current editing location)
        // Priority 4: Usage frequency in the file
        // Priority 5: Exact case prefix match
        // Priority 6: Shorter length
        // Priority 7: Alphabetical order
        let scored = candidateWords.map { word -> ScoredCandidate in
            let wordLower = word.lowercased()
            let startsWithPrefix = wordLower.hasPrefix(prefixLower)
            let isKeyword = keywordSet.contains(word)
            let isLocal = localWords.contains(word)
            let frequency = cachedFrequencies[word] ?? (isLocal ? 1 : 0)
            let exactCaseMatch = word.hasPrefix(prefix)

            return ScoredCandidate(
                word: word,
                startsWithPrefix: startsWithPrefix,
                isKeyword: isKeyword,
                isLocal: isLocal,
                frequency: frequency,
                exactCaseMatch: exactCaseMatch,
                length: word.count
            )
        }

        let sorted = scored.sorted()
        return sorted.prefix(20).map(\.word)
    }

    private struct ScoredCandidate: Comparable {
        let word: String
        let startsWithPrefix: Bool
        let isKeyword: Bool
        let isLocal: Bool
        let frequency: Int
        let exactCaseMatch: Bool
        let length: Int

        static func < (lhs: ScoredCandidate, rhs: ScoredCandidate) -> Bool {
            // 1. Prefix matches first
            if lhs.startsWithPrefix != rhs.startsWithPrefix {
                return lhs.startsWithPrefix
            }
            // 2. Language keywords & general reserved words first
            if lhs.isKeyword != rhs.isKeyword {
                return lhs.isKeyword
            }
            // 3. Local words (near cursor) next
            if lhs.isLocal != rhs.isLocal {
                return lhs.isLocal
            }
            // 4. Higher frequency words next
            if lhs.frequency != rhs.frequency {
                return lhs.frequency > rhs.frequency
            }
            // 5. Exact case match
            if lhs.exactCaseMatch != rhs.exactCaseMatch {
                return lhs.exactCaseMatch
            }
            // 6. Shorter words next
            if lhs.length != rhs.length {
                return lhs.length < rhs.length
            }
            // 7. Alphabetical
            return lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
        }
    }

    private static func extractLocalWords(around prefix: String, in text: String) -> Set<String> {
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

    nonisolated private static func extractWordFrequencies(from text: String) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        let pattern = #"\b[A-Za-z_][A-Za-z0-9_]{1,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let word = nsText.substring(with: match.range)
            frequencies[word, default: 0] += 1
        }
        return frequencies
    }

    static func keywords(for language: CodeLanguage) -> [String] {
        switch language {
        case .swift:
            return [
                "import", "let", "var", "func", "return", "if", "else", "guard",
                "switch", "case", "default", "for", "while", "repeat", "struct",
                "class", "enum", "protocol", "extension", "init", "deinit", "self",
                "Self", "true", "false", "nil", "private", "fileprivate", "internal",
                "public", "open", "static", "final", "mutating", "throws", "rethrows",
                "throw", "try", "catch", "async", "await", "where", "as", "is",
                "typealias", "associatedtype", "some", "any", "weak", "unowned",
                "override", "subscript", "continue", "break", "fallthrough", "defer"
            ]
        case .javascript, .typescript:
            return [
                "import", "export", "from", "default", "const", "let", "var",
                "function", "return", "if", "else", "switch", "case", "for", "while",
                "do", "class", "extends", "super", "this", "new", "true", "false",
                "null", "undefined", "try", "catch", "finally", "throw", "async",
                "await", "yield", "typeof", "instanceof", "interface", "type",
                "implements", "readonly", "private", "public", "protected",
                "abstract", "as", "is", "keyof", "in", "of", "break", "continue"
            ]
        case .python:
            return [
                "def", "class", "import", "from", "as", "return", "if", "elif",
                "else", "for", "while", "try", "except", "finally", "raise",
                "with", "lambda", "yield", "self", "True", "False", "None",
                "async", "await", "global", "nonlocal", "pass", "break", "continue",
                "and", "or", "not", "is", "in", "assert", "del"
            ]
        case .json:
            return ["true", "false", "null"]
        case .html:
            return [
                "html", "head", "body", "div", "span", "p", "a", "button",
                "input", "form", "script", "style", "link", "meta", "title",
                "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
                "table", "tr", "td", "th", "header", "footer", "main", "section"
            ]
        case .css:
            return [
                "display", "flex", "grid", "position", "absolute", "relative",
                "margin", "padding", "width", "height", "color", "background",
                "border", "border-radius", "font-size", "font-family", "font-weight",
                "align-items", "justify-content", "opacity", "z-index", "overflow",
                "cursor", "transition", "transform", "box-shadow"
            ]
        case .shell:
            return [
                "if", "then", "else", "elif", "fi", "case", "esac", "for",
                "select", "while", "until", "do", "done", "in", "function",
                "time", "export", "echo", "local", "return", "exit", "source"
            ]
        case .cFamily:
            return [
                "include", "define", "int", "char", "float", "double", "void",
                "struct", "typedef", "return", "if", "else", "switch", "case",
                "default", "for", "while", "do", "break", "continue", "sizeof",
                "static", "const", "volatile", "unsigned", "signed", "auto",
                "class", "public", "private", "protected", "virtual", "template"
            ]
        case .go:
            return [
                "package", "import", "func", "return", "var", "const", "type",
                "struct", "interface", "map", "chan", "if", "else", "switch",
                "case", "default", "for", "range", "go", "select", "defer",
                "make", "new", "nil", "true", "false", "break", "continue"
            ]
        case .rust:
            return [
                "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait",
                "use", "mod", "crate", "return", "if", "else", "match", "loop",
                "while", "for", "in", "break", "continue", "async", "await",
                "type", "self", "Self", "true", "false", "Some", "None", "Ok", "Err"
            ]
        case .markdown, .yaml, .plainText:
            return []
        }
    }
}
