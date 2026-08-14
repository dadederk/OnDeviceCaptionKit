import CoreMedia
import Foundation
import Speech
import Testing
@testable import OnDeviceCaptionKit

struct TimedTranscriptSegmenterTests {
    @available(macOS 26, *)
    @Test("Time-indexed words become readable caption cues with exact boundaries")
    func readableTimedCues() throws {
        let tokens = [
            token("Hello ", start: 0, duration: 0.5),
            token("world.", start: 0.5, duration: 0.5),
            token("Next ", start: 1.2, duration: 0.4),
            token("caption", start: 1.6, duration: 0.6),
        ]

        let segments = try TimedTranscriptSegmenter.segments(from: tokens, startingAt: 3)

        #expect(segments == [
            CaptionSegment(index: 3, startTime: 0, endTime: 1, text: "Hello world."),
            CaptionSegment(index: 4, startTime: 1.2, endTime: 2.2, text: "Next caption"),
        ])
    }

    @available(macOS 26, *)
    @Test("Long speech is split without losing token timing")
    func boundedCues() throws {
        let tokens = (0..<20).map { offset in
            token("word ", start: Double(offset) * 0.35, duration: 0.3)
        }

        let segments = try TimedTranscriptSegmenter.segments(from: tokens, startingAt: 1)

        #expect(segments.count > 1)
        #expect(segments.first?.startTime == 0)
        #expect(abs((segments.last?.endTime ?? 0) - 6.95) < 0.002)
        #expect(segments.map(\.index) == Array(1...segments.count))
    }

    @available(macOS 26, *)
    @Test("Missing timing fails instead of dropping recognized text")
    func missingTimingFailsAtomically() throws {
        var transcript = AttributedString("Timed untimed")
        let boundary = transcript.index(transcript.startIndex, offsetByCharacters: 5)
        transcript[transcript.startIndex..<boundary].audioTimeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 0.5, preferredTimescale: 1_000)
        )

        #expect(throws: TimedTranscriptSegmenter.Error.missingTiming) {
            try TimedTranscriptSegmenter.segments(from: transcript, startingAt: 1)
        }
    }

    @available(macOS 26, *)
    @Test("Non-monotonic timed runs fail safely")
    func nonMonotonicTimingFails() {
        let tokens = [
            token("later ", start: 2, duration: 0.5),
            token("earlier", start: 1, duration: 0.5),
        ]

        #expect(throws: TimedTranscriptSegmenter.Error.nonMonotonicTiming) {
            try TimedTranscriptSegmenter.segments(from: tokens, startingAt: 1)
        }
    }

    @available(macOS 26, *)
    @Test("Whitespace between timed runs is preserved")
    func whitespaceIsPreserved() throws {
        var transcript = AttributedString("Hello world")
        let space = try #require(transcript.characters.firstIndex(of: " "))
        let afterSpace = transcript.characters.index(after: space)
        transcript[transcript.startIndex..<space].audioTimeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 0.4, preferredTimescale: 1_000)
        )
        transcript[afterSpace..<transcript.endIndex].audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.4, preferredTimescale: 1_000)
        )

        let segments = try TimedTranscriptSegmenter.segments(from: transcript, startingAt: 1)

        #expect(segments.map(\.text) == ["Hello world"])
        #expect(segments.first?.startTime == 0)
        #expect(abs((segments.first?.endTime ?? 0) - 0.9) < 0.002)
    }

    private func token(_ text: String, start: Double, duration: Double) -> TimedTranscriptSegmenter.Token {
        TimedTranscriptSegmenter.Token(
            text: text,
            timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1_000),
                duration: CMTime(seconds: duration, preferredTimescale: 1_000)
            )
        )
    }
}
