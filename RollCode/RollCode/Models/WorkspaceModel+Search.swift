import Foundation

struct WorkspaceReplaceResult: Sendable {
    var files = 0
    var occurrences = 0
    var failedFiles: [String] = []
}

extension WorkspaceModel {
    func openSearchMatch(_ match: WorkspaceSearchMatch) {
        openFile(match.url)
        guard activeDocument?.url.standardizedFileURL == match.url.standardizedFileURL else { return }
        editorNavigationRequest = EditorNavigationRequest(line: match.line)
    }

    func searchWorkspace(for query: String) async -> [WorkspaceSearchMatch] {
        guard let rootURL, !query.isEmpty else { return [] }
        let files = await searchableFiles()
        return await Task.detached(priority: .userInitiated) {
            WorkspaceSearch.matches(for: query, in: files, relativeTo: rootURL)
        }.value
    }

    func replaceWorkspaceOccurrences(of query: String, with replacement: String) async -> WorkspaceReplaceResult {
        guard !query.isEmpty else { return WorkspaceReplaceResult() }
        let files = await searchableFiles()
        let replacements = await Task.detached(priority: .userInitiated) {
            WorkspaceSearch.replacements(of: query, with: replacement, in: files)
        }.value

        let writeResult = await Task.detached(priority: .userInitiated) {
            var completed: [WorkspaceReplacement] = []
            var failures: [String] = []
            for replacement in replacements {
                do {
                    try replacement.text.write(to: replacement.url, atomically: true, encoding: .utf8)
                    completed.append(replacement)
                } catch {
                    failures.append(replacement.url.lastPathComponent)
                }
            }
            return (completed, failures)
        }.value

        var result = WorkspaceReplaceResult(failedFiles: writeResult.1)
        for replacement in writeResult.0 {
            updateOpenDocument(with: replacement)
            result.files += 1
            result.occurrences += replacement.occurrences
        }
        return result
    }

    func gitChanges() async throws -> [GitChange] {
        guard let rootURL else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try GitDiffService.changes(in: rootURL)
        }.value
    }

    func gitCommit(message: String) async throws {
        guard let rootURL else { return }
        try await Task.detached(priority: .userInitiated) {
            try GitDiffService.commit(in: rootURL, message: message)
        }.value
        refreshTree()
    }

    private func searchableFiles() async -> [WorkspaceSearchFile] {
        let urls = workspaceFiles.map(\.url)
        let openFiles = Dictionary(uniqueKeysWithValues: documents.map {
            ($0.url.standardizedFileURL, $0.text)
        })

        return await Task.detached(priority: .userInitiated) {
            urls.compactMap { url in
                if let text = openFiles[url.standardizedFileURL] {
                    return WorkspaceSearchFile(url: url, text: text)
                }
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      data.count <= 5_000_000,
                      !data.prefix(8_192).contains(0),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return WorkspaceSearchFile(url: url, text: text)
            }
        }.value
    }

    private func updateOpenDocument(with replacement: WorkspaceReplacement) {
        guard let document = documents.first(where: {
            $0.url.standardizedFileURL == replacement.url.standardizedFileURL
        }) else { return }
        document.replaceFromDisk(
            text: replacement.text,
            modificationDate: replacement.url.modificationDate
        )
    }
}
