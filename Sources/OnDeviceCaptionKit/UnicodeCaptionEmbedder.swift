import AVFoundation
import Foundation

@available(macOS 26, *)
enum UnicodeCaptionEmbeddingError: Error {
    case noCaptionTracks
    case missingVideoPresentationSize
    case unplayableCaptionTracks(count: Int)
    case validationFailed(expected: [CaptionLanguageTrack], actual: [CaptionLanguageTrack])
}

@available(macOS 26, *)
struct UnicodeCaptionEmbedder: Sendable {
    @concurrent
    func embed(
        tracks: [CaptionLanguageTrack],
        into videoURL: URL,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        let nonemptyTracks = tracks.filter { track in
            track.segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard !nonemptyTracks.isEmpty else {
            throw UnicodeCaptionEmbeddingError.noCaptionTracks
        }

        let outputURL = Self.temporaryURL(prefix: "CaptionedRecording")
        let captionTrackURL = Self.temporaryURL(prefix: "CaptionTracks")
        defer { try? FileManager.default.removeItem(at: captionTrackURL) }
        let startedAt = ContinuousClock.now
        do {
            progressHandler?(0)
            let presentationSize = try await Self.videoPresentationSize(at: videoURL)
            CaptionLogger.info(
                "Starting TX3G caption staging: tracks=\(nonemptyTracks.count), "
                    + "presentation=\(Int(presentationSize.width))x\(Int(presentationSize.height))"
            )
            try await Tx3gCaptionTrackWriter().write(
                tracks: nonemptyTracks,
                to: captionTrackURL,
                presentationSize: presentationSize,
                terminalPadding: 0.001
            )
            try Task.checkCancellation()
            CaptionLogger.info(
                "Unicode caption staging completed; beginning passthrough media mux"
            )
            try await PassthroughCaptionTrackMuxer().mux(
                captionsFrom: captionTrackURL,
                withMediaFrom: videoURL,
                to: outputURL
            )
            CaptionLogger.info(
                "Unicode media copy completed: tracks=\(nonemptyTracks.count), "
                    + "outputBytes=\(Self.fileSize(at: outputURL)), "
                    + "elapsed=\(Self.elapsedSeconds(since: startedAt))s"
            )
            try Task.checkCancellation()
            progressHandler?(1)
            try Task.checkCancellation()

            let decodedTracks = try await Tx3gCaptionTrackReader().read(from: outputURL)
            guard Self.matches(decodedTracks, expected: nonemptyTracks) else {
                throw UnicodeCaptionEmbeddingError.validationFailed(
                    expected: nonemptyTracks,
                    actual: decodedTracks
                )
            }
            let asset = AVURLAsset(url: outputURL)
            let captionTracks = try await asset.loadTracks(withMediaType: .subtitle)
            var unplayableTrackCount = 0
            for track in captionTracks where try await !track.load(.isPlayable) {
                unplayableTrackCount += 1
            }
            guard captionTracks.count == decodedTracks.count, unplayableTrackCount == 0 else {
                throw UnicodeCaptionEmbeddingError.unplayableCaptionTracks(
                    count: unplayableTrackCount
                )
            }
            let decodedCueCount = decodedTracks.reduce(0) { $0 + $1.segments.count }
            CaptionLogger.info(
                "Embedded, decoded, and playback-validated \(decodedTracks.count) Unicode "
                    + "subtitle track(s): playableTracks=\(captionTracks.count), "
                    + "decodedCues=\(decodedCueCount), "
                    + "elapsed=\(Self.elapsedSeconds(since: startedAt))s"
            )
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func matches(
        _ actual: [CaptionLanguageTrack],
        expected: [CaptionLanguageTrack]
    ) -> Bool {
        guard actual.count == expected.count else { return false }
        var actualByLanguage: [String: [CaptionSegment]] = [:]
        for track in actual {
            guard actualByLanguage.updateValue(
                track.segments,
                forKey: track.languageIdentifier
            ) == nil else { return false }
        }
        return expected.allSatisfy {
            actualByLanguage[$0.languageIdentifier] == $0.segments.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private static func videoPresentationSize(at url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw UnicodeCaptionEmbeddingError.missingVideoPresentationSize
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
        let size = CGSize(width: transformed.width, height: transformed.height)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw UnicodeCaptionEmbeddingError.missingVideoPresentationSize
        }
        return size
    }

    private static func temporaryURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> String {
        let components = start.duration(to: .now).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.3f", seconds)
    }
}
