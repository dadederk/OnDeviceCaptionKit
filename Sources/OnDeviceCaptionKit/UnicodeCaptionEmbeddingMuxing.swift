import AVFoundation
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
        for tracks: [CaptionLanguageTrack],
        into videoURL: URL
    ) async throws -> TimeInterval {
        let asset = AVURLAsset(url: videoURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let fileSize = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        let budget = CaptionEmbeddingTimeoutBudget.unicodeEmbeddingTimeout(
            duration: duration,
            fileSizeBytes: fileSize
        )
        CaptionLogger.info(
            "Estimated Unicode embedding budget: tracks=\(tracks.count), "
                + "duration=\(Self.formatted(duration))s, sourceBytes=\(fileSize), "
                + "budget=\(Self.formatted(budget))s"
        )
        return budget
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

    private static func formatted(_ value: TimeInterval) -> String {
        String(format: "%.1f", value.isFinite ? value : 0)
    }
}
