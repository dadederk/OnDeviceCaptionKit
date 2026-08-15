import Foundation

@available(macOS 26, *)
public struct CaptionPipeline: Sendable {
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
    private let unicodeEmbedder: any UnicodeCaptionEmbeddingMuxing
    private let embeddingTimeoutMargin: TimeInterval
    private let embeddingCleanupScheduler: CaptionEmbeddingTimeout.CleanupScheduler
    private let discardedCaptionOutputCleanup: @Sendable (URL) -> Void

    public init(
        configuration: Configuration = Configuration(),
        embeddingTimeoutMargin: TimeInterval = 2
    ) {
        self.init(
            configuration: configuration,
            embedder: nil,
            unicodeEmbedder: nil,
            srtWriter: nil,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    init(
        configuration: Configuration = Configuration(),
        embedder: (any CaptionEmbeddingMuxing)? = nil,
        unicodeEmbedder: (any UnicodeCaptionEmbeddingMuxing)? = nil,
        srtWriter: SRTWriter? = nil,
        embeddingTimeoutMargin: TimeInterval = 2,
        modernProvider: (any CaptionRecognitionProvider)? = nil,
        legacyProvider: (any CaptionRecognitionProvider)? = nil,
        embeddingCleanupScheduler: CaptionEmbeddingTimeout.CleanupScheduler = CaptionEmbeddingTimeout.sharedCleanupScheduler,
        discardedCaptionOutputCleanup: @escaping @Sendable (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
        }
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
        self.unicodeEmbedder = unicodeEmbedder ?? UnicodeCaptionEmbedder()
        self.embeddingTimeoutMargin = embeddingTimeoutMargin
        self.embeddingCleanupScheduler = embeddingCleanupScheduler
        self.discardedCaptionOutputCleanup = discardedCaptionOutputCleanup
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
            unicodeEmbedder: nil,
            srtWriter: nil,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    init(
        transcription: CaptionTranscriptionConfiguration,
        speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        assetsPrepared: Bool = false,
        embedder: (any CaptionEmbeddingMuxing)? = nil,
        unicodeEmbedder: (any UnicodeCaptionEmbeddingMuxing)? = nil,
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
            unicodeEmbedder: unicodeEmbedder,
            srtWriter: srtWriter,
            embeddingTimeoutMargin: embeddingTimeoutMargin
        )
    }

    @available(macOS 26, *)
    @concurrent
    public static func prepareAssets(for locale: Locale, consentGranted: Bool) async throws {
        try await ModernSpeechProvider.prepareAssets(for: locale, consentGranted: consentGranted)
    }

    @concurrent
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

    @concurrent
    public func exportCaptions(
        segments: [CaptionSegment],
        videoURL: URL,
        format: CaptionOutputFormat,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> CaptionExportResult {
        try Task.checkCancellation()

        switch format {
        case .embeddedMovCaptions:
            do {
                let cancellation = CaptionEmbeddingCancellationHolder()
                let timeoutBudget = try await embedder.estimatedEmbeddingTimeout(for: segments, into: videoURL)
                    + embeddingTimeoutMargin

                let captionedURL = try await CaptionEmbeddingTimeout.run(
                    seconds: timeoutBudget,
                    cleanupScheduler: embeddingCleanupScheduler,
                    cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                        prepare: {
                            cancellation.prepareCancellation()
                        },
                        perform: { reason in
                            cancellation.performPreparedCancellation()
                            if reason == .timeout {
                                CaptionLogger.warning("Caption embedding timed out at export boundary")
                            }
                        }
                    ),
                    discardedSuccessCleanup: discardedCaptionOutputCleanup,
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
            } catch is CancellationError {
                throw CancellationError()
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

    @concurrent
    public func exportCaptions(
        tracks: [CaptionLanguageTrack],
        videoURL: URL,
        format: CaptionOutputFormat,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> CaptionExportResult {
        try Task.checkCancellation()
        try CaptionLanguageTrack.validateCollection(tracks)
        let originalSegments = tracks.first?.segments ?? []
        let hasNonemptyTranslation = tracks.dropFirst().contains { track in
            track.segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard hasNonemptyTranslation else {
            return try await exportCaptions(
                segments: originalSegments,
                videoURL: videoURL,
                format: format,
                progressHandler: progressHandler
            )
        }
        let nonemptyTracks = tracks.filter { track in
            track.segments.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        switch format {
        case .embeddedMovCaptions:
            do {
                let estimatedTimeout = try await unicodeEmbedder.estimatedEmbeddingTimeout(
                    for: nonemptyTracks,
                    into: videoURL
                )
                let timeoutBudget = estimatedTimeout + embeddingTimeoutMargin
                let cueCount = nonemptyTracks.reduce(into: 0) { count, track in
                    count += track.segments.lazy.filter {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }.count
                }
                CaptionLogger.info(
                    "Starting Unicode caption embedding: tracks=\(nonemptyTracks.count), "
                        + "cues=\(cueCount), timeout=\(Self.formatted(timeoutBudget))s"
                )
                let captionedURL = try await CaptionEmbeddingTimeout.run(
                    seconds: timeoutBudget,
                    cleanupScheduler: embeddingCleanupScheduler,
                    cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                        prepare: { true },
                        perform: { reason in
                            if reason == .timeout {
                                CaptionLogger.warning("Unicode caption embedding timed out at export boundary")
                            }
                        }
                    ),
                    discardedSuccessCleanup: discardedCaptionOutputCleanup,
                    operation: {
                        try await self.unicodeEmbedder.embedUnicodeCaptions(
                            from: nonemptyTracks,
                            into: videoURL,
                            progressHandler: progressHandler
                        )
                    }
                )
                return CaptionExportResult(
                    videoURL: captionedURL,
                    segments: originalSegments
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                CaptionLogger.error("Unicode caption embedding failed: \(error.localizedDescription)")
                return CaptionExportResult(
                    videoURL: videoURL,
                    segments: originalSegments,
                    deferredSRTTracks: nonemptyTracks.isEmpty ? nil : nonemptyTracks,
                    warningCode: nonemptyTracks.isEmpty ? "embeddedFailed" : "embeddedFallbackToSRT"
                )
            }

        case .srtSidecar:
            return CaptionExportResult(
                videoURL: videoURL,
                segments: originalSegments,
                deferredSRTTracks: nonemptyTracks.isEmpty ? nil : nonemptyTracks
            )
        }
    }

    @available(*, deprecated, message: "Use the async writeSRT overload.")
    public func writeSRT(segments: [CaptionSegment], besideVideoAt videoURL: URL) throws {
        let outputURL = srtWriter.srtURLBesideVideo(videoURL)
        try srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    @available(*, deprecated, message: "Use the async writeSRT overload.")
    public func writeSRT(segments: [CaptionSegment], to outputURL: URL) throws {
        try srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    @concurrent
    public func writeSRT(segments: [CaptionSegment], besideVideoAt videoURL: URL) async throws {
        let outputURL = srtWriter.srtURLBesideVideo(videoURL)
        try await srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    @concurrent
    public func writeSRT(segments: [CaptionSegment], to outputURL: URL) async throws {
        try await srtWriter.generateSRTFile(from: segments, to: outputURL)
    }

    @concurrent
    public func writeSRT(
        tracks: [CaptionLanguageTrack],
        besideVideoAt videoURL: URL
    ) async throws -> [URL] {
        try CaptionLanguageTrack.validateCollection(tracks)
        return try await srtWriter.generateSRTBundle(from: tracks, besideVideoAt: videoURL)
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

    private static func formatted(_ value: TimeInterval) -> String {
        String(format: "%.1f", value.isFinite ? value : 0)
    }
}
