import Foundation

/// Maps audio timeline position to a 0...1 transcription progress value.
/// Reserves the last ~8% for analyzer finalization or legacy segmentation.
enum CaptionTranscriptionProgress {
    static let streamHeadroom: Double = 0.92
    static let finalizingValue: Double = 0.96

    static func streamProgress(processedSeconds: TimeInterval, totalSeconds: TimeInterval) -> Double {
        guard totalSeconds > 0, processedSeconds.isFinite, totalSeconds.isFinite else { return 0 }
        let fraction = min(max(processedSeconds / totalSeconds, 0), 1)
        return min(fraction * streamHeadroom, streamHeadroom)
    }

    static func reportStreamProgress(
        processedSeconds: TimeInterval,
        totalSeconds: TimeInterval,
        lastReported: inout Double,
        handler: (@Sendable (Double) -> Void)?
    ) {
        guard let handler else { return }
        let progress = streamProgress(processedSeconds: processedSeconds, totalSeconds: totalSeconds)
        guard progress > lastReported + 0.005 || progress >= streamHeadroom else { return }
        lastReported = progress
        handler(progress)
    }

    static func reportFinalizing(_ handler: (@Sendable (Double) -> Void)?) {
        handler?(finalizingValue)
    }

    static func reportComplete(_ handler: (@Sendable (Double) -> Void)?) {
        handler?(1)
    }
}
