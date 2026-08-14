import Foundation

@available(macOS 26, *)
protocol UnicodeCaptionEmbeddingMuxing: Sendable {
    @concurrent func estimatedEmbeddingTimeout(
        for tracks: [CaptionLanguageTrack],
        into videoURL: URL
    ) async throws -> TimeInterval

    @concurrent func embedUnicodeCaptions(
        from tracks: [CaptionLanguageTrack],
        into videoURL: URL,
        progressHandler: (@Sendable (Float) -> Void)?
    ) async throws -> URL
}

@available(macOS 26, *)
extension UnicodeCaptionEmbedder: UnicodeCaptionEmbeddingMuxing {
    @concurrent
    func estimatedEmbeddingTimeout(
        for _: [CaptionLanguageTrack],
        into _: URL
    ) async throws -> TimeInterval {
        10
    }

    @concurrent
    func embedUnicodeCaptions(
        from tracks: [CaptionLanguageTrack],
        into videoURL: URL,
        progressHandler: (@Sendable (Float) -> Void)?
    ) async throws -> URL {
        try await embed(
            tracks: tracks,
            into: videoURL,
            progressHandler: progressHandler
        )
    }
}
