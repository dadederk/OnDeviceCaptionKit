import AVFoundation
import Foundation

nonisolated protocol CaptionEmbeddingCancellable: Sendable {
  func cancel()
}

/// Cancels in-flight caption writers and export sessions when embedding times out.
nonisolated final class CaptionEmbeddingCancellationHolder: CaptionEmbeddingCancellable, @unchecked Sendable {
  private let lock = NSLock()
  private var writer: AVAssetWriter?
  private var exportSession: AVAssetExportSession?
  private(set) var didCancel = false

  func setWriter(_ writer: AVAssetWriter) {
    lock.lock()
    self.writer = writer
    lock.unlock()
  }

  func clearWriter(_ writer: AVAssetWriter) {
    lock.lock()
    if self.writer === writer {
      self.writer = nil
    }
    lock.unlock()
  }

  func setExportSession(_ exportSession: AVAssetExportSession) {
    lock.lock()
    self.exportSession = exportSession
    lock.unlock()
  }

  func clearExportSession(_ exportSession: AVAssetExportSession) {
    lock.lock()
    if self.exportSession === exportSession {
      self.exportSession = nil
    }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    didCancel = true
    let writer = self.writer
    let exportSession = self.exportSession
    lock.unlock()
    writer?.cancelWriting()
    exportSession?.cancelExport()
  }
}
