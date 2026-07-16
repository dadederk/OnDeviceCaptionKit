import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionTranscriptionFallbackPolicyTests {
    @Test("Consent errors do not allow legacy fallback")
    func givenAssetDownloadRequiresConsentWhenCheckingFallbackThenReturnsFalse() {
        #expect(!CaptionTranscriptionFallbackPolicy.shouldFallback(from: CaptionError.assetDownloadRequiresConsent))
        #expect(!CaptionTranscriptionFallbackPolicy.shouldFallback(from: CaptionError.assetDownloadFailed))
    }

    @Test("Cancellation does not allow legacy fallback")
    func givenCancellationErrorWhenCheckingFallbackThenReturnsFalse() {
        #expect(!CaptionTranscriptionFallbackPolicy.shouldFallback(from: CancellationError()))
    }

    @Test("Recoverable transcription failures allow legacy fallback")
    func givenRecoverableErrorsWhenCheckingFallbackThenReturnsTrue() {
        #expect(CaptionTranscriptionFallbackPolicy.shouldFallback(from: CaptionError.recognitionFailed))
        #expect(CaptionTranscriptionFallbackPolicy.shouldFallback(from: CaptionError.providerUnavailable))
        #expect(CaptionTranscriptionFallbackPolicy.shouldFallback(from: CaptionError.speechRecognizerNotAvailable))
    }

    @Test("Unknown errors do not allow legacy fallback")
    func givenUnknownErrorWhenCheckingFallbackThenReturnsFalse() {
        struct SampleError: Error {}
        #expect(!CaptionTranscriptionFallbackPolicy.shouldFallback(from: SampleError()))
    }
}
