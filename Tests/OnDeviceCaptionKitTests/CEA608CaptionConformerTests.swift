import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import OnDeviceCaptionKit

@Suite(.timeLimit(.minutes(1)))
struct CEA608CaptionConformerTests {
    private let frame = CMTime(value: 1001, timescale: 30_000)

    @Test("Short early captions fail recoverably", arguments: [1, 2, 3])
    func shortEarlyCaptionsFailSafely(frames: Int) throws {
        let conformer = try CEA608CaptionConformer(frameDuration: frame)
        #expect(throws: CaptionEmbeddingError.self) {
            try conformer.conformedCaption(
                text: "Hello",
                timeRange: CMTimeRange(
                    start: frame,
                    duration: CMTimeMultiply(frame, multiplier: Int32(frames))
                )
            )
        }
    }

    @Test("Supported caption timing matches AVFoundation", arguments: ["Hello", String(repeating: "™", count: 32)])
    func supportedCaptionsKeepTiming(text: String) throws {
        let range = CMTimeRange(start: frame, duration: CMTime(value: 90_000, timescale: 30_000))
        let actual = try CEA608CaptionConformer(frameDuration: frame)
            .conformedCaption(text: text, timeRange: range)
        let reference = AVCaptionFormatConformer(conversionSettings: [
            .mediaType: AVMediaType.closedCaption,
            .mediaSubType: NSNumber(value: kCMClosedCaptionFormatType_CEA608),
            .timeCodeFrameDuration: NSValue(time: frame)
        ])
        reference.conformsCaptionsToTimeRange = true
        let expected = try reference.conformedCaption(for: AVCaption(text, timeRange: range))
        #expect(actual.text == expected.text)
        #expect(CMTimeRangeEqual(actual.timeRange, expected.timeRange))
    }

    @Test("Short later captions remain supported")
    func shortLaterCaptionConverts() throws {
        let range = CMTimeRange(start: CMTime(value: 300_300, timescale: 30_000), duration: frame)
        let actual = try CEA608CaptionConformer(frameDuration: frame)
            .conformedCaption(text: "Hello", timeRange: range)
        #expect(CMTimeRangeEqual(actual.timeRange, range))
    }

    @Test("CEA-608 timing boundaries return numeric captions or recoverable errors",
          arguments: ["x", "Hello", String(repeating: "a", count: 32), String(repeating: "™", count: 32)])
    func timingBoundariesFailSafely(text: String) throws {
        let conformer = try CEA608CaptionConformer(frameDuration: frame)
        for startFrame in [0, 1, 2, 3, 4, 8, 16, 30, 90] {
            for durationFrames in [1, 2, 3, 4, 8, 16, 30, 90] {
                do {
                    let caption = try conformer.conformedCaption(
                        text: text,
                        timeRange: CMTimeRange(
                            start: CMTimeMultiply(frame, multiplier: Int32(startFrame)),
                            duration: CMTimeMultiply(frame, multiplier: Int32(durationFrames))
                        )
                    )
                    #expect(caption.timeRange.start.isNumeric)
                    #expect(caption.timeRange.duration.isNumeric)
                    #expect(caption.timeRange.duration > .zero)
                } catch let error as CaptionEmbeddingError {
                    guard case .captionConformanceFailed = error else {
                        Issue.record("Unexpected embedding error: \(error)")
                        return
                    }
                }
            }
        }
    }

    @Test("Invalid caption times fail before AVFoundation", arguments: [
        CMTime.invalid, .indefinite, .positiveInfinity, .zero,
        CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0),
        CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)
    ])
    func invalidTimesFailSafely(time: CMTime) throws {
        let conformer = try CEA608CaptionConformer(frameDuration: frame)
        #expect(throws: CaptionEmbeddingError.self) {
            try conformer.conformedCaption(text: "Hello", timeRange: CMTimeRange(start: frame, duration: time))
        }
        if !time.isNumeric || time.timescale <= 0 {
            #expect(throws: CaptionEmbeddingError.self) {
                try conformer.conformedCaption(text: "Hello", timeRange: CMTimeRange(start: time, duration: frame))
            }
        }
    }

    @Test("Invalid frame durations fail before AVFoundation",
          arguments: [
            CMTime.invalid, .indefinite, .positiveInfinity, .zero,
            CMTime(value: -1, timescale: 30),
            CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0),
            CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)
          ])
    func invalidFrameDurationsFailSafely(frameDuration: CMTime) {
        #expect(throws: CaptionEmbeddingError.self) {
            try CEA608CaptionConformer(frameDuration: frameDuration)
        }
    }

    @Test("A short chunk-start probe preserves the video and complete SRT fallback")
    func shortChunkProbeFallsBack() async throws {
        // A caption-only source exercises the real embedding boundary without
        // requiring a video encoder, microphone, or Speech recognition.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortCueFallback-\(UUID().uuidString).mov")
        let srtURL = url.deletingPathExtension().appendingPathExtension("srt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: srtURL)
        }
        let donorSegments = [CaptionSegment(index: 1, startTime: 0, endTime: 2, text: "Donor")]
        try await Tx3gCaptionTrackWriter().write(
            tracks: [try CaptionLanguageTrack(languageIdentifier: "en-US", segments: donorSegments)],
            to: url,
            presentationSize: CGSize(width: 640, height: 480)
        )
        let sourceData = try Data(contentsOf: url)
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 0.1, text: "Hello"),
            CaptionSegment(index: 2, startTime: 0.5, endTime: 1.5, text: "Keep this cue too")
        ]
        let pipeline = CaptionPipeline(configuration: .init(speechAuthorizationProvider: NoSpeechAuthorization()))
        let result = try await pipeline.exportCaptions(
            segments: segments,
            videoURL: url,
            format: .embeddedMovCaptions
        )
        #expect(result.videoURL == url)
        #expect(result.deferredSRTSegments == segments)
        #expect(result.warningCode == "embeddedFallbackToSRT")
        #expect(try Data(contentsOf: url) == sourceData)
        let deferred = try #require(result.deferredSRTSegments)
        try await pipeline.writeSRT(segments: deferred, besideVideoAt: result.videoURL)
        let sidecar = try String(contentsOf: srtURL, encoding: .utf8)
        #expect(sidecar == """
        1
        00:00:00,000 --> 00:00:00,100
        Hello

        2
        00:00:00,500 --> 00:00:01,500
        Keep this cue too

        """)
    }
}

private struct NoSpeechAuthorization: SpeechAuthorizationProviding {
    @concurrent
    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        Issue.record("Caption export must not request Speech authorization")
        return .denied
    }
}
