import Foundation

struct WorkspaceSnapshot: Equatable {
    struct Fingerprint: Equatable {
        let modificationDate: Date?
        let size: Int?
    }

    let files: [String: Fingerprint]

    static func capture(at rootURL: URL) -> WorkspaceSnapshot {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let excludedDirectories: Set<String> = [".git", ".build", "DerivedData", "node_modules"]
        guard let enumerator = FileManager.default.enumerator(atPath: rootURL.path) else {
            return WorkspaceSnapshot(files: [:])
        }

        var files: [String: Fingerprint] = [:]
        while let relativePath = enumerator.nextObject() as? String {
            let url = rootURL.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            files[relativePath] = Fingerprint(
                modificationDate: values.contentModificationDate,
                size: values.fileSize
            )
        }
        return WorkspaceSnapshot(files: files)
    }

    func changedFiles(comparedTo newer: WorkspaceSnapshot) -> [String] {
        Set(files.keys).union(newer.files.keys)
            .filter { files[$0] != newer.files[$0] }
            .sorted()
    }
}

