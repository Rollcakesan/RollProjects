import AppKit
import SwiftUI

@MainActor
final class SuggestionOverlayController {
    private var window: NSWindow?
    private weak var textView: NSTextView?
    private var hostingView: NSHostingView<SuggestionListView>?

    private(set) var suggestions: [String] = []
    private(set) var selectedIndex: Int = 0
    private(set) var prefixRange: NSRange = NSRange(location: NSNotFound, length: 0)

    var isVisible: Bool {
        window?.isVisible == true && !suggestions.isEmpty
    }

    func show(suggestions: [String], prefixRange: NSRange, in textView: NSTextView) {
        guard !suggestions.isEmpty else {
            hide()
            return
        }
        self.suggestions = suggestions
        self.selectedIndex = 0
        self.prefixRange = prefixRange
        self.textView = textView

        let content = SuggestionListView(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            onSelect: { [weak self] chosen in
                self?.commit(chosen)
            }
        )

        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            self.hostingView = hv
        }

        guard let parentWindow = textView.window else { return }

        if window == nil {
            let win = NonActivatingSuggestionWindow(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.level = .floating
            win.contentView = hostingView
            self.window = win
        }

        updateFrame(in: textView, parentWindow: parentWindow)

        if window?.parent == nil {
            parentWindow.addChildWindow(window!, ordered: .above)
        }
        window?.orderFront(nil)
    }

    func hide() {
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window?.orderOut(nil)
        suggestions = []
        selectedIndex = 0
        prefixRange = NSRange(location: NSNotFound, length: 0)
    }

    func selectNext() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % suggestions.count
        updateView()
    }

    func selectPrevious() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + suggestions.count) % suggestions.count
        updateView()
    }

    func commitSelected() -> Bool {
        guard isVisible, selectedIndex < suggestions.count else { return false }
        commit(suggestions[selectedIndex])
        return true
    }

    private func commit(_ word: String) {
        guard let textView, prefixRange.location != NSNotFound else { return }
        let nsText = textView.string as NSString
        guard prefixRange.location + prefixRange.length <= nsText.length else { return }

        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        textView.insertText(word, replacementRange: prefixRange)
        undoManager?.endUndoGrouping()
        hide()
    }

    private func updateView() {
        hostingView?.rootView = SuggestionListView(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            onSelect: { [weak self] chosen in
                self?.commit(chosen)
            }
        )
    }

    private func updateFrame(in textView: NSTextView, parentWindow: NSWindow) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              prefixRange.location != NSNotFound else { return }

        let nsText = textView.string as NSString
        let validRange = NSRange(
            location: min(prefixRange.location, nsText.length),
            length: min(prefixRange.length, max(0, nsText.length - prefixRange.location))
        )
        let glyphRange = layoutManager.glyphRange(forCharacterRange: validRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let screenRect = textView.convert(rect, to: nil)
        let windowScreenRect = parentWindow.convertToScreen(screenRect)

        let width: CGFloat = 220
        let itemHeight: CGFloat = 22
        let height: CGFloat = min(CGFloat(suggestions.count) * itemHeight + 10, 150)
        let popupFrame = NSRect(
            x: max(windowScreenRect.minX - 4, 10),
            y: max(windowScreenRect.minY - height - 4, 10),
            width: width,
            height: height
        )
        window?.setFrame(popupFrame, display: true)
    }
}

private final class NonActivatingSuggestionWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SuggestionListView: View {
    let suggestions: [String]
    let selectedIndex: Int
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                        let isSelected = (index == selectedIndex)
                        HStack(spacing: 6) {
                            Image(systemName: "text.cursor")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? Color.white : RollCodeTheme.secondaryText)
                            Text(item)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : RollCodeTheme.primaryText)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isSelected ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                        .id(index)
                        .onTapGesture {
                            onSelect(item)
                        }
                    }
                }
                .padding(3)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex, anchor: .center)
            }
        }
        .background(RollCodeTheme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(RollCodeTheme.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}
