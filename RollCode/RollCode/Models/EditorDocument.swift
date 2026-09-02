import Foundation

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var text: String
    @Published private(set) var savedText: String
    private(set) var diskModificationDate: Date?

    init(url: URL, text: String, diskModificationDate: Date? = nil) {
        self.url = url
        self.text = text
        self.savedText = text
        self.diskModificationDate = diskModificationDate
    }

    var name: String { url.lastPathComponent }
    var isDirty: Bool { text != savedText }
    var language: CodeLanguage { CodeLanguage(url: url) }
    var lineCount: Int { text.count(where: \.isNewline) + 1 }

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

struct EditorSearchRequest: Equatable {
    enum Direction {
        case previous
        case next
    }

    let id = UUID()
    let direction: Direction
}

enum CodeLanguage: String {
    case swift, javascript, typescript, python, html, css, json, shell, markdown
    case cFamily, go, rust, yaml, plainText

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "py": self = .python
        case "html", "htm": self = .html
        case "css", "scss", "sass": self = .css
        case "json": self = .json
        case "sh", "zsh", "bash": self = .shell
        case "md", "markdown": self = .markdown
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": self = .cFamily
        case "go": self = .go
        case "rs": self = .rust
        case "yaml", "yml": self = .yaml
        default: self = .plainText
        }
    }

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
}
