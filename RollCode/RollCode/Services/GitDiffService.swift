import Foundation
#if canImport(GitBridgeKit)
import GitBridgeKit
typealias GitDiffService = GitBridgeKit.GitBridgeService
#else
typealias GitDiffService = GitBridgeService
#endif
