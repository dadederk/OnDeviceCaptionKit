import AVFoundation
import Foundation

protocol CaptionEmbeddingMuxing: Sendable {
    func estimatedEmbeddingTimeout(
        for segments: [CaptionSegment],
        into videoURL: URL
    ) async throws -> TimeInterval

    func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder?,
        progressHandler: (@Sendable (Float) -> Void)?
    ) async throws -> URL
}

@available(macOS 26, *)
extension CaptionEmbedder: CaptionEmbeddingMuxing {}
