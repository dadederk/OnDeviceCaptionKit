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
}
