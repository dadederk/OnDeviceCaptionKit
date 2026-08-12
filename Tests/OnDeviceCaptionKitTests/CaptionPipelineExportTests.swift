import Foundation
import Synchronization
import Testing
@testable import OnDeviceCaptionKit

struct CaptionPipelineExportTests {
    @Test("Embedded subtitle mode returns the captioned MOV and no deferred SRT")
    func givenEmbeddedModeWhenExportingThenCaptionMuxerResultIsUsed() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let captionedURL = URL(fileURLWithPath: "/tmp/captioned.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(result: .success(captionedURL))
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.videoURL == captionedURL)
        #expect(result.deferredSRTSegments == nil)
        #expect(result.warningCode == nil)
    }

    @Test("SRT sidecar mode returns deferred segments without writing immediately")
    func givenSRTModeWhenExportingThenSegmentsAreDeferred() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(result: .failure(.unexpectedCaptionMux))
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .srtSidecar
        )

        #expect(result.videoURL == sourceURL)
        #expect(result.deferredSRTSegments == sampleSegments)
        #expect(result.warningCode == nil)
    }

    @Test(
        "Pre-cancelled caption exports propagate cancellation for every format",
        arguments: [CaptionOutputFormat.embeddedMovCaptions, .srtSidecar]
    )
    func givenPreCancelledExportWhenExportingThenCancellationPropagates(
        format: CaptionOutputFormat
    ) async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(result: .failure(.unexpectedCaptionMux))
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.exportCaptions(
                segments: sampleSegments,
                videoURL: sourceURL,
                format: format
            )
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Embedded subtitle mode falls back to deferred SRT when caption muxing fails")
    func givenEmbeddedModeWhenCaptionMuxingFailsThenSRTFallbackIsReturned() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(result: .failure(.captionMuxFailed))
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.videoURL == sourceURL)
        #expect(result.deferredSRTSegments == sampleSegments)
        #expect(result.warningCode == "embeddedFallbackToSRT")
    }

    @Test("Embedded subtitle mode preserves MOV when caption muxing fails without segments")
    func givenEmbeddedModeWhenAllSubtitleWritesFailThenVideoResultIsPreserved() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(result: .failure(.captionMuxFailed))
        )

        let result = try await pipeline.exportCaptions(
            segments: [],
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.videoURL == sourceURL)
        #expect(result.deferredSRTSegments == nil)
        #expect(result.warningCode == "embeddedFailed")
    }

    @Test(
        "Embedded subtitle mode falls back to deferred SRT when caption muxing stalls",
        .timeLimit(.minutes(1))
    )
    func givenEmbeddedModeWhenCaptionMuxingStallsThenSRTFallbackIsReturned() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(behavior: .stall),
            embeddingTimeoutMargin: 0
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.videoURL == sourceURL)
        #expect(result.deferredSRTSegments == sampleSegments)
        #expect(result.warningCode == "embeddedFallbackToSRT")
    }

    @Test(
        "Scaled timeout allows multi-chunk caption embedding to complete",
        .timeLimit(.minutes(1))
    )
    func givenMultiChunkWorkWhenBudgetScalesThenEmbeddingSucceeds() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let captionedURL = URL(fileURLWithPath: "/tmp/captioned.mov")
        let pipeline = makePipeline(
            embedder: StubCaptionMuxer(behavior: .slowSuccess(captionedURL, chunkCount: 3, stepDelay: 0.05)),
            embeddingTimeoutMargin: 0.5
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.videoURL == captionedURL)
        #expect(result.warningCode == nil)
    }

    @Test(
        "A late successful export that loses the timeout race is deleted",
        .timeLimit(.minutes(1))
    )
    func givenLateSuccessfulExportWhenTimeoutWinsThenTemporaryMovieIsRemoved() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let lateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionPipelineExportTests-late-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let cleanupEvents = AsyncStream<Void>.makeStream()
        var cleanupIterator = cleanupEvents.stream.makeAsyncIterator()
        let muxer = StubCaptionMuxer(behavior: .successAfterCancellation(lateURL))
        let pipeline = makePipeline(
            embedder: muxer,
            embeddingTimeoutMargin: 0,
            discardedCaptionOutputCleanup: { url in
                try? FileManager.default.removeItem(at: url)
                _ = cleanupEvents.continuation.yield()
                cleanupEvents.continuation.finish()
            }
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.warningCode == "embeddedFallbackToSRT")
        _ = await cleanupIterator.next()
        #expect(!FileManager.default.fileExists(atPath: lateURL.path))
    }

    @Test(
        "Export-service timeout cancels in-flight caption embedding",
        .timeLimit(.minutes(1))
    )
    func givenStalledEmbeddingWhenTimeoutFiresThenCancellationIsInvoked() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let muxer = StubCaptionMuxer(behavior: .stallUntilCancelled)
        let pipeline = makePipeline(
            embedder: muxer,
            embeddingTimeoutMargin: 0
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.warningCode == "embeddedFallbackToSRT")
        for _ in 0..<100 where muxer.receivedCancellation?.didCancel != true {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(muxer.receivedCancellation?.didCancel == true)
    }

    @Test("Parent cancellation propagates instead of returning an SRT fallback")
    func givenCancelledParentWhenExportingThenCancellationPropagates() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let muxer = StubCaptionMuxer(behavior: .stallForParentCancellation)
        let pipeline = makePipeline(embedder: muxer)

        let task = Task {
            try await pipeline.exportCaptions(
                segments: sampleSegments,
                videoURL: sourceURL,
                format: .embeddedMovCaptions
            )
        }

        for _ in 0..<100 where muxer.receivedCancellation == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            for _ in 0..<100 where muxer.receivedCancellation?.didCancel != true {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(muxer.receivedCancellation?.didCancel == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private var sampleSegments: [CaptionSegment] {
        [CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello")]
    }

    private func makePipeline(
        embedder: any CaptionEmbeddingMuxing,
        embeddingTimeoutMargin: TimeInterval = 2,
        discardedCaptionOutputCleanup: @escaping @Sendable (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
        }
    ) -> CaptionPipeline {
        CaptionPipeline(
            embedder: embedder,
            embeddingTimeoutMargin: embeddingTimeoutMargin,
            embeddingCleanupScheduler: CaptionEmbeddingTimeout.CleanupScheduler(),
            discardedCaptionOutputCleanup: discardedCaptionOutputCleanup
        )
    }
}

private final class StubCaptionMuxer: CaptionEmbeddingMuxing, Sendable {
    let behavior: Behavior
    private let cancellation = Mutex<CaptionEmbeddingCancellationHolder?>(nil)

    var receivedCancellation: CaptionEmbeddingCancellationHolder? {
        cancellation.withLock { $0 }
    }

    init(result: Result<URL, CaptionPipelineExportTestError>) {
        switch result {
        case .success(let url):
            self.behavior = .success(url)
        case .failure(let error):
            self.behavior = .failure(error)
        }
    }

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    @concurrent func estimatedEmbeddingTimeout(
        for segments: [CaptionSegment],
        into videoURL: URL
    ) async throws -> TimeInterval {
        switch behavior {
        case .slowSuccess(_, let chunkCount, let stepDelay):
            return CaptionEmbeddingTimeoutBudget.totalTimeout(
                chunkCount: chunkCount,
                perStepTimeout: stepDelay,
                margin: 0
            )
        case .stall, .stallUntilCancelled, .successAfterCancellation:
            return 0.01
        case .stallForParentCancellation:
            return 60
        default:
            return CaptionEmbeddingTimeoutBudget.totalTimeout(chunkCount: 0, perStepTimeout: 10)
        }
    }

    @concurrent func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder?,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        self.cancellation.withLock { $0 = cancellation }

        switch behavior {
        case .success(let url):
            return url
        case .failure(let error):
            throw error
        case .stall:
            try await Task.sleep(for: .seconds(10))
            throw CaptionPipelineExportTestError.captionMuxFailed
        case .slowSuccess(let url, let chunkCount, let stepDelay):
            for _ in 0..<chunkCount {
                try await Task.sleep(for: .seconds(stepDelay))
            }
            return url
        case .stallUntilCancelled:
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CaptionPipelineExportTestError.captionMuxFailed
        case .stallForParentCancellation:
            try await Task.sleep(for: .seconds(60))
            throw CaptionPipelineExportTestError.captionMuxFailed
        case .successAfterCancellation(let url):
            try? await Task.sleep(for: .seconds(60))
            try Data().write(to: url)
            return url
        }
    }

    enum Behavior: Sendable {
        case success(URL)
        case failure(CaptionPipelineExportTestError)
        case stall
        case slowSuccess(URL, chunkCount: Int, stepDelay: TimeInterval)
        case stallUntilCancelled
        case stallForParentCancellation
        case successAfterCancellation(URL)
    }
}

private enum CaptionPipelineExportTestError: Error, Sendable {
    case captionMuxFailed
    case unexpectedCaptionMux
}
