import Foundation

/// Supported programming languages for language server discovery and LSP association.
public enum LSPDocumentLanguage: String, Sendable, CaseIterable {
    case swift, javascript, typescript, python, html, css, json, shell, markdown
    case cFamily, go, rust, yaml, plainText

    public init(url: URL) {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        if filename == "dockerfile" || filename == ".zshrc" || filename == ".bashrc" || filename == ".bash_profile" || filename == ".profile" {
            self = .shell
            return
        }

        switch ext {
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "py", "pyw": self = .python
        case "html", "htm": self = .html
        case "css", "scss", "sass": self = .css
        case "json", "jsonc": self = .json
        case "sh", "zsh", "bash": self = .shell
        case "md", "markdown": self = .markdown
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": self = .cFamily
        case "go": self = .go
        case "rs": self = .rust
        case "yaml", "yml": self = .yaml
        default: self = .plainText
        }
    }
}

/// A resolved language server executable and invocation parameters.
public struct ResolvedLanguageServer: Hashable, Sendable {
    public let identifier: String
    public let executablePath: String
    public let arguments: [String]
    public let languageId: String

    public var processIdentifier: String {
        ([identifier, executablePath] + arguments).joined(separator: "\u{0}")
    }

    public init(identifier: String, executablePath: String, arguments: [String], languageId: String) {
        self.identifier = identifier
        self.executablePath = executablePath
        self.arguments = arguments
        self.languageId = languageId
    }
}

/// Completion suggestion returned from LSP textDocument/completion.
public struct LSPCompletionItem: Hashable, Identifiable, Sendable {
    public let label: String
    public let insertText: String
    public let filterText: String?
    public let detail: String?
    public let replacementRange: NSRange?

    public var id: String {
        [label, insertText, detail ?? ""].joined(separator: "\u{0}")
    }

    public init(
        label: String,
        insertText: String? = nil,
        filterText: String? = nil,
        detail: String? = nil,
        replacementRange: NSRange? = nil
    ) {
        self.label = label
        self.insertText = insertText ?? label
        self.filterText = filterText
        self.detail = detail
        self.replacementRange = replacementRange
    }
}
