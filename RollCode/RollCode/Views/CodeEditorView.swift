import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let searchTerm: String
    let searchRequest: EditorSearchRequest?
    let navigationRequest: EditorNavigationRequest?
    var errorLines: Set<Int> = []
    var gitAddedLines: Set<Int> = []
    var gitModifiedLines: Set<Int> = []
    var documentURL: URL? = nil
    var workspaceURL: URL? = nil
    let tabWidth: Int
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorPalette.background

        let textView = EditorTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.writingToolsBehavior = .none
        textView.backgroundColor = EditorPalette.background
        textView.insertionPointColor = EditorPalette.caret
        textView.selectedTextAttributes = [
            .backgroundColor: EditorPalette.selection,
            .foregroundColor: EditorPalette.foreground
        ]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        let editorFont = EditorPalette.font(size: fontSize)
        textView.font = editorFont
        textView.textColor = EditorPalette.foreground
        let paragraphStyle = EditorPalette.paragraphStyle(tabWidth: tabWidth, fontSize: fontSize)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.font] = editorFont
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        ruler.errorLines = errorLines
        ruler.gitAddedLines = gitAddedLines
        ruler.gitModifiedLines = gitModifiedLines
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.applyHighlighting(language: language, searchTerm: searchTerm)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        let editorFont = EditorPalette.font(size: fontSize)
        if textView.font != editorFont {
            textView.font = editorFont
            textView.typingAttributes[.font] = editorFont
        }
        let paragraphStyle = EditorPalette.paragraphStyle(tabWidth: tabWidth, fontSize: fontSize)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        if !context.coordinator.isInternalTextChange && textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
        context.coordinator.applyHighlighting(language: language, searchTerm: searchTerm)
        context.coordinator.handleSearchRequest(searchRequest, query: searchTerm)
        context.coordinator.handleNavigationRequest(navigationRequest)
        context.coordinator.ruler?.errorLines = errorLines
        context.coordinator.ruler?.gitAddedLines = gitAddedLines
        context.coordinator.ruler?.gitModifiedLines = gitModifiedLines
        context.coordinator.ruler?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var isInternalTextChange = false
        private var isApplyingAttributes = false
        private var isPerformingSmartEdit = false
        private var lastSearchRequestID: UUID?
        private var lastNavigationRequestID: UUID?
        private var completionDebounceTask: Task<Void, Never>?
        let suggestionController = SuggestionOverlayController()

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingAttributes, let textView else { return }
            isInternalTextChange = true
            parent.text = textView.string
            isInternalTextChange = false
            applyHighlighting(language: parent.language, searchTerm: parent.searchTerm)
            ruler?.needsDisplay = true

            scheduleCompletion(in: textView)
        }

        private var lastBracketPair: (NSRange, NSRange)?

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
            ruler?.needsDisplay = true
            applyBracketMatching()

            if suggestionController.isVisible {
                guard let textView,
                      textView.selectedRange().location == suggestionController.prefixRange.location + suggestionController.prefixRange.length else {
                    suggestionController.hide()
                    return
                }
            }
        }

        private func applyBracketMatching() {
            guard let textView = self.textView,
                  let textStorage = textView.textStorage else { return }

            if let (r1, r2) = lastBracketPair {
                if r1.location + r1.length <= textStorage.length {
                    textStorage.removeAttribute(.backgroundColor, range: r1)
                }
                if r2.location + r2.length <= textStorage.length {
                    textStorage.removeAttribute(.backgroundColor, range: r2)
                }
                lastBracketPair = nil
            }

            let selection = textView.selectedRange()
            guard selection.length == 0 else { return }
            let text = textStorage.string as NSString
            guard selection.location <= text.length else { return }

            if let pair = findMatchingBracketPair(at: selection.location, in: text) {
                lastBracketPair = pair
                let highlightColor = NSColor.systemTeal.withAlphaComponent(0.28)
                textStorage.addAttribute(.backgroundColor, value: highlightColor, range: pair.0)
                textStorage.addAttribute(.backgroundColor, value: highlightColor, range: pair.1)
            }
        }

        private func findMatchingBracketPair(at location: Int, in text: NSString) -> (NSRange, NSRange)? {
            let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
            let reversePairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]

            var testLocations = [Int]()
            if location > 0 { testLocations.append(location - 1) }
            if location < text.length { testLocations.append(location) }

            for loc in testLocations {
                let charCode = text.character(at: loc)
                guard let scalar = UnicodeScalar(charCode) else { continue }
                let ch = Character(scalar)

                if let closing = pairs[ch] {
                    var depth = 0
                    for i in (loc + 1)..<text.length {
                        guard let s = UnicodeScalar(text.character(at: i)) else { continue }
                        let c = Character(s)
                        if c == ch { depth += 1 }
                        else if c == closing {
                            if depth == 0 {
                                return (NSRange(location: loc, length: 1), NSRange(location: i, length: 1))
                            }
                            depth -= 1
                        }
                    }
                } else if let opening = reversePairs[ch] {
                    var depth = 0
                    for i in stride(from: loc - 1, through: 0, by: -1) {
                        guard let s = UnicodeScalar(text.character(at: i)) else { continue }
                        let c = Character(s)
                        if c == ch { depth += 1 }
                        else if c == opening {
                            if depth == 0 {
                                return (NSRange(location: i, length: 1), NSRange(location: loc, length: 1))
                            }
                            depth -= 1
                        }
                    }
                }
            }
            return nil
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if suggestionController.isVisible {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    suggestionController.selectPrevious()
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    suggestionController.selectNext()
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    return suggestionController.commitSelected()
                case #selector(NSResponder.cancelOperation(_:)):
                    suggestionController.hide()
                    return true
                default:
                    break
                }
            }

            // Multi-line indent with Tab
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                let selectedRange = textView.selectedRange()
                let nsText = textView.string as NSString
                if selectedRange.length > 0 {
                    let edit = EditorSmartEditing.indentLines(in: nsText, range: selectedRange, tabWidth: parent.tabWidth)
                    applyEdit(edit, in: textView)
                    return true
                }
            }

            // Dedent with Shift + Tab
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                let selectedRange = textView.selectedRange()
                let nsText = textView.string as NSString
                let edit = EditorSmartEditing.dedentLines(in: nsText, range: selectedRange, tabWidth: parent.tabWidth)
                applyEdit(edit, in: textView)
                return true
            }

            // Soft Tab Backspace: delete tabWidth spaces if inside indent
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                let selectedRange = textView.selectedRange()
                let nsText = textView.string as NSString
                if let edit = EditorSmartEditing.backspaceEdit(in: nsText, range: selectedRange, tabWidth: parent.tabWidth) {
                    applyEdit(edit, in: textView)
                    return true
                }
            }

            return false
        }

        private func applyEdit(_ edit: EditorSmartEdit, in textView: NSTextView) {
            let targetRange = edit.replacementRange ?? textView.selectedRange()
            isPerformingSmartEdit = true
            let undoManager = textView.undoManager
            undoManager?.beginUndoGrouping()
            textView.insertText(edit.replacement, replacementRange: targetRange)
            textView.setSelectedRange(edit.selection)
            undoManager?.endUndoGrouping()
            isPerformingSmartEdit = false
            isInternalTextChange = true
            parent.text = textView.string
            isInternalTextChange = false
            applyHighlighting(language: parent.language, searchTerm: parent.searchTerm)
            ruler?.needsDisplay = true
        }

        private func scheduleCompletion(in textView: NSTextView) {
            completionDebounceTask?.cancel()

            // Don't interrupt IME composition (Japanese input, etc.)
            guard !textView.hasMarkedText() else {
                suggestionController.hide()
                return
            }

            completionDebounceTask = Task { @MainActor [weak self] in
                // 150ms debounce: wait until user stops typing
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let textView = self.textView else { return }

                let selectedRange = textView.selectedRange()
                guard selectedRange.length == 0, selectedRange.location >= 1 else {
                    self.suggestionController.hide()
                    return
                }
                let nsText = textView.string as NSString
                guard selectedRange.location <= nsText.length else {
                    self.suggestionController.hide()
                    return
                }

                let charBefore = nsText.character(at: selectedRange.location - 1)
                guard let unicodeScalar = UnicodeScalar(charBefore) else {
                    self.suggestionController.hide()
                    return
                }

                let isDot = (unicodeScalar == ".")
                let isWordChar = CharacterSet.alphanumerics.contains(unicodeScalar) || unicodeScalar == "_"
                guard isDot || isWordChar else {
                    self.suggestionController.hide()
                    return
                }

                let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
                let prefixRange = NSRange(location: lineRange.location, length: selectedRange.location - lineRange.location)
                let linePrefix = nsText.substring(with: prefixRange)

                // Calculate 1-based line and 0-based character column
                var lineNumber = 1
                var scanLoc = 0
                while scanLoc < lineRange.location {
                    scanLoc = NSMaxRange(nsText.lineRange(for: NSRange(location: scanLoc, length: 0)))
                    lineNumber += 1
                }
                let columnNumber = selectedRange.location - lineRange.location

                let lastWord: String
                let wordRange: NSRange
                if isDot {
                    lastWord = ""
                    wordRange = NSRange(location: selectedRange.location, length: 0)
                } else {
                    let delimiters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
                    guard let word = linePrefix.components(separatedBy: delimiters).last, !word.isEmpty else {
                        self.suggestionController.hide()
                        return
                    }
                    lastWord = word
                    wordRange = NSRange(location: selectedRange.location - word.utf16.count, length: word.utf16.count)
                }

                let suggestions = await CodeCompletionService.shared.completions(
                    for: lastWord,
                    in: textView.string,
                    language: self.parent.language,
                    fileURL: self.parent.documentURL,
                    workspaceURL: self.parent.workspaceURL,
                    line: lineNumber,
                    character: columnNumber
                )

                guard !Task.isCancelled, textView.selectedRange().location == selectedRange.location else { return }

                if !suggestions.isEmpty {
                    self.suggestionController.show(suggestions: suggestions, prefixRange: wordRange, in: textView)
                } else {
                    self.suggestionController.hide()
                }
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isPerformingSmartEdit,
                  let replacementString,
                  let edit = EditorSmartEditing.edit(
                    for: replacementString,
                    in: textView.string,
                    range: affectedCharRange,
                    tabWidth: parent.tabWidth
                  ) else { return true }

            let resolvedEdit = EditorSmartEdit(
                replacement: edit.replacement,
                selection: edit.selection,
                replacementRange: edit.replacementRange ?? affectedCharRange
            )
            applyEdit(resolvedEdit, in: textView)
            return false
        }

        func handleSearchRequest(_ request: EditorSearchRequest?, query: String) {
            guard let request,
                  request.id != lastSearchRequestID,
                  !query.isEmpty,
                  let textView else { return }
            lastSearchRequestID = request.id

            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: text.length)
            let match: NSRange

            switch request.direction {
            case .next:
                let start = min(NSMaxRange(selection), text.length)
                let remaining = NSRange(location: start, length: text.length - start)
                let next = text.range(of: query, options: .caseInsensitive, range: remaining)
                match = next.location == NSNotFound
                    ? text.range(of: query, options: .caseInsensitive, range: fullRange)
                    : next
            case .previous:
                let end = min(selection.location, text.length)
                let preceding = NSRange(location: 0, length: end)
                let previous = text.range(of: query, options: [.caseInsensitive, .backwards], range: preceding)
                match = previous.location == NSNotFound
                    ? text.range(of: query, options: [.caseInsensitive, .backwards], range: fullRange)
                    : previous
            }

            guard match.location != NSNotFound else { return }
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.window?.makeFirstResponder(textView)
        }

        func handleNavigationRequest(_ request: EditorNavigationRequest?) {
            guard let request,
                  request.id != lastNavigationRequestID,
                  let textView else { return }
            lastNavigationRequestID = request.id

            let text = textView.string as NSString
            var line = 1
            var location = 0
            while line < request.line, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }

        func applyHighlighting(language: CodeLanguage, searchTerm: String) {
            guard let textStorage = textView?.textStorage, let textView else { return }
            let fullLength = textStorage.length
            guard fullLength > 0 else { return }

            let activeRange: NSRange
            if fullLength > 40_000, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
                let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
                let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                let padding = 15_000
                let start = max(0, charRange.location - padding)
                let end = min(fullLength, NSMaxRange(charRange) + padding)
                activeRange = NSRange(location: start, length: end - start)
            } else {
                activeRange = NSRange(location: 0, length: fullLength)
            }

            isApplyingAttributes = true
            textStorage.beginEditing()
            textStorage.setAttributes([
                .font: EditorPalette.font(size: parent.fontSize),
                .foregroundColor: EditorPalette.foreground,
                .backgroundColor: EditorPalette.background,
                .paragraphStyle: EditorPalette.paragraphStyle(tabWidth: parent.tabWidth, fontSize: parent.fontSize)
            ], range: activeRange)

            for rule in SyntaxRules.rules(for: language) {
                for match in rule.regex.matches(in: textStorage.string, range: activeRange) {
                    textStorage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
                }
            }

            if !searchTerm.isEmpty,
               let expression = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: searchTerm),
                options: [.caseInsensitive]
               ) {
                for match in expression.matches(in: textStorage.string, range: activeRange) {
                    textStorage.addAttribute(.backgroundColor, value: EditorPalette.searchMatch, range: match.range)
                    textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: match.range)
                }
            }

            for errorLine in parent.errorLines {
                if let range = characterRange(forLine: errorLine, in: textStorage.string),
                   NSIntersectionRange(range, activeRange).length > 0 {
                    textStorage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18), range: range)
                    textStorage.addAttribute(.underlineColor, value: NSColor.systemRed, range: range)
                    textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            textStorage.endEditing()
            isApplyingAttributes = false
        }

        private func characterRange(forLine targetLine: Int, in string: String) -> NSRange? {
            let nsString = string as NSString
            var currentLine = 1
            var index = 0
            while index < nsString.length {
                let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
                if currentLine == targetLine {
                    return lineRange
                }
                index = NSMaxRange(lineRange)
                currentLine += 1
            }
            if currentLine == targetLine && nsString.length == 0 {
                return NSRange(location: 0, length: 0)
            }
            return nil
        }
    }
}

