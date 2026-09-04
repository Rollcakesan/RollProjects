import Foundation
import Observation

@Observable
@MainActor
final class EditorDocument: Identifiable {
    @ObservationIgnored let id = UUID()
    var url: URL
    var text: String {
        didSet {
            if text != oldValue {
                cachedLineCount = text.count(where: \.isNewline) + 1
            }
        }
    }
    private(set) var savedText: String
    private(set) var diskModificationDate: Date?
    var isPreviewMode = false
    var diagnostics: [SyntaxDiagnostic] = []
    var isCheckingSyntax: Bool = false
    var gitAddedLines: Set<Int> = []
    var gitModifiedLines: Set<Int> = []
    private var cachedLineCount: Int

    init(url: URL, text: String, diskModificationDate: Date? = nil) {
        self.url = url
        self.text = text
        self.savedText = text
        self.diskModificationDate = diskModificationDate
        self.cachedLineCount = text.count(where: \.isNewline) + 1
    }

    var name: String { url.lastPathComponent }
    var isDirty: Bool { text != savedText }
    var language: CodeLanguage { CodeLanguage(url: url) }
    var lineCount: Int { cachedLineCount }

    func markSaved(modificationDate: Date? = nil) {
        savedText = text
        diskModificationDate = modificationDate
    }

    func replaceFromDisk(text: String, modificationDate: Date?) {
        self.text = text
        savedText = text
        diskModificationDate = modificationDate
    }

    func recordDiskModificationDate(_ date: Date?) {
        diskModificationDate = date
    }
}

struct EditorSearchRequest: Equatable, Sendable {
    enum Direction: Sendable {
        case previous
        case next
    }

    let id = UUID()
    let direction: Direction
}

struct EditorNavigationRequest: Equatable, Sendable {
    let id = UUID()
    let line: Int
}

public typealias CodeLanguage = LSPDocumentLanguage

extension CodeLanguage {
    var displayName: String {
        switch self {
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .cFamily: return "C / C++"
        case .yaml: return "YAML"
        case .plainText: return "Plain Text"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var systemImageName: String {
        switch self {
        case .swift: return "swift"
        case .json: return "curlybraces"
        case .shell: return "terminal"
        case .markdown: return "text.document"
        case .cFamily: return "c.square"
        case .html, .css: return "globe"
        default: return "doc.text"
        }
    }

    var standardKeywords: [String] {
        switch self {
        case .swift:
            return [
                "import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "guard",
                "switch", "case", "default", "for", "while", "repeat", "return", "throw", "throws", "try", "await", "async",
                "actor", "private", "public", "internal", "fileprivate", "open", "static", "final", "mutating", "some", "any",
                "in", "where", "nil", "true", "false", "self", "Self", "typealias", "associatedtype", "weak", "unowned",
                "override", "subscript", "continue", "break", "fallthrough", "defer", "init", "deinit"
            ]
        case .javascript, .typescript:
            return [
                "const", "let", "var", "function", "class", "interface", "type", "extends", "implements", "if", "else",
                "switch", "case", "default", "for", "while", "do", "return", "throw", "try", "catch", "finally", "async",
                "await", "import", "export", "from", "new", "this", "super", "null", "undefined", "true", "false", "yield",
                "typeof", "instanceof", "readonly", "private", "public", "protected", "abstract", "as", "is", "keyof",
                "in", "of", "break", "continue"
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
                "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield", "self"
            ]
        case .shell:
            return [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
                "function", "in", "export", "local", "select", "time", "echo", "return", "exit", "source"
            ]
        case .json:
            return ["true", "false", "null"]
        case .html:
            return [
                "html", "head", "body", "div", "span", "p", "a", "button", "input", "form",
                "script", "style", "link", "meta", "title", "header", "footer", "main", "section"
            ]
        case .css:
            return [
                "display", "flex", "grid", "position", "absolute", "relative", "margin", "padding",
                "width", "height", "color", "background", "border", "font-size", "opacity", "overflow"
            ]
        case .cFamily:
            return [
                "auto", "break", "case", "char", "class", "const", "continue", "default", "delete", "do",
                "double", "else", "enum", "explicit", "extern", "float", "for", "friend", "if", "inline",
                "int", "long", "namespace", "new", "nullptr", "operator", "private", "protected", "public",
                "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this",
                "throw", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "make", "new"
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while", "Some", "None", "Ok", "Err"
            ]
        case .yaml:
            return ["true", "false", "yes", "no", "null"]
        case .markdown, .plainText:
            return []
        }
    }
}
