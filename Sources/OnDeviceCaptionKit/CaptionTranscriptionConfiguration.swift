import Foundation

public struct CaptionTranscriptionConfiguration: Sendable, Equatable {
    public var locale: Locale
    public var assetPolicy: CaptionAssetPolicy
    public var debugLogTranscripts: Bool
    public var preferLegacySpeechProvider: Bool

    public init(
        locale: Locale = .current,
        assetPolicy: CaptionAssetPolicy = .requireExplicitConsent,
        debugLogTranscripts: Bool = false,
        preferLegacySpeechProvider: Bool = false
    ) {
        self.locale = locale
        self.assetPolicy = assetPolicy
        self.debugLogTranscripts = debugLogTranscripts
        self.preferLegacySpeechProvider = preferLegacySpeechProvider
    }
}

public struct CaptionTranscriptionResult: Sendable, Equatable {
    public let segments: [CaptionSegment]
    public let providerID: CaptionRecognitionProviderID

    public init(segments: [CaptionSegment], providerID: CaptionRecognitionProviderID) {
        self.segments = segments
        self.providerID = providerID
    }
}

public struct CaptionExportResult: Equatable, Sendable {
    public let videoURL: URL
    public let segments: [CaptionSegment]
    public let deferredSRTSegments: [CaptionSegment]?
    public let warningCode: String?
    public let providerID: CaptionRecognitionProviderID?

    public init(
        videoURL: URL,
        segments: [CaptionSegment],
        deferredSRTSegments: [CaptionSegment]? = nil,
        warningCode: String? = nil,
        providerID: CaptionRecognitionProviderID? = nil
    ) {
        self.videoURL = videoURL
        self.segments = segments
        self.deferredSRTSegments = deferredSRTSegments
        self.warningCode = warningCode
        self.providerID = providerID
    }
}
