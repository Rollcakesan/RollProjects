import SwiftUI

struct ShortcutItem: Identifiable, Sendable {
    let id = UUID()
    let category: String
    let title: String
    let keys: [String]
}

struct ShortcutCheatSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let shortcuts: [ShortcutItem] = [
        // Navigation & Files
        ShortcutItem(category: "Files & Navigation", title: "Quick Open file", keys: ["⌘", "P"]),
        ShortcutItem(category: "Files & Navigation", title: "Go to line", keys: ["⌘", "L"]),
        ShortcutItem(category: "Files & Navigation", title: "Search project files", keys: ["⇧", "⌘", "F"]),
        ShortcutItem(category: "Files & Navigation", title: "Git changes & review", keys: ["⇧", "⌘", "G"]),
        ShortcutItem(category: "Files & Navigation", title: "Find in current file", keys: ["⌘", "F"]),
        ShortcutItem(category: "Files & Navigation", title: "Save active file", keys: ["⌘", "S"]),
        ShortcutItem(category: "Files & Navigation", title: "Save file as…", keys: ["⇧", "⌘", "S"]),
        ShortcutItem(category: "Files & Navigation", title: "Close active tab", keys: ["⌘", "W"]),
        ShortcutItem(category: "Files & Navigation", title: "New file", keys: ["⌘", "N"]),

        // Editing & Indentation
        ShortcutItem(category: "Editing", title: "Multi-line Indent", keys: ["Tab"]),
        ShortcutItem(category: "Editing", title: "Multi-line Dedent", keys: ["⇧", "Tab"]),
        ShortcutItem(category: "Editing", title: "Soft Tab Backspace", keys: ["⌫"]),
        ShortcutItem(category: "Editing", title: "Undo", keys: ["⌘", "Z"]),
        ShortcutItem(category: "Editing", title: "Redo", keys: ["⇧", "⌘", "Z"]),
        ShortcutItem(category: "Editing", title: "Accept Code Completion", keys: ["Tab", "/", "↩"]),
        ShortcutItem(category: "Editing", title: "Dismiss Completion", keys: ["Esc"]),

        // Zoom & View
        ShortcutItem(category: "View & Panes", title: "Zoom in", keys: ["⌘", "+"]),
        ShortcutItem(category: "View & Panes", title: "Zoom out", keys: ["⌘", "-"]),
        ShortcutItem(category: "View & Panes", title: "Reset zoom", keys: ["⌘", "0"]),
        ShortcutItem(category: "View & Panes", title: "Toggle Terminal panel", keys: ["⌃", "`"]),
        ShortcutItem(category: "View & Panes", title: "Toggle AI Agent panel", keys: ["⌘", "J"]),
        ShortcutItem(category: "View & Panes", title: "Settings", keys: ["⌘", ","]),
        ShortcutItem(category: "View & Panes", title: "Keyboard Shortcuts", keys: ["⌘", "?"]),

        // AI Agent
        ShortcutItem(category: "AI Agent", title: "Reference project file", keys: ["@"]),
        ShortcutItem(category: "AI Agent", title: "Send prompt", keys: ["↩"]),
        ShortcutItem(category: "AI Agent", title: "New conversation thread", keys: ["+"]),
    ]

    private var filteredShortcuts: [ShortcutItem] {
        searchText.isEmpty ? shortcuts : shortcuts.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText) ||
            $0.keys.joined().localizedCaseInsensitiveContains(searchText)
        }
    }

    private var categories: [String] {
        filteredShortcuts.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Keyboard Shortcuts", systemImage: "command")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RollCodeTheme.primaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                TextField("Search shortcuts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RollCodeTheme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RollCodeTheme.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(RollCodeTheme.divider))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider().overlay(RollCodeTheme.divider)

            // List
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(categories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(RollCodeTheme.accent)
                                .padding(.horizontal, 4)

                            VStack(spacing: 1) {
                                ForEach(filteredShortcuts.filter { $0.category == category }) { item in
                                    HStack {
                                        Text(item.title)
                                            .font(.system(size: 12))
                                            .foregroundStyle(RollCodeTheme.primaryText)
                                        Spacer()
                                        HStack(spacing: 3) {
                                            ForEach(item.keys, id: \.self) { key in
                                                Text(key)
                                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(RollCodeTheme.elevatedBackground)
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(RollCodeTheme.divider, lineWidth: 1)
                                                    )
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                }
                            }
                            .background(RollCodeTheme.windowBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(RollCodeTheme.divider))
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 480)
        .background(.ultraThinMaterial)
    }
}
