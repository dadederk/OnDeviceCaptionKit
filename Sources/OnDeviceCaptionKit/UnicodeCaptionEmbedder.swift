import AVFoundation
import Foundation

@available(macOS 26, *)
enum UnicodeCaptionEmbeddingError: Error {
    case noCaptionTracks
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
            try await Tx3gCaptionTrackWriter().write(
                tracks: nonemptyTracks,
                to: captionTrackURL,
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
            CaptionLogger.info(
                "Embedded and validated \(decodedTracks.count) Unicode caption track(s), "
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
