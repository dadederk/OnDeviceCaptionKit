import AVFoundation
import Foundation
import Synchronization

/// Cancels in-flight caption writers and export sessions when embedding times out
/// or its parent task is cancelled.
nonisolated final class CaptionEmbeddingCancellationHolder: Sendable {
    /// AVAssetWriter has no checked Sendable conformance. This reference is used
    /// only with the caption-only writer created by CaptionEmbedder; that writer
    /// never calls the sample-buffer or pixel-buffer append APIs that AVFoundation
    /// explicitly forbids racing with cancelWriting(). Cancellation runs outside
    /// the mutex because cancelWriting() may block. Remove this wrapper when the
    /// SDK provides a checked concurrency contract for AVAssetWriter.
    private struct WriterReference: @unchecked Sendable {
        private let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }

        func matches(_ other: AVAssetWriter) -> Bool {
            writer === other
        }

        func cancel() {
            writer.cancelWriting()
        }
    }

    /// AVAssetExportSession permits cancellation while an export is running.
    /// The immutable wrapper is used only to cancel that export and read progress.
    /// Remove it when AVAssetExportSession gains checked Sendable conformance.
    private struct ExportSessionReference: @unchecked Sendable {
        private let exportSession: AVAssetExportSession

        init(_ exportSession: AVAssetExportSession) {
            self.exportSession = exportSession
        }

        func matches(_ other: AVAssetExportSession) -> Bool {
            exportSession === other
        }

        var progress: Float {
            exportSession.progress
        }

        func cancel() {
            exportSession.cancelExport()
        }
    }

    private struct CancellationHandles: Sendable {
        let writer: WriterReference?
        let exportSession: ExportSessionReference?
        let temporaryFileCleanupLease: CaptionEmbeddingTemporaryFiles.OperationLease?
    }

    private enum CleanupState: Equatable {
        case idle
        case prepared
        case running
        case completed
    }

    private struct State: ~Copyable {
        var writer: WriterReference?
        var exportSession: ExportSessionReference?
        var temporaryFiles: CaptionEmbeddingTemporaryFiles?
        var temporaryFileCleanupLease: CaptionEmbeddingTemporaryFiles.OperationLease?
        var didCancel = false
        var cleanupState = CleanupState.idle
    }

    private let state = Mutex(State())

    var didCancel: Bool {
        state.withLock { $0.didCancel }
    }

    @discardableResult
    func setWriter(_ writer: AVAssetWriter) -> Bool {
        let reference = WriterReference(writer)
        return state.withLock { state in
            guard !state.didCancel else { return false }
            state.writer = reference
            return true
        }
    }

    func clearWriter(_ writer: AVAssetWriter) {
        state.withLock { state in
            if !state.didCancel, state.writer?.matches(writer) == true {
                state.writer = nil
            }
        }
    }

    @discardableResult
    func setExportSession(_ exportSession: AVAssetExportSession) -> Bool {
        let reference = ExportSessionReference(exportSession)
        return state.withLock { state in
            guard !state.didCancel else { return false }
            state.exportSession = reference
            return true
        }
    }

    func clearExportSession(_ exportSession: AVAssetExportSession) {
        state.withLock { state in
            if !state.didCancel, state.exportSession?.matches(exportSession) == true {
                state.exportSession = nil
            }
        }
    }

    func exportProgress() -> Float? {
        let exportSession = state.withLock { $0.exportSession }
        return exportSession?.progress
    }

    @discardableResult
    func setTemporaryFiles(_ temporaryFiles: CaptionEmbeddingTemporaryFiles) -> Bool {
        state.withLock { state in
            guard !state.didCancel else { return false }
            state.temporaryFiles = temporaryFiles
            return true
        }
    }

    func clearTemporaryFiles(_ temporaryFiles: CaptionEmbeddingTemporaryFiles) {
        state.withLock { state in
            if !state.didCancel, state.temporaryFiles === temporaryFiles {
                state.temporaryFiles = nil
            }
        }
    }

    @discardableResult
    func prepareCancellation() -> Bool {
        state.withLock { state in
            guard state.cleanupState == .idle else { return false }
            state.didCancel = true
            state.cleanupState = .prepared
            state.temporaryFileCleanupLease = state.temporaryFiles?.beginCleanup()
            return true
        }
    }

    func performPreparedCancellation() {
        let handles = state.withLock { state -> CancellationHandles? in
            guard state.cleanupState == .prepared else { return nil }
            state.cleanupState = .running
            let handles = CancellationHandles(
                writer: state.writer,
                exportSession: state.exportSession,
                temporaryFileCleanupLease: state.temporaryFileCleanupLease
            )
            state.writer = nil
            state.exportSession = nil
            state.temporaryFiles = nil
            state.temporaryFileCleanupLease = nil
            return handles
        }
        guard let handles else { return }

        handles.exportSession?.cancel()
        handles.writer?.cancel()
        handles.temporaryFileCleanupLease?.finish()

        state.withLock { state in
            state.cleanupState = .completed
        }
    }
}
