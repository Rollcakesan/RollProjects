import Foundation

enum QuickOpenMatcher {
    static func score(query: String, candidate: String) -> Int? {
        let queryCharacters = Array(query.lowercased())
        guard !queryCharacters.isEmpty else { return 0 }

        let candidateCharacters = Array(candidate.lowercased())
        var queryIndex = 0
        var score = 0
        var lastMatchIndex: Int?

        for (candidateIndex, character) in candidateCharacters.enumerated() {
            guard queryIndex < queryCharacters.count,
                  character == queryCharacters[queryIndex] else { continue }

            score += 10
            if let lastMatchIndex, candidateIndex == lastMatchIndex + 1 {
                score += 12
            }
            if candidateIndex == 0 || isPathBoundary(candidateCharacters[candidateIndex - 1]) {
                score += 8
            }
            score -= min(candidateIndex, 20)
            lastMatchIndex = candidateIndex
            queryIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        score -= max(candidateCharacters.count - queryCharacters.count, 0) / 4
        return score
    }

    private static func isPathBoundary(_ character: Character) -> Bool {
        character == "/" || character == "-" || character == "_" || character == "." || character == " "
    }
}
