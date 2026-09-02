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
    @Published var isQuickOpenPresented = false
    @Published private(set) var tabWidth: Int
    @Published private(set) var isLoadingTree = false

    var onWorkspaceChanged: ((URL) -> Void)?
    private let defaults: UserDefaults
    private var isCheckingExternalChanges = false
    private static let lastWorkspacePathKey = "RollCode.lastWorkspacePath"
    private static let tabWidthKey = "RollCode.editorTabWidth"

    init(defaults: UserDefaults = .standard, restoresLastWorkspace: Bool = true) {
        self.defaults = defaults
        let savedTabWidth = defaults.integer(forKey: Self.tabWidthKey)
        self.tabWidth = [2, 4, 8].contains(savedTabWidth) ? savedTabWidth : 4
        guard restoresLastWorkspace,
              let path = defaults.string(forKey: Self.lastWorkspacePathKey) else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            defaults.removeObject(forKey: Self.lastWorkspacePathKey)
            return
        }
        openWorkspace(URL(fileURLWithPath: path, isDirectory: true))
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    var hasUnsavedDocuments: Bool {
        documents.contains(where: \.isDirty)
    }

    var workspaceFiles: [FileNode] {
        rootNode?.flattenedFiles ?? []
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
        let standardizedURL = url.standardizedFileURL
        rootURL = standardizedURL
        fileFilter = ""
        defaults.set(standardizedURL.path, forKey: Self.lastWorkspacePathKey)
        refreshTree()
        onWorkspaceChanged?(standardizedURL)
    }

    func presentQuickOpen() {
        guard rootURL != nil else {
            chooseFolder()
            return
        }
        isQuickOpenPresented = true
    }

    func setTabWidth(_ width: Int) {
        guard [2, 4, 8].contains(width) else { return }
        tabWidth = width
        defaults.set(width, forKey: Self.tabWidthKey)
    }

    func quickOpenFiles(matching query: String) -> [FileNode] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = workspaceFiles
        guard !normalized.isEmpty else { return Array(files.prefix(100)) }

        return files
            .compactMap { node -> (node: FileNode, path: String, score: Int)? in
                let path = relativePath(for: node.url)
                guard let score = QuickOpenMatcher.score(query: normalized, candidate: path) else { return nil }
                return (node, path, score)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(100)
            .map(\.node)
    }

    func relativePath(for url: URL) -> String {
        guard let rootURL else { return url.path }
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.path }
        return String(url.path.dropFirst(rootPath.count))
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
            let document = EditorDocument(url: url, text: text, diskModificationDate: modificationDate(for: url))
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
            document.markSaved(modificationDate: modificationDate(for: destination))
            refreshTree()
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.markSaved(modificationDate: modificationDate(for: document.url))
            return true
        } catch {
            alertMessage = "Could not save \(document.name): \(error.localizedDescription)"
            return false
        }
    }

    func saveAllDocuments() -> Bool {
        documents.filter(\.isDirty).allSatisfy { save($0) }
    }

    func closeActiveDocument() {
        guard let activeDocument else { return }
        closeDocument(activeDocument)
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

    func checkForExternalChanges() {
        guard !isCheckingExternalChanges else { return }
        isCheckingExternalChanges = true
        defer { isCheckingExternalChanges = false }

        for document in documents {
            guard FileManager.default.fileExists(atPath: document.url.path) else {
                if document.diskModificationDate != nil {
                    document.recordDiskModificationDate(nil)
                    alertMessage = "\(document.name) was removed outside RollCode. Your open editor content is still available."
                }
                continue
            }

            let currentDate = modificationDate(for: document.url)
            guard currentDate != document.diskModificationDate,
                  let data = try? Data(contentsOf: document.url),
                  let diskText = String(data: data, encoding: .utf8) else { continue }

            if diskText == document.text {
                document.markSaved(modificationDate: currentDate)
                continue
            }

            if !document.isDirty {
                document.replaceFromDisk(text: diskText, modificationDate: currentDate)
                continue
            }

            let alert = NSAlert()
            alert.messageText = "\(document.name) changed on disk."
            alert.informativeText = "Reload the file or keep the changes currently open in RollCode?"
            alert.addButton(withTitle: "Keep Editor Version")
            alert.addButton(withTitle: "Reload from Disk")
            if alert.runModal() == .alertSecondButtonReturn {
                document.replaceFromDisk(text: diskText, modificationDate: currentDate)
            } else {
                document.recordDiskModificationDate(currentDate)
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func requestRename(_ url: URL) {
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.selectText(nil)

        let alert = NSAlert()
        alert.messageText = "Rename \(url.lastPathComponent)"
        alert.informativeText = "Enter a new name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try renameItem(at: url, to: field.stringValue)
        } catch {
            alertMessage = "Could not rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func renameItem(at source: URL, to newName: String) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != ".",
              trimmedName != "..",
              !trimmedName.contains("/") else {
            throw WorkspaceError.invalidFileName
        }

        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmedName)
        guard destination != source else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceError.fileAlreadyExists
        }

        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        try FileManager.default.moveItem(at: source, to: destination)
        for document in documents {
            if document.url == source {
                document.url = destination
            } else if document.url.path.hasPrefix(sourcePrefix) {
                let suffix = String(document.url.path.dropFirst(sourcePrefix.count))
                document.url = destination.appendingPathComponent(suffix)
            }
        }
        refreshTree()
    }

    private func modificationDate(for url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}

private enum WorkspaceError: LocalizedError {
    case fileTooLarge
    case notUTF8Text
    case fileAlreadyExists
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "Files larger than 5 MB are not supported."
        case .notUTF8Text: return "The file is binary or is not UTF-8 text."
        case .fileAlreadyExists: return "A file with that name already exists."
        case .invalidFileName: return "Enter a valid file or folder name."
        }
    }
}