@MainActor
private enum EditorPalette {
    static var background: NSColor { RollCodeTheme.nsEditorBackground }
    static var foreground: NSColor { RollCodeTheme.nsForeground }
    static var caret: NSColor { RollCodeTheme.nsCaret }
    static var selection: NSColor { RollCodeTheme.nsSelection }
    static var searchMatch: NSColor { RollCodeTheme.nsSearchMatch }
    static var font: NSFont { RollCodeTheme.editorFont }

    static func font(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func paragraphStyle(tabWidth: Int, fontSize: CGFloat = 14.5) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font(size: fontSize)]).width
        style.defaultTabInterval = spaceWidth * CGFloat(tabWidth)
        style.tabStops = []
        return style
    }
}

@MainActor
private struct SyntaxRule {
    let regex: NSRegularExpression
    let color: NSColor

    init(pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
        self.regex = (try? NSRegularExpression(pattern: pattern, options: options)) ?? (try! NSRegularExpression(pattern: "$^"))
        self.color = color
    }
}

@MainActor
private enum SyntaxRules {
    private static let keyword = NSColor(red: 0.78, green: 0.48, blue: 0.92, alpha: 1)
    private static let string = NSColor(red: 0.72, green: 0.86, blue: 0.56, alpha: 1)
    private static let comment = NSColor(red: 0.43, green: 0.48, blue: 0.52, alpha: 1)
    private static let number = NSColor(red: 0.92, green: 0.68, blue: 0.43, alpha: 1)
    private static let type = NSColor(red: 0.45, green: 0.75, blue: 0.94, alpha: 1)

