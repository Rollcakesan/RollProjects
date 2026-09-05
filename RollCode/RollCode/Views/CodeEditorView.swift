import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        context.coordinator.applyHighlighting(language: language)
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

        if textView.backgroundColor != EditorPalette.background {
            textView.backgroundColor = EditorPalette.background
            textView.insertionPointColor = EditorPalette.caret
            textView.textColor = EditorPalette.foreground
            textView.selectedTextAttributes = [
                .backgroundColor: EditorPalette.selection,
                .foregroundColor: EditorPalette.foreground
            ]
        }

        if !context.coordinator.isInternalTextChange && textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
        context.coordinator.applyHighlighting(language: language)
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
            applyHighlighting(language: parent.language)
            ruler?.needsDisplay = true

            scheduleCompletion(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
            ruler?.needsDisplay = true

            if suggestionController.isVisible {
                guard let textView,
                      textView.selectedRange().location == suggestionController.prefixRange.location + suggestionController.prefixRange.length else {
                    suggestionController.hide()
                    return
                }
            }
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
            applyHighlighting(language: parent.language)
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
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let selectedRange = textView.selectedRange()
                let loc = selectedRange.location
                let nsText = textView.string as NSString
                guard selectedRange.length == 0, loc >= 1, loc <= nsText.length else {
                    self.suggestionController.hide()
                    return
                }
                guard let char = UnicodeScalar(nsText.character(at: loc - 1)),
                      char == "." || CharacterSet.alphanumerics.contains(char) || char == "_" else {
                    self.suggestionController.hide()
                    return
                }
                let isDot = (char == ".")

                let lineRange = nsText.lineRange(for: NSRange(location: loc, length: 0))
                let prefixRange = NSRange(location: lineRange.location, length: loc - lineRange.location)
                let linePrefix = nsText.substring(with: prefixRange)

                // Calculate 1-based line and 0-based character column
                var lineNumber = 1
                var scanLoc = 0
                while scanLoc < lineRange.location {
                    scanLoc = NSMaxRange(nsText.lineRange(for: NSRange(location: scanLoc, length: 0)))
                    lineNumber += 1
                }
                let columnNumber = loc - lineRange.location

                let lastWord: String
                let wordRange: NSRange
                if isDot {
                    lastWord = ""
                    wordRange = NSRange(location: loc, length: 0)
                } else {
                    let delimiters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
                    guard let word = linePrefix.components(separatedBy: delimiters).last, !word.isEmpty else {
                        self.suggestionController.hide()
                        return
                    }
                    lastWord = word
                    wordRange = NSRange(location: loc - word.utf16.count, length: word.utf16.count)
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

                guard !Task.isCancelled, textView.selectedRange().location == loc else { return }

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

        func handleNavigationRequest(_ request: EditorNavigationRequest?) {
            guard let request, request.id != lastNavigationRequestID, let textView else { return }
            lastNavigationRequestID = request.id
            if let range = lineRange(forLine: request.line, in: textView.string as NSString) {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
        }

        func applyHighlighting(language: CodeLanguage) {
            guard let textStorage = textView?.textStorage, textStorage.length > 0 else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)

            isApplyingAttributes = true
            textStorage.beginEditing()
            textStorage.setAttributes([
                .font: EditorPalette.font(size: parent.fontSize),
                .foregroundColor: EditorPalette.foreground,
                .backgroundColor: EditorPalette.background,
                .paragraphStyle: EditorPalette.paragraphStyle(tabWidth: parent.tabWidth, fontSize: parent.fontSize)
            ], range: fullRange)

            for rule in SyntaxRules.rules(for: language) {
                for match in rule.regex.matches(in: textStorage.string, range: fullRange) {
                    textStorage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
                }
            }

            for errorLine in parent.errorLines {
                if let range = lineRange(forLine: errorLine, in: textStorage.string as NSString) {
                    textStorage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18), range: range)
                    textStorage.addAttribute(.underlineColor, value: NSColor.systemRed, range: range)
                    textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            textStorage.endEditing()
            isApplyingAttributes = false
        }

        private func lineRange(forLine targetLine: Int, in string: NSString) -> NSRange? {
            var line = 1, loc = 0
            while loc < string.length {
                let range = string.lineRange(for: NSRange(location: loc, length: 0))
                if line == targetLine { return range }
                loc = NSMaxRange(range)
                line += 1
            }
            return (targetLine == 1 && string.length == 0) ? NSRange(location: 0, length: 0) : nil
        }
    }
}

@MainActor
private enum EditorPalette {
    static var background: NSColor { RollCodeTheme.nsEditorBackground }
    static var foreground: NSColor { RollCodeTheme.nsForeground }
    static var caret: NSColor { RollCodeTheme.nsCaret }
    static var selection: NSColor { RollCodeTheme.nsSelection }
    static func font(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func paragraphStyle(tabWidth: Int, fontSize: CGFloat = 14.5) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font(size: fontSize)]).width * CGFloat(tabWidth)
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
    static func rules(for language: CodeLanguage) -> [SyntaxRule] {
        var list = [
            SyntaxRule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: NSColor(red: 0.92, green: 0.68, blue: 0.43, alpha: 1)),
            SyntaxRule(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: NSColor(red: 0.72, green: 0.86, blue: 0.56, alpha: 1))
        ]
        let words = language.standardKeywords
        if !words.isEmpty {
            list.append(SyntaxRule(pattern: #"\b("# + words.joined(separator: "|") + #")\b"#, color: NSColor(red: 0.78, green: 0.48, blue: 0.92, alpha: 1)))
        }
        let commentPattern = (language == .python || language == .shell || language == .yaml) ? #"#.*$"# : #"//.*$|/\*[\s\S]*?\*/"#
        list.append(SyntaxRule(pattern: commentPattern, color: NSColor(red: 0.43, green: 0.48, blue: 0.52, alpha: 1), options: [.anchorsMatchLines]))
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
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        let normalAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(white: 0.42, alpha: 1)]
        let errAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemRed]

        func drawRow(y: CGFloat, h: CGFloat, line: Int) {
            if gitAddedLines.contains(line) || gitModifiedLines.contains(line) {
                (gitAddedLines.contains(line) ? NSColor.systemGreen : NSColor.systemBlue).setFill()
                NSRect(x: 1, y: y, width: 3, height: h).fill()
            }
            let isErr = errorLines.contains(line)
            if isErr {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: y + 4, width: 5, height: 5)).fill()
            }
            let attrs = isErr ? errAttrs : normalAttrs
            ("\(line)" as NSString).draw(at: NSPoint(x: ruleThickness - ("\(line)" as NSString).size(withAttributes: attrs).width - 8, y: y + 1), withAttributes: attrs)
        }

        var charIdx = 0, line = 1
        while charIdx < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIdx)
            if NSLocationInRange(glyphIdx, visibleGlyphRange) {
                let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                drawRow(y: rect.minY + textView.textContainerOrigin.y - visibleRect.minY, h: rect.height, line: line)
            } else if glyphIdx > NSMaxRange(visibleGlyphRange) { break }
            charIdx = NSMaxRange(lineRange)
            line += 1
        }
        if text.length == 0 || text.hasSuffix("\n") {
            let rect = layoutManager.extraLineFragmentRect
            drawRow(y: rect.minY + textView.textContainerOrigin.y - visibleRect.minY, h: max(rect.height, 16), line: line)
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
              self.textContainer != nil else { return }

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
