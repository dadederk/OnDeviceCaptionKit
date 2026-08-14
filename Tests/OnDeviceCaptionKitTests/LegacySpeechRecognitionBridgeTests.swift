import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct LegacySpeechRecognitionBridgeTests {
    @Test("A cancelled bridge rejects continuation installation")
    func givenCancelledBridgeWhenInstallingContinuationThenItRejectsRecognition() async {
        let bridge = LegacySpeechRecognitionBridge()
        bridge.cancel()

        do {
            let _: LegacySpeechRecognitionSnapshot = try await withCheckedThrowingContinuation { continuation in
                let admitted = bridge.install(continuation: continuation)
                #expect(!admitted)
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Bridge cancellation resumes an installed continuation once")
    func givenInstalledContinuationWhenCancellingTwiceThenItResumesOnce() async {
        let bridge = LegacySpeechRecognitionBridge()

        do {
            let _: LegacySpeechRecognitionSnapshot = try await withCheckedThrowingContinuation { continuation in
                #expect(bridge.install(continuation: continuation))
                bridge.cancel()
                bridge.cancel()
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Late recognition callbacks are rejected after cancellation")
    func givenCancelledBridgeWhenCallbackArrivesThenItIsRejected() {
        let bridge = LegacySpeechRecognitionBridge()
        #expect(bridge.shouldProcessCallback())

        bridge.cancel()

        #expect(!bridge.shouldProcessCallback())
    }

    @Test("Pre-cancelled legacy post-processing exits immediately")
    func givenPreCancelledTaskWhenProcessingRecognitionThenItThrowsCancellation() async {
        let provider = LegacySpeechProvider()
        let snapshot = LegacySpeechRecognitionSnapshot(
            segments: [
                .init(substring: "Hello", startTime: 0, endTime: 1),
                .init(substring: "world", startTime: 1, endTime: 2),
            ]
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.processRecognitionResult(snapshot, duration: 2)
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

    @Test("Legacy post-processing preserves short recognized speech")
    func givenShortSpeechWhenProcessingRecognitionThenNoWordsAreDropped() async throws {
        let provider = LegacySpeechProvider()
        let snapshot = LegacySpeechRecognitionSnapshot(
            segments: [
                .init(substring: "Yes.", startTime: 2.0, endTime: 2.35),
                .init(substring: "Next", startTime: 3.2, endTime: 3.5),
                .init(substring: "line.", startTime: 3.5, endTime: 3.9),
            ]
        )

        let captions = try await provider.processRecognitionResult(snapshot, duration: 8)

        #expect(captions.map(\.text) == ["Yes.", "Next line."])
        #expect(captions.map(\.startTime) == [2.0, 3.2])
        #expect(captions.map(\.endTime) == [2.35, 3.9])
    }

    @Test("Legacy post-processing splits at pauses without absorbing silence")
    func givenPauseWhenProcessingRecognitionThenCueTimingUsesRecognizedWords() async throws {
        let provider = LegacySpeechProvider()
        let snapshot = LegacySpeechRecognitionSnapshot(
            segments: [
                .init(substring: "First", startTime: 4.0, endTime: 4.4),
                .init(substring: "thought", startTime: 4.4, endTime: 4.9),
                .init(substring: "second", startTime: 6.0, endTime: 6.4),
                .init(substring: "thought", startTime: 6.4, endTime: 6.9),
            ]
        )

        let captions = try await provider.processRecognitionResult(snapshot, duration: 12)

        #expect(captions.map(\.text) == ["First thought.", "Second thought."])
        #expect(captions.map(\.startTime) == [4.0, 6.0])
        #expect(captions.map(\.endTime) == [4.9, 6.9])
    }

    @Test("Legacy post-processing creates readable cues without losing continuous speech")
    func givenLongSpeechWhenProcessingRecognitionThenEveryWordIsPreserved() async throws {
        let provider = LegacySpeechProvider()
        let words = (0..<24).map { "word\($0)" }
        let snapshot = LegacySpeechRecognitionSnapshot(
            segments: words.enumerated().map { offset, word in
                .init(
                    substring: word,
                    startTime: Double(offset) * 0.4,
                    endTime: Double(offset) * 0.4 + 0.35
                )
            }
        )

        let captions = try await provider.processRecognitionResult(snapshot, duration: 12)
        let preservedWords = captions
            .flatMap { $0.text.components(separatedBy: .whitespaces) }
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }

        #expect(captions.count > 1)
        #expect(captions.allSatisfy { $0.text.count <= 65 })
        #expect(preservedWords == words)
    }
}
