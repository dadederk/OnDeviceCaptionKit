import Dispatch
import Foundation
import Synchronization
import Testing
@testable import OnDeviceCaptionKit

struct CaptionEmbeddingTimeoutTests {
    @Test("A pre-cancelled parent never starts the timeout operation")
    func givenPreCancelledParentWhenRunningEmbeddingTimeoutThenOperationDoesNotStart() async {
        let started = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { false },
                    perform: { _ in }
                ),
                operation: {
                    started.set()
                    return "done"
                }
            )
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to fail the timeout wrapper")
        } catch is CancellationError {
            #expect(!started.value)
            #expect(cleanupScheduler.outstandingReservationCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Cancellation during task installation never starts the operation")
    func givenCancellationDuringTaskInstallationWhenRunningThenOperationDoesNotStart() async {
        let started = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        let task = Task {
            try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { false },
                    perform: { _ in }
                ),
                beforeTaskInstallation: {
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                operation: {
                    started.set()
                    return "done"
                }
            )
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!started.value)
            #expect(cleanupScheduler.outstandingReservationCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A successful value discarded by timeout runs ownership cleanup")
    func givenOperationReturnsAfterTimeoutWhenResultIsDiscardedThenCleanupRuns() async {
        let discarded = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.01,
                cleanupScheduler: cleanupScheduler,
                discardedSuccessCleanup: { value in
                    #expect(value == "unreturned")
                    discarded.set()
                },
                operation: {
                    try? await Task.sleep(for: .seconds(60))
                    return "unreturned"
                }
            )
            Issue.record("Expected timeout")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
            for _ in 0..<100 where !discarded.value {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(discarded.value)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Cleanup claims resources before timeout cancels the operation")
    func givenTimeoutWhenCancellingOperationThenCleanupPreparationRunsFirst() async {
        let cleanupPrepared = LockedFlag()
        let cancellationObservedPreparation = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.05,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: {
                        cleanupPrepared.set()
                        return true
                    },
                    perform: { _ in }
                ),
                operation: {
                    try await withTaskCancellationHandler {
                        try await Task.sleep(for: .seconds(60))
                        return "done"
                    } onCancel: {
                        if cleanupPrepared.value {
                            cancellationObservedPreparation.set()
                        }
                    }
                }
            )
            Issue.record("Expected embedding timeout")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
            for _ in 0..<100 where !cancellationObservedPreparation.value {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(cancellationObservedPreparation.value)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Parent cancellation stops a long-running embedding operation")
    func givenCancelledParentWhenRunningEmbeddingTimeoutThenOperationStopsEarly() async {
        let started = LockedFlag()
        let finished = LockedFlag()
        let cleanupStarted = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        let task = Task {
            try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { true },
                    perform: { reason in
                        #expect(reason == .cancellation)
                        cleanupStarted.set()
                    }
                ),
                operation: {
                    started.set()
                    try await Task.sleep(for: .seconds(5))
                    finished.set()
                    return "done"
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to fail the timeout wrapper")
        } catch is CancellationError {
            #expect(started.value)
            #expect(!finished.value)
            for _ in 0..<100 where !cleanupStarted.value {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(cleanupStarted.value)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Timeout fires when operation exceeds budget")
    func givenSlowOperationWhenRunningEmbeddingTimeoutThenTimesOut() async throws {
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.05,
                cleanupScheduler: cleanupScheduler
            ) {
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
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.05,
                cleanupScheduler: cleanupScheduler
            ) {
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

    @Test(
        "Timeout return is independent of slow cleanup",
        .timeLimit(.minutes(1))
    )
    func givenSlowCleanupWhenTimingOutThenCallerReturnsFirst() async throws {
        let cleanupGate = DispatchSemaphore(value: 0)
        let cleanupStarted = LockedFlag()
        let cleanupFinished = LockedFlag()
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()
        defer { cleanupGate.signal() }

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.05,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { true },
                    perform: { reason in
                        #expect(reason == .timeout)
                        cleanupStarted.set()
                        cleanupGate.wait()
                        cleanupFinished.set()
                    }
                ),
                operation: {
                    try await Task.sleep(for: .seconds(60))
                    return "done"
                }
            )
            Issue.record("Expected embedding timeout")
        } catch let error as CaptionEmbeddingError {
            if case .timedOut = error {
                for _ in 0..<1_000 where !cleanupStarted.value {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                #expect(cleanupStarted.value)
                #expect(!cleanupFinished.value)
                cleanupGate.signal()
                for _ in 0..<1_000 where !cleanupFinished.value {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                #expect(cleanupFinished.value)
                return
            }
            Issue.record("Unexpected embedding error: \(error)")
        }
    }

    @Test("Cleanup admission fails fast instead of retaining a blocked-work backlog")
    func givenSaturatedCleanupWorkersWhenStartingMoreWorkThenAdmissionFailsFast() async throws {
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler(
            capacity: 2,
            admissionCapacity: 2
        )
        let cleanupGate = DispatchSemaphore(value: 0)
        let cleanupsStarted = LockedCounter()
        let thirdOperationStarted = LockedFlag()
        defer {
            cleanupGate.signal()
            cleanupGate.signal()
        }

        func blockedTimeout() -> Task<Void, Never> {
            Task {
                do {
                    _ = try await CaptionEmbeddingTimeout.run(
                        seconds: 0.01,
                        cleanupScheduler: cleanupScheduler,
                        cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                            prepare: { true },
                            perform: { _ in
                                cleanupsStarted.increment()
                                cleanupGate.wait()
                            }
                        ),
                        operation: {
                            try await Task.sleep(for: .seconds(60))
                            return "done"
                        }
                    )
                } catch {
                    // Expected timeout.
                }
            }
        }

        let first = blockedTimeout()
        let second = blockedTimeout()
        await first.value
        await second.value
        for _ in 0..<1_000 where cleanupsStarted.value < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupsStarted.value == 2)

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { false },
                    perform: { _ in }
                )
            ) {
                thirdOperationStarted.set()
                return "done"
            }
            Issue.record("Expected saturated cleanup admission to fail")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!thirdOperationStarted.value)
    }

    @Test(
        "Simultaneous timeouts cannot exceed cleanup admission capacity",
        .timeLimit(.minutes(1))
    )
    func givenTimeoutBurstWhenCleanupWorkersBlockThenBacklogRemainsBounded() async {
        let admissionCapacity = 4
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler(
            capacity: 2,
            admissionCapacity: admissionCapacity
        )
        let startBarrier = AsyncBarrier(participantCount: admissionCapacity)
        let cleanupGate = DispatchSemaphore(value: 0)
        let cleanupStarted = LockedCounter()
        let rejectedOperationStarted = LockedFlag()
        defer {
            for _ in 0..<admissionCapacity {
                cleanupGate.signal()
            }
        }

        let admittedTasks = (0..<admissionCapacity).map { _ in
            Task {
                do {
                    _ = try await CaptionEmbeddingTimeout.run(
                        seconds: 0.05,
                        cleanupScheduler: cleanupScheduler,
                        cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                            prepare: { true },
                            perform: { _ in
                                cleanupStarted.increment()
                                cleanupGate.wait()
                            }
                        )
                    ) {
                        try await startBarrier.arriveAndWait()
                        try await Task.sleep(for: .seconds(60))
                        return "done"
                    }
                } catch {
                    // Every admitted operation is expected to time out.
                }
            }
        }

        for _ in 0..<1_000 where cleanupScheduler.outstandingReservationCount < admissionCapacity {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupScheduler.outstandingReservationCount == admissionCapacity)

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { false },
                    perform: { _ in }
                )
            ) {
                rejectedOperationStarted.set()
                return "unexpected"
            }
            Issue.record("Expected cleanup admission to reject excess work")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!rejectedOperationStarted.value)

        for task in admittedTasks {
            await task.value
        }
        for _ in 0..<1_000 where cleanupScheduler.pendingCleanupCount < admissionCapacity {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupScheduler.pendingCleanupCount == admissionCapacity)
        #expect(cleanupScheduler.outstandingReservationCount == admissionCapacity)

        for _ in 0..<admissionCapacity {
            cleanupGate.signal()
        }
        for _ in 0..<1_000 where cleanupScheduler.outstandingReservationCount > 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupStarted.value == admissionCapacity)
        #expect(cleanupScheduler.pendingCleanupCount == 0)
        #expect(cleanupScheduler.outstandingReservationCount == 0)
    }

    @Test(
        "Prompt cleanup keeps admission reserved while operations remain stuck",
        .timeLimit(.minutes(1))
    )
    func givenStuckOperationsAfterCleanupWhenStartingMoreWorkThenAdmissionRemainsSaturated() async {
        let admissionCapacity = 2
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler(
            capacity: 2,
            admissionCapacity: admissionCapacity
        )
        let startBarrier = AsyncBarrier(participantCount: admissionCapacity)
        let operationGate = AsyncGate()
        let cleanupsFinished = LockedCounter()
        let rejectedOperationStarted = LockedFlag()

        let admittedTasks = (0..<admissionCapacity).map { _ in
            Task {
                do {
                    _ = try await CaptionEmbeddingTimeout.run(
                        seconds: 0.01,
                        cleanupScheduler: cleanupScheduler,
                        cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                            prepare: { true },
                            perform: { _ in cleanupsFinished.increment() }
                        )
                    ) {
                        try await startBarrier.arriveAndWait()
                        await operationGate.wait()
                        return "late"
                    }
                } catch {
                    // Every admitted caller is expected to return on timeout.
                }
            }
        }

        for task in admittedTasks {
            await task.value
        }
        for _ in 0..<1_000 where cleanupsFinished.value < admissionCapacity {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupsFinished.value == admissionCapacity)
        #expect(cleanupScheduler.pendingCleanupCount == 0)
        #expect(cleanupScheduler.outstandingReservationCount == admissionCapacity)

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 60,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { false },
                    perform: { _ in }
                )
            ) {
                rejectedOperationStarted.set()
                return "unexpected"
            }
            Issue.record("Expected stuck operations to keep admission saturated")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!rejectedOperationStarted.value)

        operationGate.open()
        for _ in 0..<1_000 where cleanupScheduler.outstandingReservationCount > 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupScheduler.outstandingReservationCount == 0)
    }

    @Test(
        "Temporary-file cleanup waits for scheduled SDK cancellation",
        .timeLimit(.minutes(1))
    )
    func givenFinishedOperationWhileSDKCleanupIsQueuedThenFileRemainsUntilCleanupCompletes() async throws {
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler()
        let cancellationHolder = CaptionEmbeddingCancellationHolder()
        let temporaryFiles = CaptionEmbeddingTemporaryFiles()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionEmbeddingTimeoutTests-cleanup-\(UUID().uuidString)")
        try Data("owned".utf8).write(to: temporaryURL)
        temporaryFiles.register(temporaryURL)
        #expect(cancellationHolder.setTemporaryFiles(temporaryFiles))
        let operationLease = temporaryFiles.beginOperation()
        let cleanupGate = DispatchSemaphore(value: 0)
        let cleanupStarted = LockedFlag()
        defer {
            cleanupGate.signal()
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            _ = try await CaptionEmbeddingTimeout.run(
                seconds: 0.01,
                cleanupScheduler: cleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: { cancellationHolder.prepareCancellation() },
                    perform: { _ in
                        cleanupStarted.set()
                        cleanupGate.wait()
                        cancellationHolder.performPreparedCancellation()
                    }
                ),
                operationCompletion: { operationLease.finish() }
            ) {
                try await Task.sleep(for: .seconds(60))
                return "done"
            }
            Issue.record("Expected timeout")
        } catch let error as CaptionEmbeddingError {
            guard case .timedOut = error else {
                Issue.record("Unexpected embedding error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        for _ in 0..<1_000 where !cleanupStarted.value {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cleanupStarted.value)
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))

        cleanupGate.signal()
        for _ in 0..<1_000 where FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test(
        "Healthy concurrent operations do not consume cleanup admission",
        .timeLimit(.minutes(1))
    )
    func givenHealthyConcurrentOperationsWhenCleanupIsIdleThenEveryOperationStarts() async {
        let cleanupScheduler = CaptionEmbeddingTimeout.CleanupScheduler(capacity: 2)
        let startBarrier = AsyncBarrier(participantCount: 3)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        _ = try await CaptionEmbeddingTimeout.run(
                            seconds: 60,
                            cleanupScheduler: cleanupScheduler
                        ) {
                            try await startBarrier.arriveAndWait()
                            return "done"
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            Issue.record("Expected every healthy operation to complete: \(error)")
        }
    }
}

