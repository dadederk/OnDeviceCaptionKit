import Foundation

/// Computes export-service timeout budgets for multi-step caption embedding.
nonisolated enum CaptionEmbeddingTimeoutBudget {
  public static let margin: TimeInterval = 2

  /// Total wall-clock budget for chunk writes plus the final passthrough export.
  static func totalTimeout(
    chunkCount: Int,
    perStepTimeout: TimeInterval,
    margin: TimeInterval = margin
  ) -> TimeInterval {
    let boundedChunkCount = max(chunkCount, 0)
    return TimeInterval(boundedChunkCount + 1) * perStepTimeout + margin
  }
}
