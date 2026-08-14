import AVFoundation
import Foundation
import Speech

@available(macOS 26, *)
struct ModernSpeechProvider: CaptionRecognitionProvider {
    static var isRuntimeAvailable: Bool { true }

    let providerID: CaptionRecognitionProviderID = .modern
    private let assetPolicy: CaptionAssetPolicy
    private let assetsPrepared: Bool

    init(assetPolicy: CaptionAssetPolicy, assetsPrepared: Bool) {
        self.assetPolicy = assetPolicy
        self.assetsPrepared = assetsPrepared
    }

    @concurrent static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    @concurrent static func assetDownloadRequirement(for locale: Locale) async -> CaptionAssetDownloadRequirement? {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed, .supported:
            return nil
        case .downloading:
            return CaptionAssetDownloadRequirement(locale: locale, moduleDescription: "Speech transcription model")
        case .unsupported:
            return nil
        @unknown default:
            return nil
        }
    }

    @concurrent static func prepareAssets(for locale: Locale, consentGranted: Bool) async throws {
        guard consentGranted else {
            throw CaptionError.assetDownloadRequiresConsent
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw CaptionError.assetDownloadFailed
        }
    }

    @concurrent func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CaptionSegment] {
        if assetPolicy == .requireExplicitConsent {
            if await Self.assetDownloadRequirement(for: locale) != nil, !assetsPrepared {
                throw CaptionError.assetDownloadRequiresConsent
            }
        }

        CaptionLogger.info("Starting modern transcription from audio file")
        let audioFile = try AVAudioFile(forReading: audioURL)
        let durationSeconds = CMTimeGetSeconds(try await AVURLAsset(url: audioURL).load(.duration))
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        progressHandler?(0)

        async let collectedSegments = collectSegments(
            from: transcriber,
            durationSeconds: durationSeconds,
            progressHandler: progressHandler
        )

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            CaptionTranscriptionProgress.reportFinalizing(progressHandler)
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
            throw CaptionError.recognitionFailed
        }

        let segments = try await collectedSegments
        CaptionTranscriptionProgress.reportComplete(progressHandler)
        let filtered = segments.filter { $0.duration > 0 }
        CaptionLogger.info("Modern transcription completed with \(filtered.count) segment(s)")
        return filtered
    }

    private func collectSegments(
        from transcriber: SpeechTranscriber,
        durationSeconds: TimeInterval,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var index = 1
        var lastReportedProgress = 0.0
        var finalResultCount = 0
        var lastCueEnd: TimeInterval?

        for try await result in transcriber.results {
            try Task.checkCancellation()

            let processedEnd = CMTimeGetSeconds(result.range.end)
            CaptionTranscriptionProgress.reportStreamProgress(
                processedSeconds: processedEnd,
                totalSeconds: durationSeconds,
                lastReported: &lastReportedProgress,
                handler: progressHandler
            )

            guard result.isFinal else { continue }
            finalResultCount += 1

            let nonblankRuns = result.text.runs.count { run in
                !String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            let timedRuns = result.text.runs.count { $0.audioTimeRange != nil }
            let resultStart = CMTimeGetSeconds(result.range.start)
            let resultEnd = CMTimeGetSeconds(result.range.end)
            CaptionLogger.info(
                "Modern final result \(finalResultCount): range \(Self.formatted(resultStart))s–"
                    + "\(Self.formatted(resultEnd))s, timedRuns=\(timedRuns), nonblankRuns=\(nonblankRuns)"
            )

            let timedSegments: [CaptionSegment]
            do {
                timedSegments = try TimedTranscriptSegmenter.segments(from: result.text, startingAt: index)
            } catch {
                CaptionLogger.error(
                    "Modern finalized result had unusable time-indexed text: \(String(describing: error))"
                )
                throw CaptionError.recognitionFailed
            }
            guard !timedSegments.isEmpty else { continue }
            if let lastCueEnd, let firstStart = timedSegments.first?.startTime,
               firstStart + 0.001 < lastCueEnd {
                CaptionLogger.error(
                    "Modern finalized result overlapped prior cue timing: priorEnd="
                        + "\(Self.formatted(lastCueEnd))s, nextStart=\(Self.formatted(firstStart))s"
                )
                throw CaptionError.recognitionFailed
            }
            segments.append(contentsOf: timedSegments)
            index += timedSegments.count
            lastCueEnd = timedSegments.last?.endTime
        }

        CaptionLogger.info(
            "Modern result stream produced \(finalResultCount) finalized result(s) and \(segments.count) cue(s)"
        )
        return segments
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        seconds.isFinite ? String(format: "%.3f", seconds) : "invalid"
    }
}
