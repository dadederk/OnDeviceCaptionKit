import Foundation
import Speech
import Testing
@testable import OnDeviceCaptionKit

struct ProviderSelectionTests {
    @Test("Preferred provider is modern on macOS 26")
    func givenCurrentOSWhenReadingPreferredProviderThenModern() {
        #expect(CaptionPipelineCapabilities.preferredProvider() == .modern)
    }

    @Test("Legacy provider is selected when preferLegacySpeechProvider is enabled")
    func givenLegacyPreferenceWhenTranscribingThenModernIsSkipped() async throws {
        let legacy = TrackingCaptionProvider(providerID: .legacy)
        let pipeline = CaptionPipeline(
            configuration: CaptionPipeline.Configuration(
                transcription: CaptionTranscriptionConfiguration(
                    locale: Locale(identifier: "en-US"),
                    preferLegacySpeechProvider: true
                )
            ),
            modernProvider: TrackingCaptionProvider(providerID: .modern),
            legacyProvider: legacy
        )

        _ = try await pipeline.transcribe(from: URL(fileURLWithPath: "/tmp/audio.m4a"))

        #expect(legacy.callCount == 1)
    }

    @Test("Consent failure does not fall back to legacy transcription")
    func givenModernConsentFailureWhenTranscribingThenLegacyIsNotUsed() async throws {
        let legacy = TrackingCaptionProvider(providerID: .legacy)
        let pipeline = CaptionPipeline(
            configuration: CaptionPipeline.Configuration(
                transcription: CaptionTranscriptionConfiguration(locale: Locale(identifier: "en-US"))
            ),
            modernProvider: ThrowingCaptionProvider(error: CaptionError.assetDownloadRequiresConsent),
            legacyProvider: legacy
        )

        do {
            _ = try await pipeline.transcribe(from: URL(fileURLWithPath: "/tmp/audio.m4a"))
            Issue.record("Expected consent error")
        } catch let error as CaptionError {
            #expect(error == .assetDownloadRequiresConsent)
            #expect(legacy.callCount == 0)
        }
    }

    @Test("Cancellation does not fall back to legacy transcription")
    func givenModernCancellationWhenTranscribingThenLegacyIsNotUsed() async throws {
        let legacy = TrackingCaptionProvider(providerID: .legacy)
        let pipeline = CaptionPipeline(
            configuration: CaptionPipeline.Configuration(
                transcription: CaptionTranscriptionConfiguration(locale: Locale(identifier: "en-US"))
            ),
            modernProvider: ThrowingCaptionProvider(error: CancellationError()),
            legacyProvider: legacy
        )

        do {
            _ = try await pipeline.transcribe(from: URL(fileURLWithPath: "/tmp/audio.m4a"))
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(legacy.callCount == 0)
        }
    }

    @Test("Recoverable modern failure falls back to legacy transcription")
    func givenRecoverableModernFailureWhenTranscribingThenLegacyRuns() async throws {
        let legacy = TrackingCaptionProvider(providerID: .legacy)
        let pipeline = CaptionPipeline(
            configuration: CaptionPipeline.Configuration(
                transcription: CaptionTranscriptionConfiguration(locale: Locale(identifier: "en-US"))
            ),
            modernProvider: ThrowingCaptionProvider(error: CaptionError.recognitionFailed),
            legacyProvider: legacy
        )

        _ = try await pipeline.transcribe(from: URL(fileURLWithPath: "/tmp/audio.m4a"))

        #expect(legacy.callCount == 1)
    }
}

private struct ThrowingCaptionProvider: CaptionRecognitionProvider {
    let providerID: CaptionRecognitionProviderID
    let error: Error

    init(providerID: CaptionRecognitionProviderID = .modern, error: Error) {
        self.providerID = providerID
        self.error = error
    }

    func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment] {
        throw error
    }
}

private final class TrackingCaptionProvider: CaptionRecognitionProvider, @unchecked Sendable {
    let providerID: CaptionRecognitionProviderID
    private(set) var callCount = 0

    init(providerID: CaptionRecognitionProviderID) {
        self.providerID = providerID
    }

    func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment] {
        callCount += 1
        return [CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "hello")]
    }
}
