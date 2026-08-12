import Foundation
import Synchronization

/// Owns caption-embedding temporary files across timeout and cancellation races.
/// Paths are removed from the mutex before file-system work begins so no lock is
/// held while invoking an external API.
nonisolated final class CaptionEmbeddingTemporaryFiles: Sendable {
    final class OperationLease: Sendable {
        private let owner: CaptionEmbeddingTemporaryFiles
        private let isFinished = Mutex(false)

        init(owner: CaptionEmbeddingTemporaryFiles) {
            self.owner = owner
        }

        func finish() {
            let shouldFinish = isFinished.withLock { isFinished in
                guard !isFinished else { return false }
                isFinished = true
                return true
            }
            if shouldFinish {
                owner.finishOperation()
            }
        }

        deinit {
            finish()
        }
    }

    private struct State: ~Copyable {
        var registeredURLs: Set<URL> = []
        var activeOperationCount = 0
        var isCleanupRequested = false
    }

    private let state = Mutex(State())

    func beginOperation() -> OperationLease {
        state.withLock { state in
            state.activeOperationCount += 1
        }
        return OperationLease(owner: self)
    }

    func beginCleanup() -> OperationLease {
        state.withLock { state in
            state.activeOperationCount += 1
            state.isCleanupRequested = true
        }
        return OperationLease(owner: self)
    }

    func register(_ url: URL) {
        _ = state.withLock { $0.registeredURLs.insert(url) }
    }

    func preserve(_ url: URL) {
        _ = state.withLock { $0.registeredURLs.remove(url) }
    }

    func remove(_ urls: some Sequence<URL>) {
        let removableURLs = state.withLock { state in
            urls.compactMap { url in
                state.registeredURLs.remove(url).map { _ in url }
            }
        }
        Self.removeFromFileSystem(removableURLs)
    }

    func requestCleanup() {
        let removableURLs = state.withLock { state -> [URL] in
            state.isCleanupRequested = true
            guard state.activeOperationCount == 0 else { return [] }
            return Self.takeRegisteredURLs(from: &state)
        }
        Self.removeFromFileSystem(removableURLs)
    }

    private func finishOperation() {
        let removableURLs = state.withLock { state -> [URL] in
            precondition(state.activeOperationCount > 0)
            state.activeOperationCount -= 1
            guard state.isCleanupRequested, state.activeOperationCount == 0 else {
                return []
            }
            return Self.takeRegisteredURLs(from: &state)
        }
        Self.removeFromFileSystem(removableURLs)
    }

    private static func takeRegisteredURLs(from state: inout State) -> [URL] {
        let urls = Array(state.registeredURLs)
        state.registeredURLs.removeAll()
        return urls
    }

    private static func removeFromFileSystem(_ urls: some Sequence<URL>) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
