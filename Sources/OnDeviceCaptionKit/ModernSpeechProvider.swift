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

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func assetDownloadRequirement(for locale: Locale) async -> CaptionAssetDownloadRequirement? {
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

    static func prepareAssets(for locale: Locale, consentGranted: Bool) async throws {
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

    func transcribe(
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

            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(result.range.end)
            segments.append(CaptionSegment(index: index, startTime: start, endTime: end, text: text))
            index += 1
        }

        return segments
    }
}

@available(macOS 26, *)
extension ModernSpeechProvider: @unchecked Sendable {}
