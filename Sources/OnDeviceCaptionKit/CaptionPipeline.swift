import Foundation

@available(macOS 26, *)
public struct CaptionPipeline {
    public struct Configuration: Sendable {
        public var transcription: CaptionTranscriptionConfiguration
        public var speechAuthorizationProvider: any SpeechAuthorizationProviding
        public var assetsPrepared: Bool

        public init(
            transcription: CaptionTranscriptionConfiguration = CaptionTranscriptionConfiguration(),
            speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
            assetsPrepared: Bool = false
        ) {
            self.transcription = transcription
            self.speechAuthorizationProvider = speechAuthorizationProvider
            self.assetsPrepared = assetsPrepared
        }
    }

    private let configuration: Configuration
    private let modernProvider: (any CaptionRecognitionProvider)?
    private let legacyProvider: any CaptionRecognitionProvider
    private let srtWriter: SRTWriter
    private let embedder: any CaptionEmbeddingMuxing
    private let embeddingTimeoutMargin: TimeInterval

    public init(
        configuration: Configuration = Configuration(),
        embeddingTimeoutMargin: TimeInterval = 2
    ) {
        self.init(
            configuration: configuration,
            embedder: nil,
            srtWriter: nil,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    init(
        configuration: Configuration = Configuration(),
        embedder: (any CaptionEmbeddingMuxing)? = nil,
        srtWriter: SRTWriter? = nil,
        embeddingTimeoutMargin: TimeInterval = 2,
        modernProvider: (any CaptionRecognitionProvider)? = nil,
        legacyProvider: (any CaptionRecognitionProvider)? = nil
    ) {
        self.configuration = configuration
        self.modernProvider = modernProvider
        self.legacyProvider = legacyProvider ?? LegacySpeechProvider(
            speechAuthorizationProvider: configuration.speechAuthorizationProvider
        )
        self.srtWriter = srtWriter ?? SRTWriter()
        if let embedder {
            self.embedder = embedder
        } else {
            self.embedder = CaptionEmbedder(locale: configuration.transcription.locale)
        }
        self.embeddingTimeoutMargin = embeddingTimeoutMargin
    }

    public init(
        transcription: CaptionTranscriptionConfiguration,
        speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        assetsPrepared: Bool = false,
        embeddingTimeoutMargin: TimeInterval = 2
    ) {
        self.init(
            configuration: Configuration(
                transcription: transcription,
                speechAuthorizationProvider: speechAuthorizationProvider,
                assetsPrepared: assetsPrepared
            ),
            embedder: nil,
            srtWriter: nil,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    init(
        transcription: CaptionTranscriptionConfiguration,
        speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        assetsPrepared: Bool = false,
        embedder: (any CaptionEmbeddingMuxing)? = nil,
        srtWriter: SRTWriter? = nil,
        embeddingTimeoutMargin: TimeInterval = 2
    ) {
        self.init(
            configuration: Configuration(
                transcription: transcription,
                speechAuthorizationProvider: speechAuthorizationProvider,
                assetsPrepared: assetsPrepared
            ),
            embedder: embedder,
            srtWriter: srtWriter,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    @available(macOS 26, *)
    public static func prepareAssets(for locale: Locale, consentGranted: Bool) async throws {
        try await ModernSpeechProvider.prepareAssets(for: locale, consentGranted: consentGranted)
    }

    public func transcribe(
        from audioURL: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CaptionTranscriptionResult {
        let locale = configuration.transcription.locale
        if !configuration.transcription.preferLegacySpeechProvider {
            do {
                let segments = try await transcribeWithModernProvider(
                    from: audioURL,
                    locale: locale,
                    progressHandler: progressHandler
                )
                CaptionLogger.info("Transcription completed using modern provider with \(segments.count) segment(s)")
                logSegments(segments)
                return CaptionTranscriptionResult(segments: segments, providerID: .modern)
            } catch {
                guard CaptionTranscriptionFallbackPolicy.shouldFallback(from: error) else {
                    throw error
                }
                CaptionLogger.warning("Modern transcription failed; falling back to legacy: \(error.localizedDescription)")
            }
        } else {
            CaptionLogger.info("Skipping modern transcription because legacy provider is preferred")
        }

        let segments = try await legacyProvider.transcribe(from: audioURL, locale: locale, progressHandler: progressHandler)
        CaptionLogger.info("Transcription completed using legacy provider with \(segments.count) segment(s)")
        logSegments(segments)
        return CaptionTranscriptionResult(segments: segments, providerID: .legacy)
    }

    public func exportCaptions(
        segments: [CaptionSegment],
        videoURL: URL,
        format: CaptionOutputFormat,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> CaptionExportResult {
        switch format {
        case .embeddedMovCaptions:
            do {
                let cancellation = CaptionEmbeddingCancellationHolder()
                let timeoutBudget = try await embedder.estimatedEmbeddingTimeout(for: segments, into: videoURL)
                    + embeddingTimeoutMargin

                let captionedURL = try await CaptionEmbeddingTimeout.run(
                    seconds: timeoutBudget,
                    onTimeout: {
                        cancellation.cancel()
                        CaptionLogger.warning("Caption embedding timed out at export boundary")
                    },
                    operation: {
                        try await self.embedder.embedClosedCaptions(
                            from: segments,
                            into: videoURL,
                            cancellation: cancellation,
                            progressHandler: progressHandler
                        )
                    }
                )
                return CaptionExportResult(videoURL: captionedURL, segments: segments)
            } catch {
                CaptionLogger.error("Caption embedding failed: \(error.localizedDescription)")
                let warningCode = segments.isEmpty ? "embeddedFailed" : "embeddedFallbackToSRT"
                return CaptionExportResult(
                    videoURL: videoURL,
                    segments: segments,
                    deferredSRTSegments: segments.isEmpty ? nil : segments,
                    warningCode: warningCode
                )
            }

        case .srtSidecar:
            return CaptionExportResult(
                videoURL: videoURL,
                segments: segments,
                deferredSRTSegments: segments
            )
        }
    }

    public func writeSRT(segments: [CaptionSegment], besideVideoAt videoURL: URL) throws {
        let outputURL = srtWriter.srtURLBesideVideo(videoURL)
        try srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    public func writeSRT(segments: [CaptionSegment], to outputURL: URL) throws {
        try srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    private func transcribeWithModernProvider(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment] {
        if let modernProvider {
            return try await modernProvider.transcribe(from: audioURL, locale: locale, progressHandler: progressHandler)
        }

        let modern = ModernSpeechProvider(
            assetPolicy: configuration.transcription.assetPolicy,
            assetsPrepared: configuration.assetsPrepared
        )
        return try await modern.transcribe(from: audioURL, locale: locale, progressHandler: progressHandler)
    }

    private func logSegments(_ segments: [CaptionSegment]) {
        #if DEBUG
        CaptionLogger.debugTranscript("Transcribed \(segments.count) segment(s)", enabled: configuration.transcription.debugLogTranscripts)
        #endif
    }
}

extension CaptionPipeline: @unchecked Sendable {}
