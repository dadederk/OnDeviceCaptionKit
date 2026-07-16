import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionPipelineExportTests {
    @Test("Embedded subtitle mode returns the captioned MOV and no deferred SRT")
    func givenEmbeddedModeWhenExportingThenCaptionMuxerResultIsUsed() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let captionedURL = URL(fileURLWithPath: "/tmp/captioned.mov")
        let pipeline = CaptionPipeline(
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
        let pipeline = CaptionPipeline(
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

    @Test("Embedded subtitle mode falls back to deferred SRT when caption muxing fails")
    func givenEmbeddedModeWhenCaptionMuxingFailsThenSRTFallbackIsReturned() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let pipeline = CaptionPipeline(
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
        let pipeline = CaptionPipeline(
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
        let pipeline = CaptionPipeline(
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
        let pipeline = CaptionPipeline(
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
        "Export-service timeout cancels in-flight caption embedding",
        .timeLimit(.minutes(1))
    )
    func givenStalledEmbeddingWhenTimeoutFiresThenCancellationIsInvoked() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let muxer = StubCaptionMuxer(behavior: .stallUntilCancelled)
        let pipeline = CaptionPipeline(
            embedder: muxer,
            embeddingTimeoutMargin: 0
        )

        let result = try await pipeline.exportCaptions(
            segments: sampleSegments,
            videoURL: sourceURL,
            format: .embeddedMovCaptions
        )

        #expect(result.warningCode == "embeddedFallbackToSRT")
        #expect(muxer.receivedCancellation?.didCancel == true)
    }

    private var sampleSegments: [CaptionSegment] {
        [CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello")]
    }
}

private final class StubCaptionMuxer: CaptionEmbeddingMuxing, @unchecked Sendable {
    let behavior: Behavior
    private(set) var receivedCancellation: CaptionEmbeddingCancellationHolder?

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

    func estimatedEmbeddingTimeout(
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
        case .stall, .stallUntilCancelled:
            return 0.01
        default:
            return CaptionEmbeddingTimeoutBudget.totalTimeout(chunkCount: 0, perStepTimeout: 10)
        }
    }

    func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder?,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        receivedCancellation = cancellation

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
        }
    }

    enum Behavior: Sendable {
        case success(URL)
        case failure(CaptionPipelineExportTestError)
        case stall
        case slowSuccess(URL, chunkCount: Int, stepDelay: TimeInterval)
        case stallUntilCancelled
    }
}

private enum CaptionPipelineExportTestError: Error, Sendable {
    case captionMuxFailed
    case unexpectedCaptionMux
}