private final class LockedFlag: Sendable {
    private let flag = Mutex(false)

    var value: Bool {
        flag.withLock { $0 }
    }

    func set() {
        flag.withLock { $0 = true }
    }
}

private final class LockedCounter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

private final class AsyncBarrier: Sendable {
    private enum InstallationAction {
        case stored
        case resumeSuccess([CheckedContinuation<Void, Error>])
        case resumeCancellation(CheckedContinuation<Void, Error>)
    }

    private struct State: ~Copyable {
        var arrivalCount = 0
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private let participantCount: Int
    private let state = Mutex(State())

    init(participantCount: Int) {
        precondition(participantCount > 0)
        self.participantCount = participantCount
    }

    func arriveAndWait() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action = state.withLock { state -> InstallationAction in
                    if Task.isCancelled {
                        return .resumeCancellation(continuation)
                    }
                    if state.isOpen {
                        return .resumeSuccess([continuation])
                    }

                    state.arrivalCount += 1
                    if state.arrivalCount == participantCount {
                        state.isOpen = true
                        let continuations = Array(state.waiters.values) + [continuation]
                        state.waiters.removeAll()
                        return .resumeSuccess(continuations)
                    }

                    state.waiters[waiterID] = continuation
                    return .stored
                }

                switch action {
                case .stored:
                    break
                case .resumeSuccess(let continuations):
                    for continuation in continuations {
                        continuation.resume()
                    }
                case .resumeCancellation(let continuation):
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.waiters.removeValue(forKey: waiterID)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class AsyncGate: Sendable {
    private enum State {
        case waiting([CheckedContinuation<Void, Never>])
        case open
    }

    private let state = Mutex(State.waiting([]))

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                switch state {
                case .waiting(var waiters):
                    waiters.append(continuation)
                    state = .waiting(waiters)
                    return false
                case .open:
                    return true
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard case .waiting(let waiters) = state else { return [] }
            state = .open
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
