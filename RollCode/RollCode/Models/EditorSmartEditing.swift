import Foundation

struct EditorSmartEdit: Equatable {
    let replacement: String
    let selection: NSRange
}

enum EditorSmartEditing {
    private static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"
    ]

    static func edit(for input: String, in text: String, range: NSRange, tabWidth: Int = 4) -> EditorSmartEdit? {
        let source = text as NSString
        guard range.location <= source.length, NSMaxRange(range) <= source.length else { return nil }

        if input == "\n" || input == "\r" {
            return newlineEdit(in: source, range: range, tabWidth: tabWidth)
        }

        guard input.count == 1, let character = input.first else { return nil }
        if let closing = pairs[character] {
            if (character == "\"" || character == "'") && isEscaped(in: source, at: range.location) {
                return nil
            }
            let selectedText = source.substring(with: range)
            let replacement = String(character) + selectedText + String(closing)
            return EditorSmartEdit(
                replacement: replacement,
                selection: NSRange(location: range.location + 1, length: range.length)
            )
        }

        if pairs.values.contains(character), range.length == 0, range.location < source.length {
            let nextRange = NSRange(location: range.location, length: 1)
            if source.substring(with: nextRange) == String(character) {
                return EditorSmartEdit(
                    replacement: "",
                    selection: NSRange(location: range.location + 1, length: 0)
                )
            }
        }
        return nil
    }

    private static func newlineEdit(in source: NSString, range: NSRange, tabWidth: Int) -> EditorSmartEdit {
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
        let prefix = source.substring(with: prefixRange)
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        let opensBlock = trimmedPrefix.last.map { "{[(:".contains($0) } == true
        let extraIndent = opensBlock ? String(repeating: " ", count: max(1, tabWidth)) : ""
        let nextCharacter = range.location < source.length
            ? source.substring(with: NSRange(location: range.location, length: 1))
            : ""
        let closesBlock = ["}", "]", ")"].contains(nextCharacter)

        if opensBlock && closesBlock {
            let firstLine = "\n" + indentation + extraIndent
            let replacement = firstLine + "\n" + indentation
            return EditorSmartEdit(
                replacement: replacement,
                selection: NSRange(location: range.location + firstLine.utf16.count, length: 0)
            )
        }

        let replacement = "\n" + indentation + extraIndent
        return EditorSmartEdit(
            replacement: replacement,
            selection: NSRange(location: range.location + replacement.utf16.count, length: 0)
        )
    }

    private static func isEscaped(in source: NSString, at location: Int) -> Bool {
        guard location > 0 else { return false }
        var backslashCount = 0
        var index = location - 1
        while index >= 0, source.substring(with: NSRange(location: index, length: 1)) == "\\" {
            backslashCount += 1
            index -= 1
        }
        return backslashCount % 2 == 1
    }
}
