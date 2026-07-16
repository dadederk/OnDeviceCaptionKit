import AVFoundation
import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionTimingTests {
    @Test("SRT timestamps preserve segment start and end times")
    func givenKnownSegmentsWhenGeneratingSRTThenTimestampsMatch() {
        let generator = SRTWriter()
        let segments = [
            CaptionSegment(index: 1, startTime: 1.5, endTime: 3.25, text: "Hello world")
        ]

        let content = generator.createSRTContent(from: segments)

        #expect(content.contains("00:00:01,500 --> 00:00:03,250"))
        #expect(content.contains("Hello world"))
    }

    @Test("Closed captions preserve segment timing within frame alignment tolerance")
    func givenKnownSegmentsWhenMakingCaptionsThenStartTimesAlign() throws {
        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 1.0, endTime: 2.5, text: "Hello"),
            CaptionSegment(index: 2, startTime: 2.5, endTime: 4.0, text: "World")
        ]

        let captions = try muxer.makeClosedCaptions(from: segments)

        #expect(captions.count >= 2)
        #expect(abs(CMTimeGetSeconds(captions[0].timeRange.start) - 1.0) < 0.1)
        #expect(abs(CMTimeGetSeconds(captions[1].timeRange.start) - 2.5) < 0.1)
        #expect(CMTimeCompare(captions[0].timeRange.end, captions[1].timeRange.start) <= 0
            || abs(CMTimeGetSeconds(captions[0].timeRange.end) - 2.5) < 0.1)
    }

    @Test("SRT sidecar export defers file write until caller supplies destination")
    func givenSegmentsWhenExportingSRTSidecarThenTimestampsMatchAfterWrite() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionTimingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let videoURL = tempDirectory.appendingPathComponent("Recording.mov")
        try Data("stub".utf8).write(to: videoURL)

        let segments = [
            CaptionSegment(index: 1, startTime: 0.5, endTime: 1.75, text: "Aligned")
        ]
        let pipeline = CaptionPipeline()
        let result = try await pipeline.exportCaptions(
            segments: segments,
            videoURL: videoURL,
            format: .srtSidecar
        )

        let deferred = try #require(result.deferredSRTSegments)
        try pipeline.writeSRT(segments: deferred, besideVideoAt: videoURL)
        let srtURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
        let srtContent = try String(contentsOf: srtURL, encoding: .utf8)

        #expect(srtContent.contains("00:00:00,500 --> 00:00:01,750"))
        #expect(srtContent.contains("Aligned"))
    }
}