    private static let slashComments = SyntaxRule(pattern: #"//.*$|/\*[\s\S]*?\*/"#, color: comment, options: [.anchorsMatchLines])
    private static let hashComments = SyntaxRule(pattern: #"#.*$"#, color: comment, options: [.anchorsMatchLines])

    private static func keywordRule(for language: CodeLanguage) -> SyntaxRule? {
        let words = language.standardKeywords
        guard !words.isEmpty else { return nil }
        let pattern = #"\b("# + words.joined(separator: "|") + #")\b"#
        return SyntaxRule(pattern: pattern, color: keyword)
    }

    private static let commonRules = [
        SyntaxRule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: number),
        SyntaxRule(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: string),
    ]

    static func rules(for language: CodeLanguage) -> [SyntaxRule] {
        var list = commonRules
        if let kwRule = keywordRule(for: language) {
            list.append(kwRule)
        }

        switch language {
        case .swift:
            list.append(SyntaxRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, color: type))
            list.append(slashComments)
        case .javascript, .typescript, .cFamily, .go, .rust:
            list.append(slashComments)
        case .python, .shell:
            list.append(hashComments)
        case .json:
            list.append(SyntaxRule(pattern: #"\"(?:\\.|[^\"\\])*\"\s*(?=:)"#, color: type))
        case .html:
            list.append(SyntaxRule(pattern: #"</?[A-Za-z][^>]*>"#, color: type))
            list.append(SyntaxRule(pattern: #"<!--[\s\S]*?-->"#, color: comment))
        case .css:
            list.append(SyntaxRule(pattern: #"[#.]?[A-Za-z_-][A-Za-z0-9_-]*(?=\s*\{)"#, color: type))
            list.append(SyntaxRule(pattern: #"/\*[\s\S]*?\*/"#, color: comment))
        case .markdown:
            list.append(SyntaxRule(pattern: #"^#{1,6}\s+.*$"#, color: type, options: [.anchorsMatchLines]))
            list.append(SyntaxRule(pattern: #"`[^`]+`|\*\*[^*]+\*\*"#, color: keyword))
        case .yaml:
            list.append(SyntaxRule(pattern: #"^[\s-]*[A-Za-z0-9_.-]+(?=:)"#, color: type, options: [.anchorsMatchLines]))
            list.append(hashComments)
        case .plainText:
            break
        }
        return list
    }
}

@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    var errorLines: Set<Int> = []
    var gitAddedLines: Set<Int> = []
    var gitModifiedLines: Set<Int> = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 45
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPalette.background.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.42, alpha: 1)
        ]

        var characterIndex = 0
        var lineNumber = 1
        while characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let isError = errorLines.contains(lineNumber)
            let isGitAdded = gitAddedLines.contains(lineNumber)
            let isGitModified = gitModifiedLines.contains(lineNumber)

            if NSLocationInRange(glyphIndex, visibleGlyphRange) {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY

                // Git diff gutter mark (leftmost 3pt line)
                if isGitAdded {
                    let markRect = NSRect(x: 1, y: y, width: 3, height: lineRect.height)
                    NSColor.systemGreen.setFill()
                    markRect.fill()
                } else if isGitModified {
                    let markRect = NSRect(x: 1, y: y, width: 3, height: lineRect.height)
                    NSColor.systemBlue.setFill()
                    markRect.fill()
                }

                if isError {
                    let dotRect = NSRect(x: 6, y: y + 4, width: 5, height: 5)
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                }

                let lineAttrs: [NSAttributedString.Key: Any] = isError ? [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.systemRed
                ] : attributes
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: lineAttrs)
                label.draw(
                    at: NSPoint(x: ruleThickness - labelSize.width - 8, y: y + 1),
                    withAttributes: lineAttrs
                )
            } else if glyphIndex > NSMaxRange(visibleGlyphRange) {
                break
            }
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        if text.length == 0 || text.hasSuffix("\n") {
            let isError = errorLines.contains(lineNumber)
            let isGitAdded = gitAddedLines.contains(lineNumber)
            let isGitModified = gitModifiedLines.contains(lineNumber)
            let lineRect = layoutManager.extraLineFragmentRect
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY

            if isGitAdded {
                let markRect = NSRect(x: 1, y: y, width: 3, height: max(lineRect.height, 16))
                NSColor.systemGreen.setFill()
                markRect.fill()
            } else if isGitModified {
                let markRect = NSRect(x: 1, y: y, width: 3, height: max(lineRect.height, 16))
                NSColor.systemBlue.setFill()
                markRect.fill()
            }

            if isError {
                let dotRect = NSRect(x: 6, y: y + 4, width: 5, height: 5)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            let lineAttrs: [NSAttributedString.Key: Any] = isError ? [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.systemRed
            ] : attributes
            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: lineAttrs)
            label.draw(at: NSPoint(x: ruleThickness - labelSize.width - 8, y: y + 1), withAttributes: lineAttrs)
        }
    }
}

@MainActor
final class EditorTextView: NSTextView {
    var isHighlightingCurrentLine = true

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard isHighlightingCurrentLine,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let selection = selectedRange()
        guard selection.length == 0 else { return }

        let nsText = (string as NSString)
        guard selection.location <= nsText.length else { return }

        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

        lineRect.origin.x = 0
        lineRect.size.width = max(bounds.width, enclosingScrollView?.contentSize.width ?? bounds.width)
        lineRect.origin.y += textContainerOrigin.y

        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.07).setFill()
        lineRect.fill()
    }
}
