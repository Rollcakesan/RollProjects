import AppKit
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var rootNode: FileNode?
    @Published var documents: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    @Published var fileFilter = ""
    @Published var alertMessage: String?
    @Published private(set) var isLoadingTree = false

    var onWorkspaceChanged: ((URL) -> Void)?

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    var hasUnsavedDocuments: Bool {
        documents.contains(where: \.isDirty)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open a folder in RollCode"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(url)
    }

    func openWorkspace(_ url: URL) {
        rootURL = url
        fileFilter = ""
        refreshTree()
        onWorkspaceChanged?(url)
    }

    func refreshTree() {
        guard let rootURL else { return }
        isLoadingTree = true
        Task { [weak self] in
            let tree = await Task.detached(priority: .userInitiated) {
                FileNode.buildTree(at: rootURL)
            }.value
            guard let self, self.rootURL == rootURL else { return }
            self.rootNode = tree
            self.isLoadingTree = false
        }
    }

    func openFile(_ url: URL) {
        if let existing = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            activeDocumentID = existing.id
            return
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 5_000_000 else {
                throw WorkspaceError.fileTooLarge
            }
            guard !data.prefix(8_192).contains(0), let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceError.notUTF8Text
            }
            let document = EditorDocument(url: url, text: text)
            documents.append(document)
            activeDocumentID = document.id
        } catch {
            alertMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func createFile() {
        let panel = NSSavePanel()
        panel.title = "Create a new file"
        panel.prompt = "Create"
        panel.directoryURL = rootURL
        panel.nameFieldStringValue = "untitled.swift"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw WorkspaceError.fileAlreadyExists
            }
            try Data().write(to: url, options: .atomic)
            refreshTree()
            openFile(url)
        } catch {
            alertMessage = "Could not create the file: \(error.localizedDescription)"
        }
    }

    func saveActiveDocument() {
        guard let activeDocument else { return }
        _ = save(activeDocument)
    }

    func saveActiveDocumentAs() {
        guard let document = activeDocument else { return }
        let panel = NSSavePanel()
        panel.title = "Save file as"
        panel.prompt = "Save"
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.nameFieldStringValue = document.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try document.text.write(to: destination, atomically: true, encoding: .utf8)
            document.url = destination
            document.markSaved()
            refreshTree()
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.markSaved()
            return true
        } catch {
            alertMessage = "Could not save \(document.name): \(error.localizedDescription)"
            return false
        }
    }

    func saveAllDocuments() -> Bool {
        documents.filter(\.isDirty).allSatisfy { save($0) }
    }

    func closeDocument(_ document: EditorDocument) {
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(document.name)?"
            alert.informativeText = "Your changes will be lost if you close this tab without saving."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard save(document) else { return }
            case .alertThirdButtonReturn:
                break
            default:
                return
            }
        }

        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if activeDocumentID == document.id {
            activeDocumentID = documents.indices.contains(index) ? documents[index].id : documents.last?.id
        }
    }
}

private enum WorkspaceError: LocalizedError {
    case fileTooLarge
    case notUTF8Text
    case fileAlreadyExists

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "Files larger than 5 MB are not supported."
        case .notUTF8Text: return "The file is binary or is not UTF-8 text."
        case .fileAlreadyExists: return "A file with that name already exists."
        }
    }
}
