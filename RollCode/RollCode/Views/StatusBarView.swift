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
            Spacer()
            if let document = workspace.activeDocument {
                ActiveDocumentStatus(document: document)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(RollCodeTheme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(RollCodeTheme.windowBackground)
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
            Text("UTF-8")
        }
    }

    private var fontSizeText: String {
        let size = workspace.fontSize
        return size == floor(size) ? "\(Int(size)) pt" : String(format: "%.1f pt", size)
    }
}
