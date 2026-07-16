import Foundation

enum CaptionTranscriptionFallbackPolicy {
    static func shouldFallback(from error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        guard let captionError = error as? CaptionError else {
            return false
        }

        switch captionError {
        case .recognitionFailed, .providerUnavailable, .speechRecognizerNotAvailable:
            return true
        case .speechAuthorizationDenied,
             .assetDownloadRequiresConsent,
             .assetDownloadFailed,
             .noAudioTrack,
             .embeddingTimedOut,
             .embeddingNoTracksToCopy,
             .embeddingCannotCreateClosedCaptionFormat,
             .embeddingCannotAddInput,
             .embeddingCannotStartWriter,
             .embeddingCannotCreateExportSession,
             .embeddingCaptionConformanceFailed:
            return false
        }
    }
}
