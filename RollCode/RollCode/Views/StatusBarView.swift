import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

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
    @ObservedObject var document: EditorDocument

    var body: some View {
        Group {
            Text(document.language.displayName)
            Text("\(document.text.components(separatedBy: .newlines).count) lines")
            Text("UTF-8")
        }
    }
}
