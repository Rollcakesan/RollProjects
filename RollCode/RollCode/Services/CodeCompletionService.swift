import Foundation

enum CodeCompletionService {
    static func completions(for prefix: String, in text: String, language: CodeLanguage) -> [String] {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.count >= 2 else { return [] }

        var candidates = Set<String>()

        // 1. Language Keywords
        for kw in keywords(for: language) {
            if kw.localizedCaseInsensitiveContains(prefix) && kw.caseInsensitiveCompare(prefix) != .orderedSame {
                candidates.insert(kw)
            }
        }

        // 2. Buffer words (Identifiers in current file)
        let words = extractIdentifiers(from: text)
        for w in words {
            if w.localizedCaseInsensitiveContains(prefix) && w.caseInsensitiveCompare(prefix) != .orderedSame {
                candidates.insert(w)
            }
        }

        // Sort candidates: prefix matches first, then shorter, then alphabetical
        let sorted = candidates.sorted { a, b in
            let aHasPrefix = a.lowercased().hasPrefix(prefix.lowercased())
            let bHasPrefix = b.lowercased().hasPrefix(prefix.lowercased())
            if aHasPrefix != bHasPrefix {
                return aHasPrefix
            }
            if a.count != b.count {
                return a.count < b.count
            }
            return a < b
        }

        return Array(sorted.prefix(20))
    }

    private static func extractIdentifiers(from text: String) -> Set<String> {
        var identifiers = Set<String>()
        let pattern = #"\b[A-Za-z_][A-Za-z0-9_]{2,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            identifiers.insert(nsText.substring(with: match.range))
        }
        return identifiers
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
