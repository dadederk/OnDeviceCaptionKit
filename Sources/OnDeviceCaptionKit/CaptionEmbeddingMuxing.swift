import AVFoundation
import Foundation

protocol CaptionEmbeddingMuxing: Sendable {
    @concurrent func estimatedEmbeddingTimeout(
        for segments: [CaptionSegment],
        into videoURL: URL
    ) async throws -> TimeInterval

    @concurrent func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder?,
        progressHandler: (@Sendable (Float) -> Void)?
    ) async throws -> URL
}

@available(macOS 26, *)
extension CaptionEmbedder: CaptionEmbeddingMuxing {}
