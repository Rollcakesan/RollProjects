import SwiftUI

struct StatusBarView: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        HStack(spacing: 14) {
            if let rootURL = workspace.rootURL {
                Label(rootURL.lastPathComponent, systemImage: "folder")
            } else {
                Text("No folder open")
            }

            if let branch = workspace.currentBranch {
                Menu {
                    ForEach(workspace.branches, id: \.self) { b in
                        Button {
                            workspace.switchBranch(to: b)
                        } label: {
                            HStack {
                                Text(b)
                                if b == branch {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch)
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Current Branch: \(branch). Click to switch.")
            }

            if let document = workspace.activeDocument {
                if document.isCheckingSyntax {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Checking syntax…")
                            .font(.system(size: 9))
                    }
                } else if !document.diagnostics.isEmpty {
                    let first = document.diagnostics[0]
                    Button {
                        workspace.navigateTo(line: first.line)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.red)
                            Text("Line \(first.line): \(first.message)")
                                .lineLimit(1)
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(document.diagnostics.map { "Line \($0.line): \($0.message)" }.joined(separator: "\n"))
                }
            }

            Spacer()
            if let document = workspace.activeDocument {
                ActiveDocumentStatus(document: document)
            }
        }
        .font(.system(size: max(workspace.uiFontSize - 1.5, 9.5)))
        .foregroundStyle(RollCodeTheme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(.bar)
        .overlay(alignment: .top) { RollCodeTheme.divider.frame(height: 1) }
    }
}

private struct ActiveDocumentStatus: View {
    @Environment(WorkspaceModel.self) private var workspace
    let document: EditorDocument

    var body: some View {
        Group {
            Text(document.language.displayName)
            Text("\(document.lineCount) lines")
            Text(fontSizeText)
            Text(document.encodingDisplayName)
        }
    }

    private var fontSizeText: String {
        let size = workspace.fontSize
        return size == floor(size) ? "\(Int(size)) pt" : String(format: "%.1f pt", size)
    }
}
