import Foundation

public enum CaptionError: Error, Equatable, Sendable {
    case speechRecognizerNotAvailable
    case speechAuthorizationDenied
    case noAudioTrack
    case recognitionFailed
    case providerUnavailable
    case embeddingTimedOut
    case embeddingNoTracksToCopy
    case embeddingCannotCreateClosedCaptionFormat(OSStatus)
    case embeddingCannotAddInput(String)
    case embeddingCannotStartWriter
    case embeddingCannotCreateExportSession
    case embeddingCaptionConformanceFailed
    case assetDownloadRequiresConsent
    case assetDownloadFailed

    public var code: String {
        switch self {
        case .speechRecognizerNotAvailable: return "speechRecognizerNotAvailable"
        case .speechAuthorizationDenied: return "speechAuthorizationDenied"
        case .noAudioTrack: return "noAudioTrack"
        case .recognitionFailed: return "recognitionFailed"
        case .providerUnavailable: return "providerUnavailable"
        case .embeddingTimedOut: return "embeddingTimedOut"
        case .embeddingNoTracksToCopy: return "embeddingNoTracksToCopy"
        case .embeddingCannotCreateClosedCaptionFormat: return "embeddingCannotCreateClosedCaptionFormat"
        case .embeddingCannotAddInput: return "embeddingCannotAddInput"
        case .embeddingCannotStartWriter: return "embeddingCannotStartWriter"
        case .embeddingCannotCreateExportSession: return "embeddingCannotCreateExportSession"
        case .embeddingCaptionConformanceFailed: return "embeddingCaptionConformanceFailed"
        case .assetDownloadRequiresConsent: return "assetDownloadRequiresConsent"
        case .assetDownloadFailed: return "assetDownloadFailed"
        }
    }
}

enum CaptionEmbeddingError: Error {
    case noTracksToCopy
    case cannotCreateClosedCaptionFormat(OSStatus)
    case cannotAddInput(String)
    case cannotStartWriter
    case cannotCreateExportSession
    case captionConformanceFailed
    case timedOut

    var captionError: CaptionError {
        switch self {
        case .noTracksToCopy: return .embeddingNoTracksToCopy
        case .cannotCreateClosedCaptionFormat(let status): return .embeddingCannotCreateClosedCaptionFormat(status)
        case .cannotAddInput(let mediaType): return .embeddingCannotAddInput(mediaType)
        case .cannotStartWriter: return .embeddingCannotStartWriter
        case .cannotCreateExportSession: return .embeddingCannotCreateExportSession
        case .captionConformanceFailed: return .embeddingCaptionConformanceFailed
        case .timedOut: return .embeddingTimedOut
        }
    }
}
