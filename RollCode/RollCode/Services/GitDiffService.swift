import Foundation
#if canImport(GitBridgeKit)
import GitBridgeKit
public typealias GitDiffService = GitBridgeKit.GitBridgeService
#else
public typealias GitDiffService = GitBridgeService
#endif
