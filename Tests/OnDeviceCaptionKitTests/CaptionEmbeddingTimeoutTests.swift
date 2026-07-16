import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionEmbeddingTimeoutTests {
    @Test("Parent cancellation stops a long-running embedding operation")
    func givenCancelledParentWhenRunningEmbeddingTimeoutThenOperationStopsEarly() async {
        let started = LockedFlag()
        let finished = LockedFlag()

        let task = Task {
            try await CaptionEmbeddingTimeout.run(seconds: 60) {
                started.set()
                try await Task.sleep(for: .seconds(5))
                finished.set()
                return "done"
            }
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to fail the timeout wrapper")
        } catch is CancellationError {
            #expect(started.value)
            #expect(!finished.value)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Timeout fires when operation exceeds budget")
    func givenSlowOperationWhenRunningEmbeddingTimeoutThenTimesOut() async throws {
        do {
            _ = try await CaptionEmbeddingTimeout.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(1))
                return "done"
            }
            Issue.record("Expected embedding timeout")
        } catch let error as CaptionEmbeddingError {
            if case .timedOut = error {
                return
            }
            Issue.record("Unexpected embedding error: \(error)")
        }
    }

    @Test("Timeout returns without waiting for a stuck operation to finish")
    func givenHungOperationWhenRunningEmbeddingTimeoutThenReturnsOnTimeoutBudget() async throws {
        let start = ContinuousClock.now

        do {
            _ = try await CaptionEmbeddingTimeout.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(60))
                return "done"
            }
            Issue.record("Expected embedding timeout")
        } catch let error as CaptionEmbeddingError {
            if case .timedOut = error {
                let elapsed = start.duration(to: .now)
                #expect(elapsed < .seconds(1))
                return
            }
            Issue.record("Unexpected embedding error: \(error)")
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
