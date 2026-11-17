import AVFoundation
import CoreMedia
import Foundation

/// Converts CEA-608 captions after verifying that AVFoundation can encode their ranges.
/// Instances remain confined to the synchronous conversion operation that creates them.
nonisolated struct CEA608CaptionConformer {
    private let rangePreservingConformer: AVCaptionFormatConformer
    private let timeConformer: AVCaptionFormatConformer

    /// Creates format and timing converters for a positive, numeric frame duration.
    init(frameDuration: CMTime) throws {
        guard frameDuration.isNumeric, frameDuration.timescale > 0,
              frameDuration.epoch == 0, frameDuration > .zero else {
            throw CaptionEmbeddingError.captionConformanceFailed
        }
        let settings: [AVCaptionSettingsKey: Any] = [
            .mediaType: AVMediaType.closedCaption,
            .mediaSubType: NSNumber(value: kCMClosedCaptionFormatType_CEA608),
            .timeCodeFrameDuration: NSValue(time: frameDuration)
        ]
        rangePreservingConformer = AVCaptionFormatConformer(conversionSettings: settings)
        rangePreservingConformer.conformsCaptionsToTimeRange = false
        timeConformer = AVCaptionFormatConformer(conversionSettings: settings)
        timeConformer.conformsCaptionsToTimeRange = true
    }

    /// Returns a conformed caption or throws when its range cannot be encoded safely.
    func conformedCaption(text: String, timeRange: CMTimeRange) throws -> AVCaption {
        guard timeRange.isValid, timeRange.start.isNumeric, timeRange.duration.isNumeric,
              timeRange.start.timescale > 0, timeRange.duration.timescale > 0,
              timeRange.duration > .zero else {
            throw CaptionEmbeddingError.captionConformanceFailed
        }
        let caption = AVCaption(text, timeRange: timeRange)
        do {
            // For a short early cue with no encodable payload, this conversion
            // returns an error. Time conformance on the same input can instead
            // raise an Objective-C exception that Swift cannot catch.
            _ = try rangePreservingConformer.conformedCaption(for: caption)
            return try timeConformer.conformedCaption(for: caption)
        } catch {
            throw CaptionEmbeddingError.captionConformanceFailed
        }
    }
}
