import Foundation
#if canImport(LSPClientKit)
import LSPClientKit
#endif

extension LSPDocumentLanguage {
    init(codeLanguage: CodeLanguage) {
        switch codeLanguage {
        case .swift: self = .swift
        case .javascript: self = .javascript
        case .typescript: self = .typescript
        case .python: self = .python
        case .html: self = .html
        case .css: self = .css
        case .json: self = .json
        case .shell: self = .shell
        case .markdown: self = .markdown
        case .cFamily: self = .cFamily
        case .go: self = .go
        case .rust: self = .rust
        case .yaml: self = .yaml
        case .plainText: self = .plainText
        }
    }
}

extension LSPManager {
    func requestCompletions(
        for language: CodeLanguage,
        url: URL,
        text: String,
        line: Int,
        character: Int,
        workspaceURL: URL? = nil
    ) async -> [CodeCompletionSuggestion] {
        let lspLang = LSPDocumentLanguage(codeLanguage: language)
        let items: [LSPCompletionItem] = await self.requestCompletions(
            for: lspLang,
            url: url,
            text: text,
            line: line,
            character: character,
            workspaceURL: workspaceURL
        )
        return items.map { item in
            CodeCompletionSuggestion(
                label: item.label,
                insertText: item.insertText,
                filterText: item.filterText,
                detail: item.detail,
                replacementRange: item.replacementRange
            )
        }
    }

    func formatDocument(
        for language: CodeLanguage,
        url: URL,
        text: String,
        tabWidth: Int,
        workspaceURL: URL? = nil
    ) async -> String? {
        let lspLang = LSPDocumentLanguage(codeLanguage: language)
        return await self.formatDocument(
            for: lspLang,
            url: url,
            text: text,
            tabWidth: tabWidth,
            workspaceURL: workspaceURL
        )
    }
}

extension LanguageServerConfig {
    static func resolve(for language: CodeLanguage, documentURL: URL? = nil) -> ResolvedLanguageServer? {
        let lspLang = LSPDocumentLanguage(codeLanguage: language)
        return resolve(for: lspLang, documentURL: documentURL)
    }

    static func languageIdentifier(for language: CodeLanguage, documentURL: URL? = nil) -> String {
        let lspLang = LSPDocumentLanguage(codeLanguage: language)
        return languageIdentifier(for: lspLang, documentURL: documentURL)
    }
}

