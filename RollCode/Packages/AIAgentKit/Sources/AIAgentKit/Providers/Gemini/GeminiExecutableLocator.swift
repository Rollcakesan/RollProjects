import Foundation

public enum GeminiExecutableLocator: Sendable {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/gemini" }
        }

        for path in candidates {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }
}
