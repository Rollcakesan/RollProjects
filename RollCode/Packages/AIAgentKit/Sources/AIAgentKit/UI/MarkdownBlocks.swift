import SwiftUI
import AppKit

public enum MarkdownBlock: Identifiable, Equatable, Sendable {
    case text(String)
    case code(language: String?, code: String)

    public var id: String {
        switch self {
        case .text(let t): return "text_\(t.hashValue)"
        case .code(let lang, let c): return "code_\(lang ?? "")_\(c.hashValue)"
        }
    }
}

public enum MarkdownBlockParser: Sendable {
    public static func parse(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var currentTextLines: [String] = []
        var currentCodeLines: [String] = []
        var currentLanguage: String? = nil
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
                    currentCodeLines.removeAll()
                    currentLanguage = nil
                    inCodeBlock = false
                } else {
                    if !currentTextLines.isEmpty {
                        let textBlock = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !textBlock.isEmpty {
                            blocks.append(.text(textBlock))
                        }
                        currentTextLines.removeAll()
                    }
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    currentLanguage = lang.isEmpty ? nil : lang
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                currentCodeLines.append(line)
            } else {
                currentTextLines.append(line)
            }
        }

        if inCodeBlock && !currentCodeLines.isEmpty {
            blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
        } else if !currentTextLines.isEmpty {
            let remaining = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                blocks.append(.text(remaining))
            }
        }

        return blocks
    }
}

public struct MarkdownCodeBlockView: View {
    public let language: String?
    public let code: String
    @State private var isCopied = false

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? Color.green : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(red: 0.145, green: 0.15, blue: 0.175).opacity(0.8))

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(white: 0.88))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(Color(red: 0.115, green: 0.12, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.08)))
        .padding(.vertical, 2)
    }
}
