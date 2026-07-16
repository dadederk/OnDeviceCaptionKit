import Foundation

nonisolated enum CaptionEmbeddingTimeout {
    private final class TimeoutRace<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        func start(
            seconds: TimeInterval,
            onTimeout: @escaping @Sendable () -> Void,
            operation: @escaping @Sendable () async throws -> Value,
            continuation: CheckedContinuation<Value, Error>
        ) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let operationTask = Task { [self] in
                do {
                    let value = try await operation()
                    self.finish(with: .success(value))
                } catch {
                    self.finish(with: .failure(error))
                }
            }

            let timeoutTask = Task { [self] in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                self.fireTimeout(onTimeout: onTimeout)
            }

            lock.lock()
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func cancelFromParent() {
            finish(with: .failure(CancellationError()))
        }

        private func fireTimeout(onTimeout: @Sendable () -> Void) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let operationTask = self.operationTask
            self.operationTask = nil
            self.timeoutTask = nil
            lock.unlock()

            guard continuation != nil else { return }

            onTimeout()
            operationTask?.cancel()
            continuation?.resume(throwing: CaptionEmbeddingError.timedOut)
        }

        private func finish(with result: sending Result<Value, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let operationTask = self.operationTask
            let timeoutTask = self.timeoutTask
            self.operationTask = nil
            self.timeoutTask = nil
            lock.unlock()

            operationTask?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }
    }

    static func run<Value: Sendable>(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = TimeoutRace<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                race.start(
                    seconds: seconds,
                    onTimeout: onTimeout,
                    operation: operation,
                    continuation: continuation
                )
            }
        } onCancel: {
            race.cancelFromParent()
        }
    }
}
