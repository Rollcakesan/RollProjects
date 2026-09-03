import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceModel {
    private(set) var rootURL: URL?
    private(set) var rootNode: FileNode?
    var documents: [EditorDocument] = []
    var activeDocumentID: UUID?
    var fileFilter = ""
    var alertMessage: String?
    var isQuickOpenPresented = false
    var isWorkspaceSearchPresented = false
    var isGitChangesPresented = false
    var isShortcutCheatSheetPresented = false
    var isFolderPickerPresented = false
    var editorNavigationRequest: EditorNavigationRequest?
    var renamingURL: URL?
    var renamingName = ""
    var creatingItemParentURL: URL?
    var creatingItemIsDirectory = false
    var creatingItemName = ""
    var deletingURL: URL?
    var unconfirmedClosingDocument: EditorDocument?
    var externalConflict: ExternalConflict?
    var isSavingActiveDocumentAs = false
    private var savingDocumentID: UUID?
    private(set) var fontSize: CGFloat
    private(set) var tabWidth: Int
    private(set) var restoresLastWorkspace: Bool
    private(set) var isLoadingTree = false

    var onWorkspaceChanged: (@MainActor @Sendable (URL) -> Void)?
    @ObservationIgnored private var fileWatcher: FileWatcherService?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isCheckingExternalChanges = false
    private static let lastWorkspacePathKey = "RollCode.lastWorkspacePath"
    private static let restoreLastWorkspaceKey = "RollCode.restoreLastWorkspace"
    private static let tabWidthKey = "RollCode.editorTabWidth"
    private static let fontSizeKey = "RollCode.editorFontSize"

    var lastWorkspacePath: String? {
        defaults.string(forKey: Self.lastWorkspacePathKey)
    }

    init(defaults: UserDefaults = .standard, restoresLastWorkspace: Bool = true) {
        self.defaults = defaults
        let savedTabWidth = defaults.integer(forKey: Self.tabWidthKey)
        self.tabWidth = [2, 4, 8].contains(savedTabWidth) ? savedTabWidth : 4
        let savedFontSize = defaults.double(forKey: Self.fontSizeKey)
        self.fontSize = savedFontSize >= 9 && savedFontSize <= 32 ? CGFloat(savedFontSize) : 12.5
        let userPrefersRestore = defaults.object(forKey: Self.restoreLastWorkspaceKey) as? Bool ?? true
        self.restoresLastWorkspace = userPrefersRestore

        guard restoresLastWorkspace && userPrefersRestore,
              let path = defaults.string(forKey: Self.lastWorkspacePathKey) else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            defaults.removeObject(forKey: Self.lastWorkspacePathKey)
            return
        }
        openWorkspace(URL(fileURLWithPath: path, isDirectory: true))
    }

    func setRestoresLastWorkspace(_ enabled: Bool) {
        restoresLastWorkspace = enabled
        defaults.set(enabled, forKey: Self.restoreLastWorkspaceKey)
    }

    func clearLastWorkspace() {
        fileWatcher?.stopWatching()
        fileWatcher = nil
        defaults.removeObject(forKey: Self.lastWorkspacePathKey)
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

    func navigateTo(line: Int) {
        editorNavigationRequest = EditorNavigationRequest(line: line)
    }

    func chooseFolder() {
        isFolderPickerPresented = true
    }

    func openWorkspace(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        rootURL = standardizedURL
        fileFilter = ""
        defaults.set(standardizedURL.path, forKey: Self.lastWorkspacePathKey)
        refreshTree()
        fileWatcher = FileWatcherService(url: standardizedURL) { [weak self] in
            self?.refreshTree()
        }
        onWorkspaceChanged?(standardizedURL)
    }

    func presentQuickOpen() {
        guard rootURL != nil else {
            chooseFolder()
            return
        }
        isQuickOpenPresented = true
    }

    func presentWorkspaceSearch() {
        guard rootURL != nil else {
            chooseFolder()
            return
        }
        isWorkspaceSearchPresented = true
    }

    func presentGitChanges() {
        guard rootURL != nil else {
            chooseFolder()
            return
        }
        isGitChangesPresented = true
    }

    func setTabWidth(_ width: Int) {
        guard [2, 4, 8].contains(width) else { return }
        tabWidth = width
        defaults.set(width, forKey: Self.tabWidthKey)
    }

    func zoomIn() {
        setFontSize(min(fontSize + 1, 32))
    }

    func zoomOut() {
        setFontSize(max(fontSize - 1, 9))
    }

    func resetZoom() {
        setFontSize(12.5)
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 9), 32)
        defaults.set(Double(fontSize), forKey: Self.fontSizeKey)
    }

    func quickOpenFiles(matching query: String) -> [FileNode] {
        let normalized = query.trimmed
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
        url.relativePath(from: rootURL)
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
            let document = EditorDocument(url: url, text: text, diskModificationDate: url.modificationDate)
            documents.append(document)
            activeDocumentID = document.id
            updateGitDiffLines(for: document)
        } catch {
            alertMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func moveDocument(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < documents.count,
              destinationIndex >= 0, destinationIndex < documents.count,
              sourceIndex != destinationIndex else { return }
        let doc = documents.remove(at: sourceIndex)
        documents.insert(doc, at: destinationIndex)
    }

    func closeOtherDocuments(except target: EditorDocument) {
        let others = documents.filter { $0.id != target.id }
        for doc in others {
            closeDocument(doc)
        }
    }

    func closeDocumentsToTheRight(of target: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == target.id }) else { return }
        let rightDocs = Array(documents[(index + 1)...])
        for doc in rightDocs {
            closeDocument(doc)
        }
    }

    func updateGitDiffLines(for document: EditorDocument) {
        guard let rootURL else { return }
        let docName = document.name
        let docURL = document.url
        Task.detached(priority: .utility) {
            guard let change = try? GitDiffService.changes(in: rootURL).first(where: { $0.path == docName || rootURL.appending(path: $0.path) == docURL }) else {
                await MainActor.run {
                    document.gitAddedLines = []
                    document.gitModifiedLines = []
                }
                return
            }
            let (added, modified) = GitDiffService.diffLineNumbers(for: change.diff)
            await MainActor.run {
                document.gitAddedLines = added
                document.gitModifiedLines = modified
            }
        }
    }

    func createFile() {
        guard let rootURL else {
            chooseFolder()
            return
        }
        requestCreateFile(in: rootURL)
    }

    func saveActiveDocument() {
        guard let activeDocument else { return }
        _ = save(activeDocument)
    }

    func saveActiveDocumentAs() {
        guard let activeDocument else { return }
        savingDocumentID = activeDocument.id
        isSavingActiveDocumentAs = true
    }

    var documentBeingSavedAs: EditorDocument? {
        documents.first { $0.id == savingDocumentID }
    }

    func completeSaveActiveDocumentAs(destination: URL) {
        guard let document = documentBeingSavedAs else { return }
        savingDocumentID = nil
        document.url = destination
        document.markSaved(modificationDate: destination.modificationDate)
        refreshTree()
    }

    func cancelSaveActiveDocumentAs() {
        savingDocumentID = nil
    }

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.markSaved(modificationDate: document.url.modificationDate)
            updateGitDiffLines(for: document)

            // Non-blocking syntax check on save
            let docURL = document.url
            let docText = document.text
            let docLang = document.language
            Task { @MainActor [weak document] in
                guard let document else { return }
                document.isCheckingSyntax = true
                let diagnostics = await SyntaxCheckService.check(url: docURL, text: docText, language: docLang)
                document.diagnostics = diagnostics
                document.isCheckingSyntax = false
            }

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
            unconfirmedClosingDocument = document
            return
        }
        forceCloseDocument(document)
    }

    func confirmCloseDocument(save: Bool) {
        guard let document = unconfirmedClosingDocument else { return }
        unconfirmedClosingDocument = nil
        if save {
            guard self.save(document) else { return }
        }
        forceCloseDocument(document)
    }

    func cancelCloseDocument() {
        unconfirmedClosingDocument = nil
    }

    func forceCloseDocument(_ document: EditorDocument) {
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

            let currentDate = document.url.modificationDate
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

            externalConflict = ExternalConflict(
                documentID: document.id,
                documentName: document.name,
                diskText: diskText,
                modificationDate: currentDate
            )
        }
    }

    func resolveExternalConflict(reload: Bool) {
        guard let conflict = externalConflict,
              let document = documents.first(where: { $0.id == conflict.documentID }) else {
            externalConflict = nil
            return
        }
        if reload {
            document.replaceFromDisk(text: conflict.diskText, modificationDate: conflict.modificationDate)
        } else {
            document.recordDiskModificationDate(conflict.modificationDate)
        }
        externalConflict = nil
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func requestRename(_ url: URL) {
        renamingURL = url
        renamingName = url.lastPathComponent
    }

    func confirmRename() {
        guard let url = renamingURL else { return }
        let targetName = renamingName
        renamingURL = nil
        renamingName = ""

        do {
            try renameItem(at: url, to: targetName)
        } catch {
            alertMessage = "Could not rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func cancelRename() {
        renamingURL = nil
        renamingName = ""
    }

    func requestCreateFile(in parentURL: URL) {
        creatingItemParentURL = parentURL
        creatingItemIsDirectory = false
        creatingItemName = "untitled.txt"
    }

    func requestCreateFolder(in parentURL: URL) {
        creatingItemParentURL = parentURL
        creatingItemIsDirectory = true
        creatingItemName = "New Folder"
    }

    func confirmCreateItem() {
        guard let parentURL = creatingItemParentURL else { return }
        let isDirectory = creatingItemIsDirectory
        let name = creatingItemName.trimmed
        creatingItemParentURL = nil
        creatingItemName = ""

        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            alertMessage = "Please enter a valid name."
            return
        }

        let targetURL = parentURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            alertMessage = "An item named \(name) already exists."
            return
        }

        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try Data().write(to: targetURL, options: .atomic)
                openFile(targetURL)
            }
            refreshTree()
        } catch {
            alertMessage = "Could not create \(name): \(error.localizedDescription)"
        }
    }

    func cancelCreateItem() {
        creatingItemParentURL = nil
        creatingItemName = ""
    }

    func requestDeleteItem(at url: URL) {
        deletingURL = url
    }

    func cancelDeleteItem() {
        deletingURL = nil
    }

    func confirmDeleteItem() {
        guard let url = deletingURL else { return }
        deletingURL = nil
        let affectedDocuments = documents.filter { document in
            document.url == url || document.url.path.hasPrefix(url.path + "/")
        }
        guard !affectedDocuments.contains(where: \.isDirty) else {
            alertMessage = "Save or close edited files inside \(url.lastPathComponent) before moving it to Trash."
            return
        }

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            for document in affectedDocuments {
                forceCloseDocument(document)
            }
            refreshTree()
        } catch {
            alertMessage = "Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)"
        }
    }

    func renameItem(at source: URL, to newName: String) throws(WorkspaceError) {
        let trimmedName = newName.trimmed
        guard !trimmedName.isEmpty,
              trimmedName != ".",
              trimmedName != "..",
              !trimmedName.contains("/") else {
            throw .invalidFileName
        }

        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmedName)
        guard destination != source else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw .fileAlreadyExists
        }

        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw .moveFailed(error.localizedDescription)
        }

        for document in documents {
            if document.url == source {
                document.url = destination
            } else if document.url.path.hasPrefix(sourcePrefix) {
                let suffix = String(document.url.path.dropFirst(sourcePrefix.count))
                document.url = destination.appending(path: suffix)
            }
        }
        refreshTree()
    }
}

struct ExternalConflict: Equatable, Sendable {
    let documentID: UUID
    let documentName: String
    let diskText: String
    let modificationDate: Date?
}

enum WorkspaceError: LocalizedError, Sendable {
    case fileTooLarge
    case notUTF8Text
    case fileAlreadyExists
    case invalidFileName
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "Files larger than 5 MB are not supported."
        case .notUTF8Text: return "The file is binary or is not UTF-8 text."
        case .fileAlreadyExists: return "A file with that name already exists."
        case .invalidFileName: return "Enter a valid file or folder name."
        case .moveFailed(let detail): return "Could not move file: \(detail)"
        }
    }
}
