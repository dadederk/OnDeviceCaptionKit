import Foundation

/// Computes export-service timeout budgets for multi-step caption embedding.
nonisolated enum CaptionEmbeddingTimeoutBudget {
  public static let margin: TimeInterval = 2
  private static let unicodeBaseTimeout: TimeInterval = 15
  private static let unicodeMinimumTimeout: TimeInterval = 30
  private static let unicodeMaximumTimeout: TimeInterval = 600
  private static let unicodeDurationMultiplier: TimeInterval = 2
  private static let unicodeCopyBytesPerSecond: Double = 5 * 1_024 * 1_024

  /// Total wall-clock budget for chunk writes plus the final passthrough export.
  static func totalTimeout(
    chunkCount: Int,
    perStepTimeout: TimeInterval,
    margin: TimeInterval = margin
  ) -> TimeInterval {
    let boundedChunkCount = max(chunkCount, 0)
    return TimeInterval(boundedChunkCount + 1) * perStepTimeout + margin
  }

  /// Bounds Unicode staging and passthrough muxing without assuming every movie
  /// completes in the same fixed interval. Duration accounts for media timeline
  /// processing while file size accounts for high-bitrate sources.
  static func unicodeEmbeddingTimeout(
    duration: TimeInterval,
    fileSizeBytes: Int64
  ) -> TimeInterval {
    let boundedDuration = duration.isFinite ? max(duration, 0) : 0
    let boundedFileSize = max(fileSizeBytes, 0)
    let durationEstimate = boundedDuration * unicodeDurationMultiplier
    let sizeEstimate = Double(boundedFileSize) / unicodeCopyBytesPerSecond
    let estimate = unicodeBaseTimeout + max(durationEstimate, sizeEstimate)
    return min(max(estimate, unicodeMinimumTimeout), unicodeMaximumTimeout)
  }
}
