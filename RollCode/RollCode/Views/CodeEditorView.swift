import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let searchTerm: String
    let searchRequest: EditorSearchRequest?
    let navigationRequest: EditorNavigationRequest?
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

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let editorFont = EditorPalette.font(size: fontSize)
        if textView.font != editorFont {
            textView.font = editorFont
            textView.typingAttributes[.font] = editorFont
        }
        let paragraphStyle = EditorPalette.paragraphStyle(tabWidth: tabWidth, fontSize: fontSize)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
        context.coordinator.applyHighlighting(language: language, searchTerm: searchTerm)
        context.coordinator.handleSearchRequest(searchRequest, query: searchTerm)
        context.coordinator.handleNavigationRequest(navigationRequest)
        context.coordinator.ruler?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        private var isApplyingAttributes = false
        private var isPerformingSmartEdit = false
        private var lastSearchRequestID: UUID?
        private var lastNavigationRequestID: UUID?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingAttributes, let textView else { return }
            parent.text = textView.string
            applyHighlighting(language: parent.language, searchTerm: parent.searchTerm)
            ruler?.needsDisplay = true
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

            isPerformingSmartEdit = true
            textView.insertText(edit.replacement, replacementRange: affectedCharRange)
            textView.setSelectedRange(edit.selection)
            isPerformingSmartEdit = false
            parent.text = textView.string
            applyHighlighting(language: parent.language, searchTerm: parent.searchTerm)
            ruler?.needsDisplay = true
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
            guard let textStorage = textView?.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            guard fullRange.length > 0 else { return }

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

            if !searchTerm.isEmpty,
               let expression = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: searchTerm),
                options: [.caseInsensitive]
               ) {
                for match in expression.matches(in: textStorage.string, range: fullRange) {
                    textStorage.addAttribute(.backgroundColor, value: EditorPalette.searchMatch, range: match.range)
                    textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: match.range)
                }
            }
            textStorage.endEditing()
            isApplyingAttributes = false
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

    static func paragraphStyle(tabWidth: Int, fontSize: CGFloat = 12.5) -> NSParagraphStyle {
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

    private static let rulesByLanguage: [CodeLanguage: [SyntaxRule]] = {
        let common = [
            SyntaxRule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: number),
            SyntaxRule(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: string),
        ]
        var dict: [CodeLanguage: [SyntaxRule]] = [:]
        dict[.swift] = common + [
            SyntaxRule(pattern: #"\b(import|struct|class|enum|protocol|extension|func|var|let|if|else|guard|switch|case|for|while|return|throw|throws|try|await|async|actor|private|public|internal|fileprivate|static|final|some|any|in|where|nil|true|false|self|Self)\b"#, color: keyword),
            SyntaxRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, color: type),
            slashComments
        ]
        dict[.javascript] = common + [
            SyntaxRule(pattern: #"\b(const|let|var|function|class|interface|type|extends|implements|if|else|switch|case|for|while|return|throw|try|catch|finally|async|await|import|export|from|new|this|null|undefined|true|false)\b"#, color: keyword),
            slashComments
        ]
        dict[.typescript] = dict[.javascript]
        dict[.python] = common + [
            SyntaxRule(pattern: #"\b(and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|not|or|pass|raise|return|True|try|while|with|yield)\b"#, color: keyword),
            hashComments
        ]
        dict[.shell] = common + [
            SyntaxRule(pattern: #"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|in|export|local)\b"#, color: keyword),
            hashComments
        ]
        dict[.json] = common + [
            SyntaxRule(pattern: #"\"(?:\\.|[^\"\\])*\"\s*(?=:)"#, color: type),
            SyntaxRule(pattern: #"\b(true|false|null)\b"#, color: keyword)
        ]
        dict[.html] = common + [
            SyntaxRule(pattern: #"</?[A-Za-z][^>]*>"#, color: type),
            SyntaxRule(pattern: #"<!--[\s\S]*?-->"#, color: comment)
        ]
        dict[.css] = common + [
            SyntaxRule(pattern: #"[#.]?[A-Za-z_-][A-Za-z0-9_-]*(?=\s*\{)"#, color: type),
            SyntaxRule(pattern: #"/\*[\s\S]*?\*/"#, color: comment)
        ]
        dict[.markdown] = common + [
            SyntaxRule(pattern: #"^#{1,6}\s+.*$"#, color: type, options: [.anchorsMatchLines]),
            SyntaxRule(pattern: #"`[^`]+`|\*\*[^*]+\*\*"#, color: keyword)
        ]
        dict[.cFamily] = common + [
            SyntaxRule(pattern: #"\b(auto|break|case|char|class|const|continue|default|delete|do|double|else|enum|explicit|extern|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|return|short|signed|sizeof|static|struct|switch|template|this|throw|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while)\b"#, color: keyword),
            slashComments
        ]
        dict[.go] = common + [
            SyntaxRule(pattern: #"\b(break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|nil|true|false)\b"#, color: keyword),
            slashComments
        ]
        dict[.rust] = common + [
            SyntaxRule(pattern: #"\b(as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|unsafe|use|where|while)\b"#, color: keyword),
            slashComments
        ]
        dict[.yaml] = common + [
            SyntaxRule(pattern: #"^[\s-]*[A-Za-z0-9_.-]+(?=:)"#, color: type, options: [.anchorsMatchLines]),
            hashComments,
            SyntaxRule(pattern: #"\b(true|false|yes|no|null)\b"#, color: keyword)
        ]
        dict[.plainText] = common
        return dict
    }()

    static func rules(for language: CodeLanguage) -> [SyntaxRule] {
        rulesByLanguage[language] ?? rulesByLanguage[.plainText] ?? []
    }
}

@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

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
            if NSLocationInRange(glyphIndex, visibleGlyphRange) {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
                label.draw(
                    at: NSPoint(x: ruleThickness - labelSize.width - 8, y: y + 1),
                    withAttributes: attributes
                )
            } else if glyphIndex > NSMaxRange(visibleGlyphRange) {
                break
            }
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        if text.length == 0 || text.hasSuffix("\n") {
            let lineRect = layoutManager.extraLineFragmentRect
            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            label.draw(at: NSPoint(x: ruleThickness - labelSize.width - 8, y: y + 1), withAttributes: attributes)
        }
    }
}
