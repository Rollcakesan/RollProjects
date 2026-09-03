import Foundation

struct EditorSmartEdit: Equatable, Sendable {
    let replacement: String
    let selection: NSRange
    var replacementRange: NSRange?
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

        // Auto-dedent on '}' if on a line with only whitespace
        if character == "}", range.length == 0 {
            let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
            let prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
            let prefix = source.substring(with: prefixRange)
            let suffixRange = NSRange(location: range.location, length: NSMaxRange(lineRange) - range.location)
            let suffix = source.substring(with: suffixRange)

            if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) && prefix.count >= tabWidth {
                let dedentedCount = max(0, prefix.count - tabWidth)
                let newPrefix = String(repeating: " ", count: dedentedCount)
                let replacement = newPrefix + "}"
                return EditorSmartEdit(
                    replacement: replacement,
                    selection: NSRange(location: lineRange.location + replacement.utf16.count, length: 0),
                    replacementRange: prefixRange
                )
            }
        }

        // Auto-closing pairs
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

        // Overtyping closing character
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

    // Soft Tab Backspace: delete up to tabWidth spaces if cursor is within indentation
    static func backspaceEdit(in source: NSString, range: NSRange, tabWidth: Int) -> EditorSmartEdit? {
        guard range.length == 0, range.location > 0, range.location <= source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
        let prefix = source.substring(with: prefixRange)

        // Only activate if prefix consists exclusively of multiple spaces
        guard prefix.count >= 2, prefix.allSatisfy({ $0 == " " }) else { return nil }

        let remainder = prefix.count % tabWidth
        let deleteCount = remainder == 0 ? tabWidth : remainder
        let deleteRange = NSRange(location: range.location - deleteCount, length: deleteCount)
        return EditorSmartEdit(
            replacement: "",
            selection: NSRange(location: deleteRange.location, length: 0),
            replacementRange: deleteRange
        )
    }

    // Indent lines (Tab on selection)
    static func indentLines(in source: NSString, range: NSRange, tabWidth: Int) -> EditorSmartEdit {
        let fullLineRange = source.lineRange(for: range)
        let linesBlock = source.substring(with: fullLineRange)
        let lines = linesBlock.components(separatedBy: "\n")
        let indentStr = String(repeating: " ", count: tabWidth)

        var newLines: [String] = []
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty {
                newLines.append(line)
            } else {
                newLines.append(indentStr + line)
            }
        }
        let replacement = newLines.joined(separator: "\n")
        let addedChars = replacement.utf16.count - linesBlock.utf16.count
        let newSelection = NSRange(location: fullLineRange.location, length: fullLineRange.length + addedChars)

        return EditorSmartEdit(
            replacement: replacement,
            selection: newSelection,
            replacementRange: fullLineRange
        )
    }

    // Dedent lines (Shift + Tab)
    static func dedentLines(in source: NSString, range: NSRange, tabWidth: Int) -> EditorSmartEdit {
        let fullLineRange = source.lineRange(for: range)
        let linesBlock = source.substring(with: fullLineRange)
        let lines = linesBlock.components(separatedBy: "\n")

        var newLines: [String] = []
        for line in lines {
            var spacesToRemove = 0
            for ch in line.prefix(tabWidth) {
                if ch == " " { spacesToRemove += 1 } else { break }
            }
            if spacesToRemove > 0 {
                newLines.append(String(line.dropFirst(spacesToRemove)))
            } else if line.hasPrefix("\t") {
                newLines.append(String(line.dropFirst(1)))
            } else {
                newLines.append(line)
            }
        }
        let replacement = newLines.joined(separator: "\n")
        let lengthDelta = linesBlock.utf16.count - replacement.utf16.count
        let newLength = max(0, fullLineRange.length - lengthDelta)
        let newSelection = NSRange(location: fullLineRange.location, length: newLength)

        return EditorSmartEdit(
            replacement: replacement,
            selection: newSelection,
            replacementRange: fullLineRange
        )
    }

    private static func newlineEdit(in source: NSString, range: NSRange, tabWidth: Int) -> EditorSmartEdit {
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
        let prefix = source.substring(with: prefixRange)
        
        let indentMatch = prefix.firstMatch(of: #/^[ \t]*/#)
        let indentation = indentMatch.map { String($0.0) } ?? ""
        
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let opensBlock = trimmed.last.map { "{[(:".contains($0) } == true
        let extraIndent = opensBlock ? String(repeating: " ", count: max(1, tabWidth)) : ""
        
        let nextChar = range.location < source.length ? source.substring(with: NSRange(location: range.location, length: 1)) : ""
        let closesBlock = ["}", "]", ")"].contains(nextChar)

        let replacement: String
        let selectionOffset: Int

        if opensBlock && closesBlock {
            let firstLine = "\n" + indentation + extraIndent
            replacement = firstLine + "\n" + indentation
            selectionOffset = firstLine.utf16.count
        } else {
            replacement = "\n" + indentation + extraIndent
            selectionOffset = replacement.utf16.count
        }

        return EditorSmartEdit(
            replacement: replacement,
            selection: NSRange(location: range.location + selectionOffset, length: 0)
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
