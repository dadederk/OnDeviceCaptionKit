import Foundation
import Synchronization

nonisolated enum CaptionEmbeddingTimeout {
    enum CleanupReason: Equatable, Sendable {
        case timeout
        case cancellation
    }

    struct CleanupPlan: Sendable {
        let prepare: @Sendable () -> Bool
        let perform: @Sendable (CleanupReason) -> Void
    }

    private final class StartGate: Sendable {
        private enum State {
            case waiting([CheckedContinuation<Bool, Never>])
            case resolved(Bool)
        }

        private let state = Mutex(State.waiting([]))

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                let decision = state.withLock { state -> Bool? in
                    switch state {
                    case .waiting(var continuations):
                        continuations.append(continuation)
                        state = .waiting(continuations)
                        return nil
                    case .resolved(let decision):
                        return decision
                    }
                }
                if let decision {
                    continuation.resume(returning: decision)
                }
            }
        }

        func resolve(_ decision: Bool) {
            let continuations = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
                guard case .waiting(let continuations) = state else { return [] }
                state = .resolved(decision)
                return continuations
            }
            for continuation in continuations {
                continuation.resume(returning: decision)
            }
        }
    }

    final class CleanupScheduler: Sendable {
        private struct State: ~Copyable {
            var reservationCount = 0
            var scheduledCleanupCount = 0
        }

        final class Reservation: Sendable {
            private enum CleanupState {
                case pending
                case scheduled
                case completed
            }

            private struct State: ~Copyable {
                var cleanupState = CleanupState.pending
                var isOperationComplete = false
                var isReleased = false
            }

            private let scheduler: CleanupScheduler
            private let state = Mutex(State())

            init(scheduler: CleanupScheduler) {
                self.scheduler = scheduler
            }

            func schedule(_ cleanup: @escaping @Sendable () -> Void) {
                let shouldSchedule = state.withLock { state in
                    guard state.cleanupState == .pending else { return false }
                    state.cleanupState = .scheduled
                    return true
                }
                guard shouldSchedule else { return }
                scheduler.scheduleReserved(cleanup, reservation: self)
            }

            func completeOperation() {
                let shouldRelease = state.withLock { state in
                    guard !state.isOperationComplete else { return false }
                    state.isOperationComplete = true
                    return Self.shouldRelease(state: &state)
                }
                if shouldRelease {
                    scheduler.releaseReservation()
                }
            }

            func completeWithoutCleanup() {
                let shouldRelease = state.withLock { state in
                    guard state.cleanupState == .pending else { return false }
                    state.cleanupState = .completed
                    return Self.shouldRelease(state: &state)
                }
                if shouldRelease {
                    scheduler.releaseReservation()
                }
            }

            func completeCleanup() {
                let shouldRelease = state.withLock { state in
                    guard state.cleanupState == .scheduled else { return false }
                    state.cleanupState = .completed
                    return Self.shouldRelease(state: &state)
                }
                if shouldRelease {
                    scheduler.releaseReservation()
                }
            }

            private static func shouldRelease(state: inout State) -> Bool {
                guard state.isOperationComplete,
                      state.cleanupState == .completed,
                      !state.isReleased else {
                    return false
                }
                state.isReleased = true
                return true
            }
        }

        private let admissionCapacity: Int
        private let queue: OperationQueue
        private let state = Mutex(State())

        init(capacity: Int = 2, admissionCapacity: Int = 8) {
            precondition(capacity > 0)
            precondition(admissionCapacity > 0)
            self.admissionCapacity = admissionCapacity
            let queue = OperationQueue()
            queue.name = "OnDeviceCaptionKit.CaptionEmbeddingCleanup"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = capacity
            self.queue = queue
        }

        var outstandingReservationCount: Int {
            state.withLock { $0.reservationCount }
        }

        var pendingCleanupCount: Int {
            state.withLock { $0.scheduledCleanupCount }
        }

        func reserve() throws -> Reservation {
            try state.withLock { state in
                guard state.reservationCount < admissionCapacity else {
                    throw CaptionEmbeddingError.timedOut
                }
                state.reservationCount += 1
            }
            return Reservation(scheduler: self)
        }

        private func scheduleReserved(
            _ cleanup: @escaping @Sendable () -> Void,
            reservation: Reservation
        ) {
            let backlog = state.withLock { state in
                state.scheduledCleanupCount += 1
                return state.scheduledCleanupCount
            }
            if backlog > 1 {
                CaptionLogger.info("Queued caption cleanup (\(backlog) pending)")
            }

            queue.addOperation { [self] in
                defer {
                    state.withLock { state in
                        state.scheduledCleanupCount -= 1
                    }
                    reservation.completeCleanup()
                }
                cleanup()
            }
        }

        private func releaseReservation() {
            state.withLock { state in
                state.reservationCount -= 1
            }
        }
    }

    static let sharedCleanupScheduler = CleanupScheduler()

    private final class TimeoutRace<Value: Sendable>: Sendable {
        private struct Completion {
            let didTransition: Bool
            let continuation: CheckedContinuation<Value, Error>?
            let operationTask: Task<Void, Never>?
            let timeoutTask: Task<Void, Never>?
        }

        private struct State: ~Copyable {
            var continuation: CheckedContinuation<Value, Error>?
            var operationTask: Task<Void, Never>?
            var timeoutTask: Task<Void, Never>?
            var isFinished = false
        }

        private let state = Mutex(State())
        private let cleanupReservation: CleanupScheduler.Reservation?

        init(cleanupReservation: CleanupScheduler.Reservation?) {
            self.cleanupReservation = cleanupReservation
        }

        func start(
            seconds: TimeInterval,
            cleanupPlan: CleanupPlan?,
            discardedSuccessCleanup: @escaping @Sendable (Value) -> Void,
            operationCompletion: @escaping @Sendable () -> Void,
            beforeTaskInstallation: @escaping @Sendable () -> Void,
            operation: @escaping @Sendable () async throws -> Value,
            continuation: CheckedContinuation<Value, Error>
        ) {
            let shouldStart = state.withLock { state in
                guard !state.isFinished else { return false }
                state.continuation = continuation
                return true
            }
            guard shouldStart else {
                operationCompletion()
                cleanupReservation?.completeOperation()
                cleanupReservation?.completeWithoutCleanup()
                continuation.resume(throwing: CancellationError())
                return
            }

            beforeTaskInstallation()
            let startGate = StartGate()
            let operationTask = Task { @concurrent [self] in
                guard await startGate.wait(), !Task.isCancelled else {
                    operationCompletion()
                    cleanupReservation?.completeOperation()
                    return
                }
                do {
                    let value = try await operation()
                    operationCompletion()
                    cleanupReservation?.completeOperation()
                    self.finishSuccess(
                        with: value,
                        discardedSuccessCleanup: discardedSuccessCleanup
                    )
                } catch {
                    operationCompletion()
                    cleanupReservation?.completeOperation()
                    self.finishFailure(with: error)
                }
            }

            let timeoutTask = Task { @concurrent [self] in
                guard await startGate.wait(), !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                self.fireTimeout(
                    cleanupPlan: cleanupPlan
                )
            }

            let installed = state.withLock { state -> Bool in
                guard !state.isFinished else { return false }
                state.operationTask = operationTask
                state.timeoutTask = timeoutTask
                return true
            }
            startGate.resolve(installed)
            if !installed {
                operationTask.cancel()
                timeoutTask.cancel()
            }
        }

        func cancelFromParent(cleanupPlan: CleanupPlan?) {
            let completion = claimCompletion()
            guard completion.didTransition else { return }

            let shouldScheduleCleanup = cleanupPlan?.prepare() == true
            completion.operationTask?.cancel()
            completion.timeoutTask?.cancel()
            completion.continuation?.resume(throwing: CancellationError())
            finishCleanup(
                shouldSchedule: shouldScheduleCleanup,
                plan: cleanupPlan,
                reason: .cancellation
            )
        }

        private func fireTimeout(cleanupPlan: CleanupPlan?) {
            let completion = claimCompletion()
            guard completion.didTransition else { return }

            let shouldScheduleCleanup = cleanupPlan?.prepare() == true
            completion.operationTask?.cancel()
            completion.continuation?.resume(throwing: CaptionEmbeddingError.timedOut)
            finishCleanup(
                shouldSchedule: shouldScheduleCleanup,
                plan: cleanupPlan,
                reason: .timeout
            )
        }

        private func finishSuccess(
            with value: sending Value,
            discardedSuccessCleanup: @escaping @Sendable (Value) -> Void
        ) {
            let completion = claimCompletion()
            guard completion.didTransition else {
                discardedSuccessCleanup(value)
                return
            }

            cleanupReservation?.completeWithoutCleanup()
            completion.operationTask?.cancel()
            completion.timeoutTask?.cancel()
            completion.continuation?.resume(returning: value)
        }

        private func finishFailure(with error: sending Error) {
            let completion = claimCompletion()
            guard completion.didTransition else { return }

            cleanupReservation?.completeWithoutCleanup()
            completion.operationTask?.cancel()
            completion.timeoutTask?.cancel()
            completion.continuation?.resume(throwing: error)
        }

        private func finishCleanup(
            shouldSchedule: Bool,
            plan: CleanupPlan?,
            reason: CleanupReason
        ) {
            guard shouldSchedule, let plan, let cleanupReservation else {
                self.cleanupReservation?.completeWithoutCleanup()
                return
            }
            cleanupReservation.schedule {
                plan.perform(reason)
            }
        }

        private func claimCompletion() -> Completion {
            state.withLock { state in
                guard !state.isFinished else {
                    return Completion(
                        didTransition: false,
                        continuation: nil,
                        operationTask: nil,
                        timeoutTask: nil
                    )
                }
                state.isFinished = true
                let continuation = state.continuation
                let operationTask = state.operationTask
                let timeoutTask = state.timeoutTask
                state.continuation = nil
                state.operationTask = nil
                state.timeoutTask = nil
                return Completion(
                    didTransition: true,
                    continuation: continuation,
                    operationTask: operationTask,
                    timeoutTask: timeoutTask
                )
            }
        }
    }

    static func run<Value: Sendable>(
        seconds: TimeInterval,
        cleanupScheduler: CleanupScheduler = sharedCleanupScheduler,
        cleanupPlan: CleanupPlan? = nil,
        discardedSuccessCleanup: @escaping @Sendable (Value) -> Void = { _ in },
        operationCompletion: @escaping @Sendable () -> Void = {},
        beforeTaskInstallation: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let cleanupReservation: CleanupScheduler.Reservation?
        do {
            cleanupReservation = try cleanupPlan.map { _ in
                try cleanupScheduler.reserve()
            }
        } catch {
            operationCompletion()
            throw error
        }
        let race = TimeoutRace<Value>(cleanupReservation: cleanupReservation)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                race.start(
                    seconds: seconds,
                    cleanupPlan: cleanupPlan,
                    discardedSuccessCleanup: discardedSuccessCleanup,
                    operationCompletion: operationCompletion,
                    beforeTaskInstallation: beforeTaskInstallation,
                    operation: operation,
                    continuation: continuation
                )
            }
        } onCancel: {
            race.cancelFromParent(cleanupPlan: cleanupPlan)
        }
    }
}
